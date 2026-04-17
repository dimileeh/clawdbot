#!/bin/bash
# pr-manager.sh — Unified PR management for Aira repos
#
# Runs every 10 minutes via crontab. Zero LLM tokens (except spawned review handlers).
#
# What it does:
#   1. For PRs targeting development: auto-merge when ready
#      (all review comments addressed, checks green, mergeable)
#      UNLESS there's an open dev→main PR (would change its diff mid-review)
#   2. For PRs targeting main: notify when ready to merge
#      (Dmitri merges main PRs manually)
#   3. If development is ahead of main with no PR: create one
#   4. After dev→main merge: fast-forward development to main
#   5. Spawn per-PR review handler agents for unresolved threads
#
# "Ready" = unresolved threads == 0 AND checks == SUCCESS AND mergeable == MERGEABLE
#
# Review handler design (v2):
#   - One isolated session per PR (not one monolithic session for all)
#   - Each session gets 20 min timeout (enough for ~8 threads)
#   - State tracks in-progress PRs with timestamps (30 min cooldown)
#   - No lock files — coordination via state file only
#   - Lock cleanup is external (this script), not self-cleaning

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:/home/linuxbrew/.linuxbrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

REPOS="${CLAWDBOT_REPOS:?Set CLAWDBOT_REPOS in .env}"
STATE_FILE="$HOME/.clawdbot/pr-manager-state.json"
REVIEW_STATE_FILE="$HOME/.clawdbot/pr-review-handler-state.json"
LOG_PREFIX="[pr-manager $(date -u +%H:%M:%S)]"
REVIEW_WAIT_MINUTES="${CLAWDBOT_REVIEW_WAIT_MINUTES:-15}"

# ── Helper Functions ──────────────────────────────────────────────

# Resolve repo name to local path relative to CLAWDBOT_PROJECTS_ROOT.
# Override with CLAWDBOT_REPO_MAP in .env (JSON: {"repo-name": "relative/path"}).
_resolve_repo_path() {
    local repo_name="$1"
    if [ -n "${CLAWDBOT_REPO_MAP:-}" ]; then
        local mapped
        mapped=$(echo "$CLAWDBOT_REPO_MAP" | jq -r --arg r "$repo_name" '.[$r] // empty' 2>/dev/null)
        [ -n "$mapped" ] && { echo "$mapped"; return; }
    fi
    echo "$repo_name"
}

# Auto-detect test command from project files.
#
# Precedence: Python (pyproject.toml / setup.py) > Node (package.json) > a
# repo-local bash test harness at tests/run-tests.sh. The bash harness is a
# last resort for shell-only repos that don't have a package manager but
# still ship their own test runner; without it, such repos would fall
# through to "No test command configured" and the review handler would
# have no way to verify its own fix before committing.
_detect_test_cmd() {
    local path="$1"
    if [ -f "$path/pyproject.toml" ] || [ -f "$path/setup.py" ]; then
        echo "python -m pytest tests/unit/ -x -q --timeout=30"
    elif [ -f "$path/package.json" ]; then
        if grep -q '"test"' "$path/package.json" 2>/dev/null; then
            echo "npm run test -- --run"
        elif grep -q '"test:unit"' "$path/package.json" 2>/dev/null; then
            echo "npm run test:unit"
        else
            echo "npx next build"
        fi
    elif [ -f "$path/tests/run-tests.sh" ]; then
        echo "bash tests/run-tests.sh"
    else
        echo "echo 'No test command configured'"
    fi
}

# ── State Files ───────────────────────────────────────────────────

[ -f "$STATE_FILE" ] || echo '{"notified_main_prs":{},"merged_prs":{},"created_dev_main_prs":{}}' > "$STATE_FILE"
[ -f "$REVIEW_STATE_FILE" ] || echo '{"handled_threads":{},"in_progress":{},"review_wait":{},"handled_ci":{}}' > "$REVIEW_STATE_FILE"

# Ensure all keys exist
for KEY in notified_main_prs merged_prs created_dev_main_prs; do
    if ! jq -e ".$KEY" "$STATE_FILE" >/dev/null 2>&1; then
        jq ". + {\"$KEY\":{}}" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
done
for KEY in handled_threads in_progress handled_ci review_wait; do
    if ! jq -e ".$KEY" "$REVIEW_STATE_FILE" >/dev/null 2>&1; then
        jq ". + {\"$KEY\":{}}" "$REVIEW_STATE_FILE" > "${REVIEW_STATE_FILE}.tmp" && mv "${REVIEW_STATE_FILE}.tmp" "$REVIEW_STATE_FILE"
    fi
done

# shellcheck disable=SC2034
WAKE_REASONS=""
MERGE_REASONS=""

for REPO in $REPOS; do
    echo "$LOG_PREFIX Checking $REPO..."

    # ─── Fetch all open PRs with GraphQL (one call per repo) ───
    PR_DATA=$(gh api graphql -f query="
    {
      repository(owner: \"${CLAWDBOT_GITHUB_OWNER}\", name: \"$(echo "$REPO" | cut -d/ -f2)\") {
        pullRequests(states: OPEN, first: 30) {
          nodes {
            number
            title
            baseRefName
            headRefName
            mergeable
            url
            isDraft
            author { login }
            reviewThreads(first: 100) {
              nodes {
                isResolved
                isOutdated
              }
            }
            commits(last: 1) {
              nodes {
                commit {
                  oid
                  statusCheckRollup {
                    state
                  }
                }
              }
            }
          }
        }
      }
    }" 2>/dev/null || echo '{"data":{"repository":{"pullRequests":{"nodes":[]}}}}')

    # Parse each PR
    PR_LIST=$(echo "$PR_DATA" | jq -c '.data.repository.pullRequests.nodes[]' 2>/dev/null || true)

    if [ -z "$PR_LIST" ]; then
        echo "$LOG_PREFIX   No open PRs"
    else
        while IFS= read -r PR; do
            PR_NUM=$(echo "$PR" | jq -r '.number')
            PR_TITLE=$(echo "$PR" | jq -r '.title')
            PR_BASE=$(echo "$PR" | jq -r '.baseRefName')
            PR_HEAD=$(echo "$PR" | jq -r '.headRefName')
            PR_URL=$(echo "$PR" | jq -r '.url')
            IS_DRAFT=$(echo "$PR" | jq -r '.isDraft')
            PR_AUTHOR=$(echo "$PR" | jq -r '.author.login // "unknown"')
            MERGEABLE=$(echo "$PR" | jq -r '.mergeable')
            CHECK_STATE=$(echo "$PR" | jq -r '.commits.nodes[0].commit.statusCheckRollup.state // "PENDING"')
            COMMIT_SHA=$(echo "$PR" | jq -r '.commits.nodes[0].commit.oid // ""')
            UNRESOLVED=$(echo "$PR" | jq '[.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == false)] | length')

            echo "$LOG_PREFIX   PR #$PR_NUM ($PR_HEAD → $PR_BASE): mergeable=$MERGEABLE checks=$CHECK_STATE unresolved=$UNRESOLVED draft=$IS_DRAFT"

            # Skip drafts
            if [ "$IS_DRAFT" = "true" ]; then
                continue
            fi

            # Skip dependabot PRs (by author, not title — our combined dep PRs also use chore(deps) prefix)
            if [ "$PR_AUTHOR" = "dependabot" ] || [ "$PR_AUTHOR" = "dependabot[bot]" ]; then
                echo "$LOG_PREFIX     Skipping dependabot PR (author=$PR_AUTHOR)"
                continue
            fi

            # ─── Check if PR is ready ───
            IS_READY="false"
            NOT_READY_REASON=""

            if [ "$MERGEABLE" != "MERGEABLE" ]; then
                NOT_READY_REASON="not mergeable ($MERGEABLE)"
            elif [ "$CHECK_STATE" != "SUCCESS" ]; then
                NOT_READY_REASON="checks not green ($CHECK_STATE)"
            elif [ "$UNRESOLVED" -gt 0 ]; then
                NOT_READY_REASON="$UNRESOLVED unresolved review thread(s)"
            else
                IS_READY="true"
            fi

            if [ "$IS_READY" = "false" ]; then
                echo "$LOG_PREFIX     Not ready: $NOT_READY_REASON"

                # ─── Spawn CI fix handler if checks failed ───
                if [ "$CHECK_STATE" = "FAILURE" ] && [ "$MERGEABLE" = "MERGEABLE" ]; then
                    CI_FIX_KEY="ci:${REPO}#${PR_NUM}@${COMMIT_SHA}"
                    CI_IN_PROGRESS=$(jq -r ".in_progress[\"$CI_FIX_KEY\"] // \"\"" "$REVIEW_STATE_FILE")
                    CI_ALREADY_HANDLED=$(jq -r ".handled_ci[\"$CI_FIX_KEY\"] // \"\"" "$REVIEW_STATE_FILE")

                    if [ -z "$CI_IN_PROGRESS" ] && [ -z "$CI_ALREADY_HANDLED" ]; then
                        echo "$LOG_PREFIX     🔧 CI failed — collecting failed job logs..."

                        # Get the failed run(s) for this commit
                        REPO_NAME_CI=$(echo "$REPO" | cut -d/ -f2)
                        FAILED_LOGS=""
                        FAILED_JOBS=$(gh run list --repo "$REPO" --commit "$COMMIT_SHA" --status failure --json databaseId,name --jq '.[] | "\(.databaseId)|\(.name)"' 2>/dev/null || true)

                        if [ -n "$FAILED_JOBS" ]; then
                            while IFS='|' read -r RUN_ID RUN_NAME; do
                                echo "$LOG_PREFIX     Pulling logs for run $RUN_ID ($RUN_NAME)..."
                                JOB_LOG=$(gh run view "$RUN_ID" --repo "$REPO" --log-failed 2>/dev/null | tail -80 || true)
                                if [ -n "$JOB_LOG" ]; then
                                    FAILED_LOGS="${FAILED_LOGS}\n--- ${RUN_NAME} (run ${RUN_ID}) ---\n${JOB_LOG}\n"
                                fi
                            done <<< "$FAILED_JOBS"
                        fi

                        if [ -n "$FAILED_LOGS" ]; then
                            CI_LOG_FILE="/tmp/ci-fix-${REPO//\//-}-${PR_NUM}.txt"
                            printf "%b" "$FAILED_LOGS" > "$CI_LOG_FILE"

                            # Map repo to local path (auto-detect from CLAWDBOT_PROJECTS_ROOT)
                            CI_LOCAL_PATH="${CLAWDBOT_PROJECTS_ROOT:-$HOME/Projects}/$(_resolve_repo_path "$REPO_NAME_CI")"

                            # Determine test command (auto-detect from project type)
                            CI_TEST_CMD="$(_detect_test_cmd "$CI_LOCAL_PATH")"

                            # Mark in progress
                            jq --arg key "$CI_FIX_KEY" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                                '.in_progress[$key] = $ts' "$REVIEW_STATE_FILE" > "${REVIEW_STATE_FILE}.tmp" && \
                                mv "${REVIEW_STATE_FILE}.tmp" "$REVIEW_STATE_FILE"

                            echo "$LOG_PREFIX     🚀 Spawning CI fix handler for $REPO PR #$PR_NUM..."

                            openclaw cron add \
                                --name "CI Fix: ${REPO}#${PR_NUM}" \
                                --at "30s" \
                                --session isolated \
                                --model "${CLAWDBOT_REVIEW_MODEL:-anthropic/claude-opus-4-7}" \
                                --timeout-seconds 1200 \
                                --announce \
                                --channel "${CLAWDBOT_NOTIFY_CHANNEL:-telegram}" \
                                --to "${CLAWDBOT_NOTIFY_TARGET:?Set CLAWDBOT_NOTIFY_TARGET in .env}" \
                                --delete-after-run \
                                --message "You are Spark's CI Fix Handler for ${REPO} PR #${PR_NUM}.

## CI Failure Logs
Read ${CI_LOG_FILE} for the failed CI output.

## Repo
Local path: ${CI_LOCAL_PATH}
Branch: ${PR_HEAD}
Test command: ${CI_TEST_CMD}

## Process
1. Read the CI failure logs in ${CI_LOG_FILE}
2. Identify the root cause (typecheck error, lint failure, test failure, etc.)
3. Check out the branch: \`cd ${CI_LOCAL_PATH} && git checkout ${PR_HEAD} && git pull origin ${PR_HEAD}\`
4. Fix the issue in the source code
5. Run the relevant check locally:
   - For typecheck: \`cd ${CI_LOCAL_PATH} && python -m mypy src/ --no-error-summary\` (Python) or \`npm run typecheck\` (Node)
   - For lint: \`cd ${CI_LOCAL_PATH} && ruff check src/\` (Python) or \`npm run lint\` (Node)
   - For tests: \`cd ${CI_LOCAL_PATH} && ${CI_TEST_CMD}\`
6. If fix works: commit with conventional commit message, push to ${PR_HEAD}
7. CI will re-run automatically on push

## When done
Clear the in-progress marker:
\`jq --arg key \"${CI_FIX_KEY}\" 'del(.in_progress[\$key])' ~/.clawdbot/pr-review-handler-state.json > /tmp/cih.tmp && mv /tmp/cih.tmp ~/.clawdbot/pr-review-handler-state.json\`

Mark as handled (so we don't re-spawn for the same SHA):
\`jq --arg key \"${CI_FIX_KEY}\" --arg ts \$(date -u +%Y-%m-%dT%H:%M:%SZ) '.handled_ci[\$key] = \$ts' ~/.clawdbot/pr-review-handler-state.json > /tmp/cih.tmp && mv /tmp/cih.tmp ~/.clawdbot/pr-review-handler-state.json\`

## Rules
- NEVER merge to main. NEVER merge PRs.
- Fix only what CI is complaining about — minimal changes.
- If the fix would be >50 lines or requires architectural changes, skip and report why.
- Report: what failed, what you fixed, whether local checks pass now." \
                                2>/dev/null || {
                                    echo "$LOG_PREFIX     ⚠️ Failed to spawn CI fix handler for $REPO PR #$PR_NUM"
                                    jq --arg key "$CI_FIX_KEY" 'del(.in_progress[$key])' "$REVIEW_STATE_FILE" > "${REVIEW_STATE_FILE}.tmp" && \
                                        mv "${REVIEW_STATE_FILE}.tmp" "$REVIEW_STATE_FILE"
                                }

                            echo "$LOG_PREFIX   ✅ CI fix handler spawned for $REPO PR #$PR_NUM"
                        else
                            echo "$LOG_PREFIX     No failed job logs found for $REPO PR #$PR_NUM"
                        fi
                    elif [ -n "$CI_IN_PROGRESS" ]; then
                        echo "$LOG_PREFIX     ⏳ CI fix handler already in progress for $CI_FIX_KEY"
                    else
                        echo "$LOG_PREFIX     Already handled CI failure at this SHA"
                    fi
                fi

                continue
            fi

            # ─── PR is ready — decide action based on base branch ───

            if [ "$PR_BASE" = "development" ]; then
                # Block auto-merge if there's an open dev→main PR (would change its diff mid-review)
                HAS_OPEN_DEV_MAIN=$(echo "$PR_DATA" | jq '[.data.repository.pullRequests.nodes[] | select(.baseRefName == "main" and .headRefName == "development")] | length')
                if [ "$HAS_OPEN_DEV_MAIN" -gt 0 ]; then
                    echo "$LOG_PREFIX     ⏸️ Holding — open development→main PR exists, won't change its diff"
                    MERGE_REASONS="${MERGE_REASONS}⏸️ Holding $REPO PR #$PR_NUM (ready to merge to development) — open dev→main PR exists\n"
                    continue
                fi

                # Auto-merge to development
                ALREADY_MERGED=$(jq -r ".merged_prs[\"$REPO#$PR_NUM\"] // \"\"" "$STATE_FILE")
                if [ -n "$ALREADY_MERGED" ]; then
                    echo "$LOG_PREFIX     Already merged (tracked)"
                    continue
                fi

                echo "$LOG_PREFIX     ✅ Auto-merging PR #$PR_NUM to development..."
                if gh pr merge "$PR_NUM" --repo "$REPO" --squash --delete-branch 2>&1; then
                    MERGE_REASONS="${MERGE_REASONS}✅ Auto-merged $REPO PR #$PR_NUM to development: $PR_TITLE\n   $PR_URL\n"
                    jq --arg key "$REPO#$PR_NUM" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                        '.merged_prs[$key] = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                else
                    echo "$LOG_PREFIX     ⚠️ Merge failed"
                    MERGE_REASONS="${MERGE_REASONS}⚠️ Auto-merge FAILED for $REPO PR #$PR_NUM: $PR_TITLE\n   $PR_URL\n"
                fi

            elif [ "$PR_BASE" = "main" ]; then
                # Notify (never auto-merge main)
                NOTIFIED_SHA=$(jq -r ".notified_main_prs[\"$REPO#$PR_NUM\"] // \"\"" "$STATE_FILE")
                if [ "$NOTIFIED_SHA" = "$COMMIT_SHA" ]; then
                    echo "$LOG_PREFIX     Already notified at this SHA"
                    continue
                fi

                MERGE_REASONS="${MERGE_REASONS}🟢 $REPO PR #$PR_NUM ready to merge to main: $PR_TITLE\n   All comments resolved, checks green, mergeable.\n   $PR_URL\n"
                jq --arg key "$REPO#$PR_NUM" --arg sha "$COMMIT_SHA" \
                    '.notified_main_prs[$key] = $sha' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            fi

        done <<< "$PR_LIST"
    fi

    # ─── Fast-forward development to main after dev→main PR merge ───
    MAIN_SHA=$(gh api "repos/$REPO/branches/main" --jq '.commit.sha' 2>/dev/null || echo "")
    DEV_SHA=$(gh api "repos/$REPO/branches/development" --jq '.commit.sha' 2>/dev/null || echo "")

    if [ -n "$MAIN_SHA" ] && [ -n "$DEV_SHA" ] && [ "$MAIN_SHA" != "$DEV_SHA" ]; then
        BEHIND=$(gh api "repos/$REPO/compare/development...main" --jq '.ahead_by' 2>/dev/null || echo "0")
        AHEAD=$(gh api "repos/$REPO/compare/main...development" --jq '.ahead_by' 2>/dev/null || echo "0")
        EXISTING_DEV_MAIN=$(gh pr list --repo "$REPO" --base main --head development --state open --json number --jq 'length' 2>/dev/null || echo "0")

        if [ "$BEHIND" -gt 0 ] && [ "$AHEAD" = "0" ] && [ "$EXISTING_DEV_MAIN" = "0" ]; then
            # development is strictly behind main (pure fast-forward safe)
            echo "$LOG_PREFIX   ⏩ Fast-forwarding development to main ($BEHIND commits behind)..."
            if gh api "repos/$REPO/git/refs/heads/development" -X PATCH -f sha="$MAIN_SHA" 2>/dev/null; then
                echo "$LOG_PREFIX   ✅ development fast-forwarded to main"
                MERGE_REASONS="${MERGE_REASONS}⏩ $REPO: development fast-forwarded to main\n"
            else
                echo "$LOG_PREFIX   ⚠️ Fast-forward failed"
            fi
        elif [ "$AHEAD" -gt 0 ] && [ "$EXISTING_DEV_MAIN" = "0" ]; then
            # development is ahead of main, no PR exists — but only create if NO open feature→dev PRs remain
            OPEN_FEATURE_TO_DEV=$(echo "$PR_DATA" | jq '[.data.repository.pullRequests.nodes[] | select(.baseRefName == "development" and .isDraft == false)] | length')
            if [ "$OPEN_FEATURE_TO_DEV" -gt 0 ]; then
                echo "$LOG_PREFIX   ⏸️ Not creating dev→main PR — $OPEN_FEATURE_TO_DEV open feature→development PR(s) still in flight"
            else
                CREATED_SHA=$(jq -r ".created_dev_main_prs[\"$REPO\"] // \"\"" "$STATE_FILE")
                if [ "$DEV_SHA" != "$CREATED_SHA" ]; then
                    echo "$LOG_PREFIX   Creating development → main PR for $REPO ($AHEAD commits ahead, no in-flight feature PRs)..."
                    PR_RESULT=$(gh pr create --repo "$REPO" --base main --head development \
                        --title "Development into main" \
                        --body "Automated PR: development → main ($AHEAD commits ahead)" 2>&1 || true)

                    if echo "$PR_RESULT" | grep -q "https://github.com"; then
                        PR_LINK=$(echo "$PR_RESULT" | grep -o "https://github.com[^ ]*")
                        MERGE_REASONS="${MERGE_REASONS}🔀 Created development → main PR for $REPO ($AHEAD commits ahead)\n   $PR_LINK\n"
                        jq --arg repo "$REPO" --arg sha "$DEV_SHA" \
                            '.created_dev_main_prs[$repo] = $sha' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                    else
                        echo "$LOG_PREFIX     PR creation output: $PR_RESULT"
                    fi
                fi
            fi
        fi
    fi

done

# ─── Spawn per-PR review handlers for unresolved threads ───
UNRESOLVED_PRS=$(bash "$HOME/.clawdbot/pr-review-collector.sh" 2>/dev/null || echo "[]")
UNRESOLVED_COUNT=$(echo "$UNRESOLVED_PRS" | jq 'length' 2>/dev/null || echo "0")

NOW_EPOCH=$(date +%s)
# Clean up stale in_progress entries (>30 min old)
jq --argjson now "$NOW_EPOCH" '
  .in_progress = (.in_progress // {} | to_entries | map(
    select((.value | split("T")[0] + "T" + .value | split("T")[1]) as $ts |
      ($now - (now | floor)) < 1800)
  ) | from_entries)
' "$REVIEW_STATE_FILE" > "${REVIEW_STATE_FILE}.tmp" 2>/dev/null && \
  mv "${REVIEW_STATE_FILE}.tmp" "$REVIEW_STATE_FILE" || true

# Actually, simpler stale cleanup — parse ISO timestamps
CUTOFF_30M=$(date -u -d "30 minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg cutoff "$CUTOFF_30M" '
  .in_progress = (.in_progress // {} | to_entries | map(select(.value > $cutoff)) | from_entries)
' "$REVIEW_STATE_FILE" > "${REVIEW_STATE_FILE}.tmp" 2>/dev/null && \
  mv "${REVIEW_STATE_FILE}.tmp" "$REVIEW_STATE_FILE" || true

if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
    # Process each PR individually
    for i in $(seq 0 $(( UNRESOLVED_COUNT - 1 ))); do
        PR_JSON=$(echo "$UNRESOLVED_PRS" | jq -c ".[$i]")
        PR_REPO=$(echo "$PR_JSON" | jq -r '.repo')
        PR_NUM=$(echo "$PR_JSON" | jq -r '.number')
        PR_HEAD=$(echo "$PR_JSON" | jq -r '.head')
        PR_HEAD_SHA=$(echo "$PR_JSON" | jq -r '.head_sha // ""')
        PR_KEY="${PR_REPO}#${PR_NUM}"
        THREAD_COUNT=$(echo "$PR_JSON" | jq '.unresolved_threads | length')
        NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        # Check if already in progress (30 min cooldown)
        IN_PROGRESS_TS=$(jq -r ".in_progress[\"$PR_KEY\"] // \"\"" "$REVIEW_STATE_FILE")
        if [ -n "$IN_PROGRESS_TS" ]; then
            echo "$LOG_PREFIX   ⏳ $PR_KEY already has review handler in progress (since $IN_PROGRESS_TS), skipping"
            continue
        fi

        WAIT_FIRST_SEEN=$(jq -r ".review_wait[\"$PR_KEY\"].first_seen // \"\"" "$REVIEW_STATE_FILE")
        WAIT_HEAD_SHA=$(jq -r ".review_wait[\"$PR_KEY\"].head_sha // \"\"" "$REVIEW_STATE_FILE")

        if [ -z "$WAIT_FIRST_SEEN" ] || [ "$WAIT_HEAD_SHA" != "$PR_HEAD_SHA" ]; then
            jq --arg key "$PR_KEY" --arg ts "$NOW_ISO" --arg sha "$PR_HEAD_SHA" \
                '.review_wait[$key] = {first_seen: $ts, head_sha: $sha}' "$REVIEW_STATE_FILE" > "${REVIEW_STATE_FILE}.tmp" && \
                mv "${REVIEW_STATE_FILE}.tmp" "$REVIEW_STATE_FILE"
            echo "$LOG_PREFIX   ⏱️ Starting ${REVIEW_WAIT_MINUTES}m review window for $PR_KEY at commit ${PR_HEAD_SHA:0:12} ($THREAD_COUNT thread(s))"
            continue
        fi

        CUTOFF_WAIT=$(date -u -d "${REVIEW_WAIT_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
        if [[ "$WAIT_FIRST_SEEN" > "$CUTOFF_WAIT" ]]; then
            echo "$LOG_PREFIX   ⏳ $PR_KEY still inside ${REVIEW_WAIT_MINUTES}m review window (since $WAIT_FIRST_SEEN), waiting"
            continue
        fi

        echo "$LOG_PREFIX   🔍 Review window elapsed, spawning handler for $PR_KEY ($THREAD_COUNT thread(s))..."

        # Write per-PR thread data
        PR_THREAD_FILE="/tmp/pr-review-${PR_REPO//\//-}-${PR_NUM}.json"
        echo "$PR_JSON" > "$PR_THREAD_FILE"

        # Map repo to local path (auto-detect from CLAWDBOT_PROJECTS_ROOT)
        REPO_NAME=$(echo "$PR_REPO" | cut -d/ -f2)
        LOCAL_PATH="${CLAWDBOT_PROJECTS_ROOT:-$HOME/Projects}/$(_resolve_repo_path "$REPO_NAME")"

        # Determine test command (auto-detect from project type)
        TEST_CMD="$(_detect_test_cmd "$LOCAL_PATH")"

        # Mark in progress and reset the review wait window baseline for the next wave.
        jq --arg key "$PR_KEY" --arg ts "$NOW_ISO" --arg sha "$PR_HEAD_SHA" \
            '.in_progress[$key] = $ts | .review_wait[$key] = {first_seen: $ts, head_sha: $sha}' "$REVIEW_STATE_FILE" > "${REVIEW_STATE_FILE}.tmp" && \
            mv "${REVIEW_STATE_FILE}.tmp" "$REVIEW_STATE_FILE"

        # Spawn isolated session — one per PR, 20 min timeout
        openclaw cron add \
            --name "PR Review: ${PR_REPO}#${PR_NUM}" \
            --at "30s" \
            --session isolated \
            --model "${CLAWDBOT_REVIEW_MODEL:-anthropic/claude-opus-4-7}" \
            --timeout-seconds 1200 \
            --announce \
            --channel "${CLAWDBOT_NOTIFY_CHANNEL:-telegram}" \
            --to "${CLAWDBOT_NOTIFY_TARGET:?Set CLAWDBOT_NOTIFY_TARGET in .env}" \
            --delete-after-run \
            --message "You are Spark's PR Review Handler for ${PR_REPO} PR #${PR_NUM}.

## Input
Read ${PR_THREAD_FILE} for the unresolved review threads.

## Repo
Local path: ${LOCAL_PATH}
Head branch: ${PR_HEAD}
Test command: ${TEST_CMD}

## Process for each thread

1. Read the review comment carefully
2. Read the source file at the path/line mentioned
3. Check if already fixed: \`cd ${LOCAL_PATH} && git log --oneline ${PR_HEAD} -5\`
4. If fix needed:
   a. \`cd ${LOCAL_PATH} && git checkout ${PR_HEAD}\`
   b. Make the fix (keep changes minimal and focused)
   c. Run tests: \`cd ${LOCAL_PATH} && ${TEST_CMD}\`
   d. If tests pass: commit with conventional commit, push
   e. Comment on the thread with the fix SHA
5. If not actionable (style nit, question, etc.): reply explaining why
6. Resolve the thread:
   \`gh api graphql -f query='mutation { resolveReviewThread(input: {threadId: \"THREAD_ID\"}) { thread { isResolved } } }'\`
7. Track in state:
   \`jq --arg tid THREAD_ID --arg ts \$(date -u +%Y-%m-%dT%H:%M:%SZ) '.handled_threads[\$tid] = \$ts' ~/.clawdbot/pr-review-handler-state.json > /tmp/prh.tmp && mv /tmp/prh.tmp ~/.clawdbot/pr-review-handler-state.json\`

## When done
Clear the in-progress marker:
\`jq 'del(.in_progress[\"${PR_KEY}\"])' ~/.clawdbot/pr-review-handler-state.json > /tmp/prh.tmp && mv /tmp/prh.tmp ~/.clawdbot/pr-review-handler-state.json\`

## Rules
- NEVER merge to main. NEVER merge PRs.
- Run tests before pushing. If tests fail, fix the test failure or skip the thread.
- If a fix would be >50 lines, skip and report why.
- Group duplicate bot comments (multiple bots flagging same issue = fix once, resolve all).
- Report: which threads you resolved, which you skipped and why.
- DO NOT claim the PR is 'ready' — only report which threads you handled." \
            2>/dev/null || {
                echo "$LOG_PREFIX     ⚠️ Failed to spawn review handler for $PR_KEY"
                # Clear in_progress on spawn failure
                jq --arg key "$PR_KEY" 'del(.in_progress[$key])' "$REVIEW_STATE_FILE" > "${REVIEW_STATE_FILE}.tmp" && \
                    mv "${REVIEW_STATE_FILE}.tmp" "$REVIEW_STATE_FILE"
            }

        echo "$LOG_PREFIX   ✅ Review handler spawned for $PR_KEY"
    done
fi

# ─── Always send merge/notification events if any ───
if [ -n "$MERGE_REASONS" ]; then
    WAKE_TEXT=$(printf "🔧 PR Manager report:\n\n${MERGE_REASONS}")
    openclaw system event \
        --mode now \
        --text "$WAKE_TEXT" \
        --timeout 5000 2>/dev/null || true
fi

# ─── Clean up handled_threads older than 7 days ───
CUTOFF_7D=$(date -u -d "7 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg cutoff "$CUTOFF_7D" '
  .handled_threads = (.handled_threads // {} | to_entries | map(select(.value > $cutoff)) | from_entries)
  | .handled_ci = (.handled_ci // {} | to_entries | map(select(.value > $cutoff)) | from_entries)
  | .review_wait = (.review_wait // {} | to_entries | map(select((.value.first_seen // "") > $cutoff)) | from_entries)
' "$REVIEW_STATE_FILE" > "${REVIEW_STATE_FILE}.tmp" 2>/dev/null && mv "${REVIEW_STATE_FILE}.tmp" "$REVIEW_STATE_FILE" || true

# ─── Clean up old temp files (>1 day) ───
find /tmp -name "pr-review-*.json" -mtime +1 -delete 2>/dev/null || true
find /tmp -name "ci-fix-*.txt" -mtime +1 -delete 2>/dev/null || true

echo "$LOG_PREFIX Done."
