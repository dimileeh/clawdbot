#!/bin/bash
# pr-manager.sh — GitHub PR watchdog for a small team
#
# Runs every 5 minutes via system crontab. Zero LLM tokens (bash only).
#
# Contract (ordered per-PR decision tree):
#
#   1. If a PR is mergeable + CI green + 0 unresolved threads:
#      a. target development → auto squash-merge (unless a dev→main PR is open).
#      b. target main → notify the maintainer once per commit SHA.
#
#   2. If a PR has unresolved review threads AND the per-PR "review wait"
#      window (default 15 min since the last check of that SHA) has elapsed:
#      → spawn an isolated handler subagent (one per PR event) that
#        aggregates the comments, builds a plan, executes inline or
#        delegates to a swarm agent, and reports completion directly to
#        the maintainer. Main orchestrator is NOT involved.
#
#   3. If a PR has 0 unresolved threads but CI failed:
#      → spawn an isolated handler subagent with the failed-job log tail
#        so it can plan the fix or delegate to a swarm agent. Same
#        ownership model as (2).
#
#   4. If development is ahead of main with no open dev→main PR and no
#      feature→development PRs in flight → create the dev→main PR.
#      If main is strictly ahead of development with no open dev→main PR
#      → fast-forward development to main.
#
# State is stored in $HOME/.clawdbot/pr-manager-state.json.
# NO in_progress / handler-tracking bookkeeping: once a handler has been
# spawned for a given PR at a given commit SHA, the script only re-spawns
# if the SHA advances OR if CLAWDBOT_RENOTIFY_MINUTES have elapsed without a
# new commit. This means the signal "work is in flight" is the PR itself
# (new commits or resolved threads), not a local marker that can leak.
#
# Handlers run in ISOLATED sessions (openclaw cron --session isolated) so
# each PR event gets a fresh context. Main-session orchestrator (Sparky)
# is invoked only when a handler explicitly escalates via sessions_send
# with an ``[ESCALATION]`` prefix.

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:/home/linuxbrew/.linuxbrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

REPOS="${CLAWDBOT_REPOS:?Set CLAWDBOT_REPOS in .env}"
STATE_FILE="$HOME/.clawdbot/pr-manager-state.json"
LOG_PREFIX="[pr-manager $(date -u +%H:%M:%S)]"

# Branch names are configurable so teams using different conventions (e.g.
# trunk-based with a single main branch, or staging/prod instead of
# development/main) are not forced into our defaults.
INTEGRATION_BRANCH="${CLAWDBOT_INTEGRATION_BRANCH:-development}"
MAIN_BRANCH="${CLAWDBOT_MAIN_BRANCH:-main}"

# ─── Tunables ─────────────────────────────────────────────────────────────
#
# REVIEW_WAIT_MINUTES: how long to wait after first observing unresolved
# threads on a given PR+SHA before notifying the orchestrator. Gives review
# bots (coderabbit / cursor / greptile / gemini / codex) time to converge so
# Sparky sees the full set at once instead of one thread at a time.
# Setting this to 0 disables the wait window — each tick can notify as soon
# as unresolved threads are observed.
#
# RENOTIFY_MINUTES: if Sparky was notified and the PR head SHA hasn't
# advanced and threads are still unresolved after this window, re-notify.
# Prevents a dropped notification from silently rotting a PR. Must be >= 1
# because a zero-minute renotification window would just spam on every tick.
_parse_nonneg_int() {
    local raw="$1" default="$2" name="$3"
    if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -ge 0 ]; then
        echo "$raw"
    else
        [ -n "$raw" ] && echo "[pr-manager] ⚠️ Invalid $name='$raw' (must be non-negative integer); using default $default" >&2
        echo "$default"
    fi
}
_parse_positive_int() {
    local raw="$1" default="$2" name="$3"
    if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -ge 1 ]; then
        echo "$raw"
    else
        [ -n "$raw" ] && echo "[pr-manager] ⚠️ Invalid $name='$raw' (must be positive integer); using default $default" >&2
        echo "$default"
    fi
}
REVIEW_WAIT_MINUTES=$(_parse_nonneg_int "${CLAWDBOT_REVIEW_WAIT_MINUTES:-15}" 15 CLAWDBOT_REVIEW_WAIT_MINUTES)
RENOTIFY_MINUTES=$(_parse_positive_int "${CLAWDBOT_RENOTIFY_MINUTES:-60}" 60 CLAWDBOT_RENOTIFY_MINUTES)

# Portable ISO-8601 UTC timestamp N minutes in the past. We delegate date
# arithmetic to jq (which ships with the rest of the pipeline) instead of
# `date -u -d`, which is GNU-only and silently fails on macOS / BSD. Returns
# empty string on error so callers can fail-closed.
_iso_minutes_ago() {
    local minutes="$1"
    jq -rn --argjson m "$minutes" 'now - ($m * 60) | strftime("%Y-%m-%dT%H:%M:%SZ")' 2>/dev/null || true
}

# ─── State File ───────────────────────────────────────────────────────────
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"
# Ensure top-level keys. notified_reviews / notified_ci are keyed by
# "<repo>#<num>@<sha>" so a new commit cleanly resets them.
for KEY in notified_main_prs merged_prs created_dev_main_prs first_seen_unresolved notified_reviews notified_ci; do
    if ! jq -e ".$KEY" "$STATE_FILE" >/dev/null 2>&1; then
        jq ". + {\"$KEY\":{}}" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
done

# ─── Helpers ──────────────────────────────────────────────────────────────

# Tunables for handler subagents. Model defaults to CLAWDBOT_REVIEW_MODEL
# (the same env var the old architecture used) so the maintainer controls
# which tier handles review + CI events without a code change.
#
# Timeout is generous (20 min) because a handler may need to: aggregate
# comments, make several commits, run lint/test locally, push, then reply
# + resolve each thread one API call at a time. Shorter timeouts kill
# partially-completed loops and leave PRs worse than they started.
HANDLER_MODEL="${CLAWDBOT_REVIEW_MODEL:-anthropic/claude-opus-4-7}"
# Validate the timeout through the same positive-int helper the other
# numeric tunables use so a typo in .env fails visibly here instead of
# at every handler spawn (coderabbit _EhD, clawdbot#24).
# Default raised from 1200 → 5400 (90 min). A handler that pushes commits +
# waits for CI re-runs + replies to multiple threads legitimately needs > 20
# min in some cases. Pairing with the dedup guard below (``_handler_already_running``)
# means a generous per-job budget no longer causes handler overlap for the
# same PR, only more headroom for the one handler that IS running.
HANDLER_TIMEOUT_SECONDS=$(_parse_positive_int "${CLAWDBOT_HANDLER_TIMEOUT_SECONDS:-5400}" 5400 CLAWDBOT_HANDLER_TIMEOUT_SECONDS)
# Thinking level is configurable because not every model supports
# ``high`` (gemini _Eb6, clawdbot#24). ``openclaw cron add --thinking``
# accepts off|minimal|low|medium|high|xhigh; anything else fails at
# spawn time, so we let openclaw validate rather than shadow its list.
HANDLER_THINKING="${CLAWDBOT_HANDLER_THINKING:-high}"
# Thread-count ceiling for inline (handler-owned) fixes — above this
# the bash script escalates directly to the maintainer instead of
# paying for an LLM spawn (gemini _BbKB, clawdbot#26). Observed on
# 2026-04-19: a 15-thread aggregate PR exhausted the handler's
# context + hit retry/abort loops. 7 is a conservative ceiling; the
# handler can still fix up to that many surgical finds.
HANDLER_MAX_INLINE_THREADS=$(_parse_positive_int "${CLAWDBOT_HANDLER_MAX_INLINE_THREADS:-7}" 7 CLAWDBOT_HANDLER_MAX_INLINE_THREADS)
HANDLER_CHANNEL="${CLAWDBOT_NOTIFY_CHANNEL:-telegram}"
HANDLER_TARGET="${CLAWDBOT_NOTIFY_TARGET:-}"

# Deliver a direct Telegram announce to the maintainer (used for merge /
# no-op bookkeeping reports that are informational, not actionable). Runs
# via ``openclaw message send`` which does not touch any LLM session.
_announce_to_maintainer() {
    local text="$1"
    if [ -z "$HANDLER_TARGET" ]; then
        echo "$LOG_PREFIX ⚠️ CLAWDBOT_NOTIFY_TARGET not set; cannot announce to maintainer" >&2
        return 1
    fi
    # ``openclaw message send`` takes ``--target``, not ``--to`` (unlike
    # ``openclaw cron add`` which takes ``--to``). Mismatch shipped in PR #24
    # as the helper was never tested against the real merge/no-op delivery
    # path; caught during post-PR#26 re-enable dry-tick.
    if openclaw message send \
        --channel "$HANDLER_CHANNEL" \
        --target "$HANDLER_TARGET" \
        --message "$text" >/dev/null 2>&1; then
        return 0
    fi
    echo "$LOG_PREFIX ⚠️ Failed to announce to maintainer; state not marked notified, will retry next tick" >&2
    return 1
}

# Wake the main orchestrator session (Sparky) with a system event. This
# mirrors the handler-runtime \`\`sessions_send\`\` escalation path the
# pr-review-hygiene skill documents — for bash-level short-circuits
# (oversized thread aggregates) we call this directly so Sparky gets
# explicitly notified, not just the maintainer's Telegram.
#
# The skill requires escalation messages to start with
# \`\`[ESCALATION] <pr_key>\`\`; callers are responsible for preserving
# that contract. \`\`--mode now\`\` enqueues immediately and triggers a
# heartbeat so Sparky picks up the event on her next tick.
_wake_main_session() {
    local text="$1"
    if openclaw system event \
        --mode now \
        --text "$text" \
        --timeout 5000 >/dev/null 2>&1; then
        return 0
    fi
    echo "$LOG_PREFIX ⚠️ Failed to wake main session; state not marked notified, will retry next tick" >&2
    return 1
}

# Spawn an isolated handler subagent for a structured PR event (review_comments
# or ci_failed). The agent gets the envelope as its message payload, runs
# with the pr-review-hygiene skill, acts end-to-end on the PR, and reports
# completion directly to the maintainer's configured channel.
#
# Main-session orchestrator (Sparky) is NOT involved — handlers own the
# full loop. If a handler needs judgment, it escalates via ``sessions_send``
# to the main session with an ``[ESCALATION]`` prefix.
#
# Returns 0 on successful spawn (cron job created), non-zero on failure so
# callers can skip the state-mark and retry on the next tick.
_spawn_handler_subagent() {
    local event="$1"         # review_comments | ci_failed
    local pr_key="$2"        # owner/repo#N
    local envelope="$3"      # header + footer + ```json\n<JSON>\n``` text payload
    # Portable timestamp via jq (gemini _Eb8): ``date -u +%s`` works on
    # Linux + BSD, but the rest of the script uses jq for time math, so
    # keep the tooling consistent.
    local name="pr-handler-${event}-$(echo "$pr_key" | tr '/#' '--')-$(jq -rn 'now | floor')"

    if [ -z "$HANDLER_TARGET" ]; then
        echo "$LOG_PREFIX ⚠️ CLAWDBOT_NOTIFY_TARGET not set; cannot spawn handler" >&2
        return 1
    fi

    # Dedup guard: suppress spawn if a handler for the same PR+event is
    # already scheduled or running. Without this, every tick (every 5 min)
    # re-spawns a new isolated Opus session for the same PR while the
    # previous one is still mid-flight — observed 2026-04-21: 14 overlapping
    # handlers for one PR in a single night, each reading a stale envelope
    # and thrashing on already-resolved threads until their timeout expired.
    #
    # Match strategy: strip the trailing ``-<unix_timestamp>`` suffix from
    # each cron job's name and compare the remainder EXACTLY to the
    # PR+event-specific prefix. This is strictly stricter than ``startswith``
    # so ``pr-handler-review_comments-owner-repo-31-*`` cannot collide with
    # ``pr-handler-review_comments-owner-repo-316-*`` (current code's
    # trailing ``-`` already disambiguates these cases but defence-in-depth
    # keeps us robust to future naming-format changes). gemini-code-assist
    # flagged on PR #35.
    #
    # We do NOT filter on ``state.runningAtMs != null``: a cron job scheduled
    # ``--at 10s`` is in the list but not yet firing for its first 10s, and
    # under scheduler backpressure the window grows. Either state (queued or
    # running) is in-flight for our purposes. ``--delete-after-run`` ensures
    # finished jobs disappear from the listing automatically, so any surviving
    # matching entry is genuinely unresolved work.
    #
    # Returns 2 on dedup skip so callers can distinguish "failed to spawn"
    # (return 1, retry next tick) from "didn't spawn because in-flight"
    # (return 2, skip state-mark AND skip retry until the running handler
    # finishes on its own).
    # Fail-closed on control-plane errors (coderabbit flagged on PR #35): if
    # ``openclaw cron list`` fails or returns invalid JSON, the pipeline-in-if
    # evaluates false and we would fall through to spawn a duplicate handler,
    # which is the exact scenario this guard exists to prevent. Capture the
    # listing separately so we can distinguish "listing failed" (skip this
    # tick, retry next) from "listing succeeded with zero matches" (safe to
    # spawn).
    local pr_prefix cron_jobs_json
    pr_prefix=$(echo "$pr_key" | tr '/#' '--')
    if ! cron_jobs_json=$(openclaw cron list --json 2>/dev/null); then
        echo "$LOG_PREFIX     ⚠️  Could not list existing handler crons for $pr_key ($event); skipping spawn this tick" >&2
        return 1
    fi
    # jq exit-code discipline (gemini flagged on PR #36):
    #   exit 0 → filter matched = dedup (rc=2)
    #   exit 1 → filter returned false/null = no dupe, safe to proceed
    #   exit >= 2 → jq failed to parse its input or hit an internal error
    #                = control-plane failure, skip this tick (rc=1) to
    #                  avoid fail-open duplicate-spawn. Using here-string
    #                  keeps the check single-process (no pipe) so $?
    #                  reflects jq directly without PIPESTATUS gymnastics.
    if jq -e --arg prefix "pr-handler-${event}-${pr_prefix}" '
            [.jobs[]?
             | select(.name | sub("-[0-9]+$"; "") == $prefix)
            ] | length > 0' <<< "$cron_jobs_json" >/dev/null 2>&1; then
        echo "$LOG_PREFIX     ⏭️  Handler already scheduled or running for $pr_key ($event); skipping spawn" >&2
        return 2
    elif [ $? -ge 2 ]; then
        echo "$LOG_PREFIX     ⚠️  Could not parse handler cron list JSON for $pr_key ($event); skipping spawn this tick" >&2
        return 1
    fi

    # Fire and forget — ``--at 10s --delete-after-run`` creates a one-shot
    # cron job that self-cleans after completion. The job itself uses
    # ``--session isolated`` + ``--message`` (kind=agentTurn) which is the
    # isolated-subagent primitive (same contract as sessions_spawn). The
    # agent's completion summary is announced to the configured channel.
    if openclaw cron add \
        --name "$name" \
        --session isolated \
        --at "10s" \
        --delete-after-run \
        --model "$HANDLER_MODEL" \
        --thinking "$HANDLER_THINKING" \
        --timeout-seconds "$HANDLER_TIMEOUT_SECONDS" \
        --announce \
        --channel "$HANDLER_CHANNEL" \
        --to "$HANDLER_TARGET" \
        --message "$envelope" >/dev/null 2>&1; then
        return 0
    fi
    echo "$LOG_PREFIX ⚠️ Failed to spawn handler subagent for $pr_key ($event); state not marked notified, will retry next tick" >&2
    return 1
}

# Redact common secret-ish patterns from CI log tails before shipping them
# to the orchestrator via `failed_job_logs`. CI runners routinely print raw
# request bodies, env dumps, and bearer tokens; forwarding those verbatim
# widens the blast radius of a single bad log line. Matches are conservative
# (false positives are fine; we'd rather redact a harmless string than leak
# a live token).
#
# Two-pass pipeline:
#   1. ``sed -z`` processes the whole input as a single NUL-delimited
#      record so multi-line PEM blocks match as a unit. We match the full
#      BEGIN...END envelope (greedy within the non-``-`` body is safe
#      because ``-`` only appears in the delimiter lines themselves).
#      If a PEM block is truncated (no END yet) the single-line pass in
#      step 2 still scrubs the BEGIN header.
#   2. Per-line pass for all single-line token patterns (Bearer, api_key,
#      gh/slack/openai/aws) which don't span newlines.
_redact_ci_logs() {
    sed -zE 's#(-----BEGIN[[:space:]]+[A-Z ][A-Z ]*PRIVATE[[:space:]]+KEY-----)[^-]*(-----END[[:space:]]+[A-Z ][A-Z ]*PRIVATE[[:space:]]+KEY-----)#\1<REDACTED>\2#g' \
    | sed -E \
        -e 's#(Authorization:[[:space:]]*Bearer[[:space:]]+)[A-Za-z0-9._/+=-]+#\1<REDACTED>#gi' \
        -e 's#(Authorization:[[:space:]]*Basic[[:space:]]+)[A-Za-z0-9+/=]+#\1<REDACTED>#gi' \
        -e 's#(Bearer[[:space:]]+)[A-Za-z0-9._/+=-]{20,}#\1<REDACTED>#gi' \
        -e 's#((api[_-]?key|apikey|access[_-]?token|auth[_-]?token|password|passwd|secret)["'\'':= ]+[\"]?)[A-Za-z0-9._/+=-]{8,}#\1<REDACTED>#gi' \
        -e 's#(gh[oprsu]_)[A-Za-z0-9]{30,}#\1<REDACTED>#g' \
        -e 's#(xox[abprs]-)[A-Za-z0-9-]{10,}#\1<REDACTED>#g' \
        -e 's#(sk-(proj-)?)[A-Za-z0-9_-]{20,}#\1<REDACTED>#g' \
        -e 's#(AKIA)[0-9A-Z]{16}#\1<REDACTED>#g'
}

# ─── Per-repo PR scan ────────────────────────────────────────────────────

MERGE_REASONS=""
NOTIFY_BLOBS=()
# READY_MAIN entries ("$PR_KEY|$COMMIT_SHA") queued during classification and
# committed to notified_main_prs only after the wake that announces them
# actually succeeds. See the MERGE_REASONS delivery block below.
PENDING_MAIN_NOTIFICATIONS=()

for REPO in $REPOS; do
    echo "$LOG_PREFIX Checking $REPO..."

    # NB: ``comments(first: 100)`` — NOT 15. Long review threads (bot +
    # human back-and-forth on a single finding) can exceed 20 comments and
    # the orchestrator contract is "full thread context", not "first page".
    # 100 is GitHub's max-per-page; anything beyond that we deliberately
    # log a warning about below and rely on the orchestrator pulling the
    # tail via the PR URL.
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
                id
                isResolved
                isOutdated
                comments(first: 100) {
                  totalCount
                  nodes {
                    id
                    body
                    author { login }
                    path
                    line
                    createdAt
                  }
                }
              }
            }
            commits(last: 1) {
              nodes {
                commit {
                  oid
                  statusCheckRollup {
                    state
                    contexts(first: 20) {
                      nodes {
                        __typename
                        ... on CheckRun { name conclusion status }
                        ... on StatusContext { context state }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }" 2>/dev/null) || {
        # Fail closed: a GraphQL fetch failure without this guard produced an
        # empty "no open PRs" response, which would then let the dev→main
        # auto-create branch at the bottom of the loop fire even when
        # feature PRs are actually in flight. Skipping the repo this tick
        # is strictly safer — the next tick will retry.
        echo "$LOG_PREFIX   ⚠️ GraphQL fetch failed for $REPO; skipping this tick" >&2
        continue
    }

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
            PR_KEY="${REPO}#${PR_NUM}"
            SHA_KEY="${PR_KEY}@${COMMIT_SHA}"

            echo "$LOG_PREFIX   PR #$PR_NUM ($PR_HEAD → $PR_BASE): mergeable=$MERGEABLE checks=$CHECK_STATE unresolved=$UNRESOLVED draft=$IS_DRAFT"

            if [ "$IS_DRAFT" = "true" ]; then
                continue
            fi
            if [ "$PR_AUTHOR" = "dependabot" ] || [ "$PR_AUTHOR" = "dependabot[bot]" ]; then
                echo "$LOG_PREFIX     Skipping dependabot PR (author=$PR_AUTHOR)"
                continue
            fi

            # ─── Classify the PR ─────────────────────────────────────────
            # Five terminal states (or skip/continue):
            #   READY_DEV      → auto-merge
            #   READY_MAIN     → notify the maintainer
            #   HAS_COMMENTS   → notify Sparky (after wait)
            #   CI_FAILED      → notify Sparky
            #   NOT_READY      → waiting (pending CI, conflicts, drafts,
            #                            or PR targets a branch that is
            #                            neither integration nor main)
            STATE=""
            if [ "$MERGEABLE" = "MERGEABLE" ] && [ "$CHECK_STATE" = "SUCCESS" ] && [ "$UNRESOLVED" -eq 0 ]; then
                if [ "$PR_BASE" = "$INTEGRATION_BRANCH" ]; then
                    STATE="READY_DEV"
                elif [ "$PR_BASE" = "$MAIN_BRANCH" ]; then
                    STATE="READY_MAIN"
                else
                    # PR targets some third branch (e.g. long-lived release
                    # line). Don't auto-merge, don't notify — a human should
                    # handle anything outside the two configured integration
                    # points.
                    STATE="NOT_READY"
                fi
            elif [ "$UNRESOLVED" -gt 0 ]; then
                STATE="HAS_COMMENTS"
            elif [ "$CHECK_STATE" = "FAILURE" ]; then
                STATE="CI_FAILED"
            else
                STATE="NOT_READY"
            fi

            case "$STATE" in
                READY_DEV)
                    HAS_OPEN_DEV_MAIN=$(echo "$PR_DATA" | jq --arg integration "$INTEGRATION_BRANCH" --arg main "$MAIN_BRANCH" '[.data.repository.pullRequests.nodes[] | select(.baseRefName == $main and .headRefName == $integration)] | length')
                    if [ "$HAS_OPEN_DEV_MAIN" -gt 0 ]; then
                        # Log-only: do NOT add to MERGE_REASONS. Otherwise
                        # every tick (every 5 minutes) re-wakes the
                        # orchestrator with the same "still holding"
                        # message until the blocker PR closes, which is
                        # noise for a known, expected interlock. The
                        # operator can grep the log file if they want a
                        # history; the state is also visible in GitHub
                        # (the feature PR is simply still open).
                        echo "$LOG_PREFIX     ⏸️ Holding $PR_KEY — open $INTEGRATION_BRANCH→$MAIN_BRANCH PR exists"
                        continue
                    fi
                    ALREADY_MERGED=$(jq -r ".merged_prs[\"$PR_KEY\"] // \"\"" "$STATE_FILE")
                    if [ -n "$ALREADY_MERGED" ]; then
                        echo "$LOG_PREFIX     Already merged (tracked)"
                        continue
                    fi
                    echo "$LOG_PREFIX     ✅ Auto-merging PR #$PR_NUM to development..."
                    if gh pr merge "$PR_NUM" --repo "$REPO" --squash --delete-branch 2>&1; then
                        MERGE_REASONS="${MERGE_REASONS}✅ Auto-merged $PR_KEY to development: $PR_TITLE\n   $PR_URL\n"
                        jq --arg key "$PR_KEY" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                            '.merged_prs[$key] = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                    else
                        echo "$LOG_PREFIX     ⚠️ Merge failed"
                        MERGE_REASONS="${MERGE_REASONS}⚠️ Auto-merge FAILED for $PR_KEY: $PR_TITLE\n   $PR_URL\n"
                    fi
                    ;;

                READY_MAIN)
                    NOTIFIED_SHA=$(jq -r ".notified_main_prs[\"$PR_KEY\"] // \"\"" "$STATE_FILE")
                    if [ "$NOTIFIED_SHA" = "$COMMIT_SHA" ]; then
                        echo "$LOG_PREFIX     Already notified the maintainer at this SHA"
                        continue
                    fi
                    MERGE_REASONS="${MERGE_REASONS}🟢 $PR_KEY ready to merge to main: $PR_TITLE\n   All comments resolved, checks green, mergeable.\n   $PR_URL\n"
                    # Defer the notified_main_prs write until after the
                    # MERGE_REASONS wake succeeds (see the delivery block
                    # further down). Marking a PR as notified before the
                    # wake silences that SHA on a dropped delivery and
                    # suppresses retries until another commit lands.
                    PENDING_MAIN_NOTIFICATIONS+=("$PR_KEY|$COMMIT_SHA")
                    ;;

                HAS_COMMENTS)
                    # Two-part decision:
                    # (a) has the 15-min review-wait window elapsed since first
                    #     observation of unresolved threads at this SHA?
                    # (b) have we already notified at this SHA, and if so, has
                    #     the renotification window elapsed?
                    NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                    FIRST_SEEN=$(jq -r ".first_seen_unresolved[\"$SHA_KEY\"] // \"\"" "$STATE_FILE")
                    LAST_NOTIFIED=$(jq -r ".notified_reviews[\"$SHA_KEY\"] // \"\"" "$STATE_FILE")
                    if [ -z "$FIRST_SEEN" ]; then
                        jq --arg key "$SHA_KEY" --arg ts "$NOW_ISO" \
                            '.first_seen_unresolved[$key] = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                        echo "$LOG_PREFIX     ⏱️ First observation at this SHA — starting ${REVIEW_WAIT_MINUTES}m review wait window"
                        continue
                    fi

                    WAIT_CUTOFF=$(_iso_minutes_ago "$REVIEW_WAIT_MINUTES")
                    if [ -z "$WAIT_CUTOFF" ]; then
                        echo "$LOG_PREFIX     ⚠️ review-wait cutoff computation failed; skipping this PR this tick (no notification, will retry next tick)" >&2
                        continue
                    fi
                    if [[ "$FIRST_SEEN" > "$WAIT_CUTOFF" ]]; then
                        echo "$LOG_PREFIX     ⏳ Still inside ${REVIEW_WAIT_MINUTES}m review wait window (since $FIRST_SEEN)"
                        continue
                    fi

                    if [ -n "$LAST_NOTIFIED" ]; then
                        RENOTIFY_CUTOFF=$(_iso_minutes_ago "$RENOTIFY_MINUTES")
                        if [ -z "$RENOTIFY_CUTOFF" ]; then
                            echo "$LOG_PREFIX     ⚠️ renotify cutoff computation failed; skipping re-notification this tick" >&2
                            continue
                        fi
                        if [[ "$LAST_NOTIFIED" > "$RENOTIFY_CUTOFF" ]]; then
                            echo "$LOG_PREFIX     🔕 Already notified at this SHA (since $LAST_NOTIFIED), within ${RENOTIFY_MINUTES}m renotification cooldown"
                            continue
                        fi
                        echo "$LOG_PREFIX     🔁 Renotifying — ${RENOTIFY_MINUTES}m elapsed since last notification, PR head unchanged"
                    fi

                    # Build structured payload for Sparky: PR metadata + all
                    # unresolved threads with their comments verbatim + CI
                    # rollup, so the orchestrator can plan without re-fetching.
                    PAYLOAD=$(echo "$PR" | jq --arg repo "$REPO" --arg pr_key "$PR_KEY" --arg sha "$COMMIT_SHA" --arg check_state "$CHECK_STATE" '{
                        event: "review_comments",
                        pr_key: $pr_key,
                        repo: $repo,
                        number: .number,
                        title: .title,
                        url: .url,
                        head: .headRefName,
                        base: .baseRefName,
                        head_sha: $sha,
                        ci_status: $check_state,
                        ci_contexts: [.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]? | . as $ctx | if .__typename == "CheckRun" then {type:"check", name: $ctx.name, conclusion: $ctx.conclusion, status: $ctx.status} else {type:"status", name: $ctx.context, conclusion: $ctx.state} end],
                        unresolved_threads: [
                            .reviewThreads.nodes[]
                            | select(.isResolved == false and .isOutdated == false)
                            | {
                                thread_id: .id,
                                comments: [.comments.nodes[] | {
                                    id: .id, author: .author.login, path: .path, line: .line,
                                    body: .body, created_at: .createdAt
                                }]
                              }
                        ]
                    }')
                    # Attach the state-update coordinates so the delivery loop
                    # below can mark "notified" only AFTER the wake succeeds.
                    # A dropped wake that had already been marked notified
                    # would suppress retries until RENOTIFY_MINUTES expires.
                    PAYLOAD=$(echo "$PAYLOAD" | jq --arg key "$SHA_KEY" --arg ts "$NOW_ISO" '. + {_state_key: "notified_reviews", _state_sha_key: $key, _state_ts: $ts}')
                    NOTIFY_BLOBS+=("$PAYLOAD")
                    echo "$LOG_PREFIX     📨 Queued notification to Sparky ($UNRESOLVED unresolved thread(s))"
                    ;;

                CI_FAILED)
                    # 0 unresolved threads but CI is red — ask Sparky to fix.
                    NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                    LAST_NOTIFIED=$(jq -r ".notified_ci[\"$SHA_KEY\"] // \"\"" "$STATE_FILE")
                    if [ -n "$LAST_NOTIFIED" ]; then
                        RENOTIFY_CUTOFF=$(_iso_minutes_ago "$RENOTIFY_MINUTES")
                        if [ -z "$RENOTIFY_CUTOFF" ]; then
                            echo "$LOG_PREFIX     ⚠️ renotify cutoff computation failed; skipping re-notification this tick" >&2
                            continue
                        fi
                        if [[ "$LAST_NOTIFIED" > "$RENOTIFY_CUTOFF" ]]; then
                            echo "$LOG_PREFIX     🔕 Already notified of CI failure at this SHA (since $LAST_NOTIFIED)"
                            continue
                        fi
                        echo "$LOG_PREFIX     🔁 Renotifying CI failure — ${RENOTIFY_MINUTES}m elapsed"
                    fi

                    # Collect failed-job log tails so Sparky doesn't need
                    # another tool-call round-trip to triage.
                    FAILED_LOGS=""
                    FAILED_JOBS=$(gh run list --repo "$REPO" --commit "$COMMIT_SHA" --status failure --json databaseId,name --jq '.[] | "\(.databaseId)|\(.name)"' 2>/dev/null || true)
                    if [ -n "$FAILED_JOBS" ]; then
                        while IFS='|' read -r RUN_ID RUN_NAME; do
                            [ -z "$RUN_ID" ] && continue
                            JOB_LOG=$(gh run view "$RUN_ID" --repo "$REPO" --log-failed 2>/dev/null | tail -100 | _redact_ci_logs 2>/dev/null || true)
                            if [ -n "$JOB_LOG" ]; then
                                FAILED_LOGS="${FAILED_LOGS}\n--- ${RUN_NAME} (run ${RUN_ID}) ---\n${JOB_LOG}\n"
                            fi
                        done <<< "$FAILED_JOBS"
                    fi

                    PAYLOAD=$(echo "$PR" | jq --arg repo "$REPO" --arg pr_key "$PR_KEY" --arg sha "$COMMIT_SHA" --arg check_state "$CHECK_STATE" --arg logs "$(printf '%b' "$FAILED_LOGS")" '{
                        event: "ci_failed",
                        pr_key: $pr_key,
                        repo: $repo,
                        number: .number,
                        title: .title,
                        url: .url,
                        head: .headRefName,
                        base: .baseRefName,
                        head_sha: $sha,
                        ci_status: $check_state,
                        ci_contexts: [.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]? | . as $ctx | if .__typename == "CheckRun" then {type:"check", name: $ctx.name, conclusion: $ctx.conclusion, status: $ctx.status} else {type:"status", name: $ctx.context, conclusion: $ctx.state} end],
                        failed_job_logs: $logs
                    }')
                    PAYLOAD=$(echo "$PAYLOAD" | jq --arg key "$SHA_KEY" --arg ts "$NOW_ISO" '. + {_state_key: "notified_ci", _state_sha_key: $key, _state_ts: $ts}')
                    NOTIFY_BLOBS+=("$PAYLOAD")
                    echo "$LOG_PREFIX     📨 Queued CI-failure notification to Sparky"
                    ;;

                NOT_READY)
                    if [ "$MERGEABLE" != "MERGEABLE" ]; then
                        echo "$LOG_PREFIX     Not ready: not mergeable ($MERGEABLE)"
                    elif [ "$CHECK_STATE" = "PENDING" ] || [ "$CHECK_STATE" = "EXPECTED" ]; then
                        echo "$LOG_PREFIX     Not ready: checks still running ($CHECK_STATE)"
                    else
                        echo "$LOG_PREFIX     Not ready: checks=$CHECK_STATE mergeable=$MERGEABLE"
                    fi
                    ;;
            esac

        done <<< "$PR_LIST"
    fi

    # ─── Fast-forward development to main / create dev→main PR ─────────
    # Validate the SHA lookups landed a real 40-char hex before proceeding.
    # When a branch doesn't exist on the remote (e.g. a fresh clone whose
    # integration branch was never pushed) the gh api call returns a JSON
    # 404 body, and ``--jq '.commit.sha'`` evaluates to ``null`` (printed
    # empty by ``-r``) OR the raw body slips through on some failure
    # modes. Either way the ``$MAIN_SHA != $DEV_SHA`` string comparison
    # that follows would accidentally proceed against garbage and the
    # downstream integer comparisons would blow up with non-integer
    # values. A strict hex regex here keeps the fast-forward / PR-create
    # branch strictly gated on real branch state.
    #
    # Fail closed: if either lookup fails transiently (network blip,
    # rate-limit, GitHub 5xx), skip the branch-sync tick for this repo
    # entirely rather than falling back to empty/0 which would make the
    # downstream gate equivalent to "no open PR, go ahead and act".
    if ! MAIN_SHA=$(gh api "repos/$REPO/branches/$MAIN_BRANCH" --jq '.commit.sha' 2>/dev/null); then
        echo "$LOG_PREFIX   ⚠️ Failed to fetch $MAIN_BRANCH SHA for $REPO; skipping branch-sync" >&2
        continue
    fi
    if [[ ! "$MAIN_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$LOG_PREFIX   ⚠️ Invalid $MAIN_BRANCH SHA for $REPO ('$MAIN_SHA'); skipping branch-sync" >&2
        continue
    fi
    if ! DEV_SHA=$(gh api "repos/$REPO/branches/$INTEGRATION_BRANCH" --jq '.commit.sha' 2>/dev/null); then
        echo "$LOG_PREFIX   ⚠️ Failed to fetch $INTEGRATION_BRANCH SHA for $REPO; skipping branch-sync" >&2
        continue
    fi
    if [[ ! "$DEV_SHA" =~ ^[0-9a-f]{40}$ ]]; then
        echo "$LOG_PREFIX   ⚠️ Invalid $INTEGRATION_BRANCH SHA for $REPO ('$DEV_SHA'); skipping branch-sync" >&2
        continue
    fi

    if [ "$MAIN_SHA" != "$DEV_SHA" ]; then
        # Same fail-closed discipline for the ahead/behind counts and the
        # open-PR count: a transient 404 on the ``compare`` endpoint
        # (observed 2026-04-19 mid-refactor) used to return a JSON body
        # that fell through ``|| echo "0"`` into a ``[ "$BEHIND" -gt 0 ]``
        # test, producing the bash "integer expression expected" error
        # and silently skipping the action. Worse, coercing a failed
        # ``gh pr list`` to ``0`` used to make the fast-forward / PR-
        # create gate treat "I couldn't tell" as "no open PR, safe to
        # act" — exactly the wrong direction for a write operation on a
        # shared branch. Skip the tick on any lookup failure or non-
        # integer response and let the next tick retry.
        if ! BEHIND=$(gh api "repos/$REPO/compare/${INTEGRATION_BRANCH}...${MAIN_BRANCH}" --jq '.ahead_by' 2>/dev/null); then
            echo "$LOG_PREFIX   ⚠️ compare ${INTEGRATION_BRANCH}...${MAIN_BRANCH} failed for $REPO; skipping branch-sync" >&2
            continue
        fi
        if [[ ! "$BEHIND" =~ ^[0-9]+$ ]]; then
            echo "$LOG_PREFIX   ⚠️ Invalid BEHIND value for $REPO ('$BEHIND'); skipping branch-sync" >&2
            continue
        fi
        if ! AHEAD=$(gh api "repos/$REPO/compare/${MAIN_BRANCH}...${INTEGRATION_BRANCH}" --jq '.ahead_by' 2>/dev/null); then
            echo "$LOG_PREFIX   ⚠️ compare ${MAIN_BRANCH}...${INTEGRATION_BRANCH} failed for $REPO; skipping branch-sync" >&2
            continue
        fi
        if [[ ! "$AHEAD" =~ ^[0-9]+$ ]]; then
            echo "$LOG_PREFIX   ⚠️ Invalid AHEAD value for $REPO ('$AHEAD'); skipping branch-sync" >&2
            continue
        fi
        if ! EXISTING_DEV_MAIN=$(gh pr list --repo "$REPO" --base "$MAIN_BRANCH" --head "$INTEGRATION_BRANCH" --state open --json number --jq 'length' 2>/dev/null); then
            echo "$LOG_PREFIX   ⚠️ Could not determine existing ${INTEGRATION_BRANCH}→${MAIN_BRANCH} PR count for $REPO; skipping branch-sync" >&2
            continue
        fi
        if [[ ! "$EXISTING_DEV_MAIN" =~ ^[0-9]+$ ]]; then
            echo "$LOG_PREFIX   ⚠️ Invalid ${INTEGRATION_BRANCH}→${MAIN_BRANCH} PR count for $REPO ('$EXISTING_DEV_MAIN'); skipping branch-sync" >&2
            continue
        fi

        if [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -eq 0 ] && [ "$EXISTING_DEV_MAIN" -eq 0 ]; then
            echo "$LOG_PREFIX   ⏩ Fast-forwarding $INTEGRATION_BRANCH to $MAIN_BRANCH ($BEHIND commits behind)..."
            if gh api "repos/$REPO/git/refs/heads/$INTEGRATION_BRANCH" -X PATCH -f sha="$MAIN_SHA" 2>/dev/null; then
                echo "$LOG_PREFIX   ✅ $INTEGRATION_BRANCH fast-forwarded to $MAIN_BRANCH"
                MERGE_REASONS="${MERGE_REASONS}⏩ $REPO: $INTEGRATION_BRANCH fast-forwarded to $MAIN_BRANCH\n"
            else
                echo "$LOG_PREFIX   ⚠️ Fast-forward failed"
            fi
        elif [ "$AHEAD" -gt 0 ] && [ "$EXISTING_DEV_MAIN" -eq 0 ]; then
            OPEN_FEATURE_TO_DEV=$(echo "$PR_DATA" | jq --arg integration "$INTEGRATION_BRANCH" '[.data.repository.pullRequests.nodes[] | select(.baseRefName == $integration and .isDraft == false)] | length')
            if [ "$OPEN_FEATURE_TO_DEV" -gt 0 ]; then
                echo "$LOG_PREFIX   ⏸️ Not creating ${INTEGRATION_BRANCH}→${MAIN_BRANCH} PR — $OPEN_FEATURE_TO_DEV open feature→${INTEGRATION_BRANCH} PR(s) still in flight"
            else
                CREATED_SHA=$(jq -r ".created_dev_main_prs[\"$REPO\"] // \"\"" "$STATE_FILE")
                if [ "$DEV_SHA" != "$CREATED_SHA" ]; then
                    echo "$LOG_PREFIX   Creating ${INTEGRATION_BRANCH} → ${MAIN_BRANCH} PR for $REPO ($AHEAD commits ahead)..."
                    PR_RESULT=$(gh pr create --repo "$REPO" --base "$MAIN_BRANCH" --head "$INTEGRATION_BRANCH" \
                        --title "${INTEGRATION_BRANCH} into ${MAIN_BRANCH}" \
                        --body "Automated PR: ${INTEGRATION_BRANCH} → ${MAIN_BRANCH} ($AHEAD commits ahead)" 2>&1 || true)
                    if echo "$PR_RESULT" | grep -q "https://github.com"; then
                        PR_LINK=$(echo "$PR_RESULT" | grep -o "https://github.com[^ ]*")
                        MERGE_REASONS="${MERGE_REASONS}🔀 Created ${INTEGRATION_BRANCH} → ${MAIN_BRANCH} PR for $REPO ($AHEAD commits ahead)\n   $PR_LINK\n"
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

# ─── Deliver queued notifications as handler subagent spawns ─────────────
# One isolated handler per event. Each handler owns its PR end-to-end:
# aggregate comments, plan, fix inline or delegate to a swarm agent, commit,
# reply + resolve threads, report completion to the maintainer. The main
# orchestrator (Sparky) is NOT in the loop — handlers escalate only when
# they need a product/design decision.
for BLOB in "${NOTIFY_BLOBS[@]}"; do
    EVENT=$(echo "$BLOB" | jq -r '.event')
    PR_KEY=$(echo "$BLOB" | jq -r '.pr_key')
    STATE_KEY=$(echo "$BLOB" | jq -r '._state_key // empty')
    STATE_SHA_KEY=$(echo "$BLOB" | jq -r '._state_sha_key // empty')
    STATE_TS=$(echo "$BLOB" | jq -r '._state_ts // empty')

    if [ "$EVENT" = "review_comments" ]; then
        THREAD_COUNT=$(echo "$BLOB" | jq '.unresolved_threads | length')

        # Thread-count escalation gate (gemini _BbKB). A PR with more than
        # HANDLER_MAX_INLINE_THREADS unresolved threads is orchestration
        # work, not surgical review-fix work — handlers that tried to
        # chew through 15-thread envelopes on 2026-04-19 hit token/abort
        # loops mid-run. Short-circuit in bash instead of paying for an
        # LLM spawn whose only job is to count and exit.
        #
        # Two-channel delivery (coderabbit _BgUR, clawdbot#26 round 2).
        # Telegram alone is fire-and-forget — the maintainer sees it but
        # the main orchestrator session (Sparky) stays unaware, which
        # violates the documented ``sessions_send`` escalation contract
        # in the pr-review-hygiene skill. So we BOTH announce to the
        # maintainer AND wake Sparky. State is only marked notified when
        # both deliveries succeed — a partial failure leaves the SHA
        # "not notified" so the next tick retries.
        if [ "$THREAD_COUNT" -gt "$HANDLER_MAX_INLINE_THREADS" ]; then
            PR_URL=$(echo "$BLOB" | jq -r '.url')
            THREAD_IDS=$(echo "$BLOB" | jq -r '[.unresolved_threads[].thread_id] | join(",")')
            ESCALATION_MSG=$(printf '[ESCALATION] %s has %s unresolved review thread(s) — above the inline-handler threshold (%s). Aggregate review PRs are orchestration work. threads=%s url=%s' \
                "$PR_KEY" "$THREAD_COUNT" "$HANDLER_MAX_INLINE_THREADS" "$THREAD_IDS" "$PR_URL")
            echo "$LOG_PREFIX     🚨 Thread count $THREAD_COUNT > $HANDLER_MAX_INLINE_THREADS; escalating to maintainer + main session (no handler spawn)"
            ANNOUNCE_OK=0
            WAKE_OK=0
            _announce_to_maintainer "$ESCALATION_MSG" && ANNOUNCE_OK=1
            _wake_main_session       "$ESCALATION_MSG" && WAKE_OK=1
            if [ "$ANNOUNCE_OK" -eq 1 ] && [ "$WAKE_OK" -eq 1 ]; then
                if [ -n "$STATE_KEY" ] && [ -n "$STATE_SHA_KEY" ] && [ -n "$STATE_TS" ]; then
                    jq --arg state_key "$STATE_KEY" --arg sha_key "$STATE_SHA_KEY" --arg ts "$STATE_TS" \
                        '.[$state_key][$sha_key] = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
                fi
            else
                echo "$LOG_PREFIX     ⚠️ Escalation partial (announce=$ANNOUNCE_OK wake=$WAKE_OK); not marking notified, will retry next tick" >&2
            fi
            continue
        fi

        HEADER="📝 PR handler: $PR_KEY has $THREAD_COUNT unresolved review thread(s) and the ${REVIEW_WAIT_MINUTES}m wait window has elapsed."
        FOOTER="You are an isolated handler subagent. Read the pr-review-hygiene skill first, then own this PR end-to-end via the pr-worktree pattern (~/pr-work/<repo>/pr-<N>/): commit fixes, push, reply + resolve each thread.

INSTRUCTIONS

1. Read pr-review-hygiene skill BEFORE touching the PR.
2. Read the envelope JSON from the file path shown below this instruction block (use the ``read`` tool, then ``jq`` if you need to slice it). The envelope has the PR id, url, head_sha, CI status, and the full list of unresolved threads with author/path/line/body/created_at for each comment.
3. Emit ZERO intermediate assistant text. Every assistant message gets announced to the maintainer's Telegram, so intermediate 'Now let me...' narrations spam the chat. Do all reasoning silently via tool-use. Produce exactly ONE final text reply at the end.
4. Escalate via sessions_send to main label='main' for any product/design call you can't make unilaterally. The escalation message MUST start with '[ESCALATION] ${PR_KEY} ' and include the affected thread_ids so the main session knows which PR and which threads you couldn't handle.

Step 0 (staleness check, MANDATORY before any other work):

The envelope was written by pr-manager at tick time, up to several minutes before this handler actually fires. The PR state may have moved on since then — the maintainer or another handler may have merged, closed, pushed new commits, or resolved threads. Acting on a stale envelope wastes the full per-handler token budget on no-ops and thrashes GitHub API calls against resolved threads.

Before touching any file or thread, fetch CURRENT state with gh and cross-check against the envelope:

  a) Run: gh pr view <pr_number> --repo <owner/repo> --json state,mergedAt,closedAt,headRefOid
     - If state != OPEN: reply '✅ <short-repo>#<n>: PR already merged/closed, no action taken' and exit. Do NOT attempt commits or thread replies.
     - If headRefOid != the envelope's head_sha: new commits landed since the envelope was written. Reply '⚠️ <short-repo>#<n> needs you — new commits landed since my task was queued' and exit. Do NOT attempt to graft your own fixes onto a branch tip you haven't read.

  b) Run the same GraphQL query the envelope used to count unresolved threads. The graphql body should match the one the envelope-writer in pr-manager.sh uses: fetch reviewThreads (first:100) with id/isResolved/isOutdated, then filter isResolved == false AND isOutdated == false, and count.
     - If 0 unresolved: reply '✅ <short-repo>#<n>: all threads already resolved, no action taken' and exit.
     - If the set differs significantly from the envelope (e.g. envelope listed 5 threads, only 1 unresolved now): work only the currently-unresolved subset. Do not reply to or re-open threads that are already resolved.

This check costs you ~2 tool calls and under 5 seconds. Skipping it costs up to 90 minutes and a full Opus budget on work that was already done. Run it.

Final reply format — this lands in the maintainer's Telegram. Humans read it on their phone. Keep it short, human, tappable.

Success path — two lines:
  ✅ <short-repo>#<number>: <one plain-English sentence>
  <url>

Example sentences:
  - 3 review threads resolved, mobile drag regression fixed
  - CI failure addressed, 112/112 tests green
  - 2 of 4 threads resolved, 2 deferred pending a product call

Escalation path — two lines:
  ⚠️ <short-repo>#<number> needs you — <one plain-English reason>
  <url>

Escalation examples:
  - 15 review threads, too many to handle inline
  - coderabbit + cursor disagree on the fix, design call needed

Rules:
- Two lines only. No preamble, no structured tags, no SHA, no mergeStateStatus, no head or base annotations, no markdown fences.
- Start with the emoji, then <short-repo>#<number>. <short-repo> is the suffix after the slash in pr_key.
- Keep the sentence under 100 characters. No jargon like isOutdated / ContextVar / mergeStateStatus — plain English.

Internal verification — NOT shown to the maintainer. Before posting the success reply, confirm the PR state via gh pr view and the unresolved-threads GraphQL actually matches what you plan to claim. If it does not, use the escalation format.

For escalations you route via sessions_send to the main session label=main, the sessions_send body MUST still carry the structured context [ESCALATION] ${PR_KEY} head=<head_branch> base=<base_branch> reason=<reason> threads=<comma-separated thread_ids> — the main-session orchestrator needs those fields. The Telegram announce to the maintainer stays human."
    else
        HEADER="🔴 PR handler: $PR_KEY has a failed CI run (all review threads resolved)."
        FOOTER="You are an isolated handler subagent. Read the pr-review-hygiene skill first, then fix the failed CI via the pr-worktree pattern (~/pr-work/<repo>/pr-<N>/).

INSTRUCTIONS

1. Read pr-review-hygiene skill BEFORE touching the PR.
2. Read the envelope JSON from the file path shown below this instruction block (use the ``read`` tool, then ``jq`` if you need to slice it). ``failed_job_logs`` has the tail of the red job.
3. Emit ZERO intermediate assistant text. Every assistant message gets announced to the maintainer's Telegram, so narrations spam the chat. Do all reasoning silently via tool-use. Produce exactly ONE final text reply at the end.
4. Escalate via sessions_send to main label='main' if the failure is infra-level (not a code bug) or requires a design call. The escalation message MUST start with '[ESCALATION] ${PR_KEY} ' so the main session can route it.

Step 0 (staleness check, MANDATORY before any other work):

The envelope and the failing-job log tail were captured at pr-manager tick time, up to several minutes before this handler fires. The PR and its CI may have moved on since then — the run may have been retried and gone green, the PR may have been merged or closed, or new commits may have landed.

Before touching any file, fetch CURRENT state:

  a) Run: gh pr view <pr_number> --repo <owner/repo> --json state,mergedAt,closedAt,headRefOid
     - If state != OPEN: reply '✅ <short-repo>#<n>: PR already merged/closed, no action taken' and exit.
     - If headRefOid != the envelope's head_sha: reply '⚠️ <short-repo>#<n> needs you — new commits landed since my task was queued' and exit.

  b) Run: gh pr checks <pr_number> --repo <owner/repo>
     - If CI is now green or the failing job is re-running: reply '✅ <short-repo>#<n>: CI already re-ran green, no action taken' and exit (or wait briefly if mid-retry, but do not duplicate-fix).

This check is cheap. Skipping it burns the full handler budget on already-fixed failures.

Final reply format — this lands in the maintainer's Telegram. Keep it short, human, tappable.

Success path — two lines:
  ✅ <short-repo>#<number>: <one plain-English sentence about the fix>
  <url>

Escalation path — two lines:
  ⚠️ <short-repo>#<number> needs you — <one plain-English reason>
  <url>

Rules: same as the review_comments branch. No SHA, no mergeStateStatus, no (head→base) annotation, no jargon, under 100 chars, start with emoji + short repo name. The sessions_send body for escalations still carries the structured [ESCALATION] envelope for main-session routing."
    fi

    # Envelope is written to a TEMP FILE and the handler is told to
    # ``Read`` it — rather than inlining the JSON (fenced or labeled)
    # inside the ``--message`` argument passed to ``openclaw cron add``.
    # This mirrors the original Apr 14 design (clawdbot@6c80d2a) which
    # never hit JSON-parse errors regardless of comment-body contents.
    #
    # Why file-based wins: review-bot comment bodies routinely contain
    # nested ```typescript / ```diff / ```markdown fences (cursor,
    # coderabbit, gemini, greptile) AND now-and-again partial-stream
    # truncation inside the subagent's own tool-call ``arguments``
    # serialization when context rebuilds mid-reply. Both classes of
    # bug vanish when the envelope never has to round-trip through
    # the agent's prompt-text parser at all — the handler just calls
    # ``read(path)`` and jq-parses the raw file.
    #
    # Filename includes the epoch-seconds so parallel ticks for the
    # same PR don't collide. Stale files are reaped at the end of
    # this script (``find /tmp -name 'pr-handler-*.json' -mtime +1``).
    ENVELOPE_FILE=$(printf '/tmp/pr-handler-%s-%s.json' "$(echo "$PR_KEY" | tr '/#' '--')" "$(jq -rn 'now | floor')")
    echo "$BLOB" | jq 'del(._state_key, ._state_sha_key, ._state_ts)' > "$ENVELOPE_FILE"

    TEXT=$(printf '%s\n\n%s\n\nRead the envelope JSON at: %s\n' "$HEADER" "$FOOTER" "$ENVELOPE_FILE")

    # ``set -euo pipefail`` (line 41) is active here; a non-zero return from
    # _spawn_handler_subagent would otherwise abort the whole script before
    # ``SPAWN_RC=$?`` can capture it — which would skip the dedup (rc=2) and
    # generic-failure (rc=1) cleanup paths and crash the tick mid-loop, so
    # the rest of the notification queue never fires. coderabbit caught
    # on PR #35. Capture via ``|| SPAWN_RC=$?`` so failures do not trip errexit.
    SPAWN_RC=0
    _spawn_handler_subagent "$EVENT" "$PR_KEY" "$TEXT" || SPAWN_RC=$?
    case "$SPAWN_RC" in
        0)
            echo "$LOG_PREFIX 🤖 Spawned handler subagent for $PR_KEY ($EVENT)"
            # Only now mark the SHA as notified. A failed spawn stays "not
            # notified" in state so the next tick retries immediately instead
            # of waiting for RENOTIFY_MINUTES.
            if [ -n "$STATE_KEY" ] && [ -n "$STATE_SHA_KEY" ] && [ -n "$STATE_TS" ]; then
                jq --arg state_key "$STATE_KEY" --arg sha_key "$STATE_SHA_KEY" --arg ts "$STATE_TS" \
                    '.[$state_key][$sha_key] = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            fi
            ;;
        2)
            # Dedup skip: a handler for this PR is already running. Drop the
            # freshly-written envelope file so /tmp doesn't accumulate stale
            # envelopes, and leave the notified-review state un-marked so
            # this tick is a no-op and the next tick re-evaluates once the
            # in-flight handler finishes.
            rm -f "$ENVELOPE_FILE"
            ;;
        *)
            # Generic spawn failure: already logged inside _spawn_handler_subagent.
            # Drop the envelope so /tmp doesn't accumulate; next tick retries.
            rm -f "$ENVELOPE_FILE"
            ;;
    esac
done

# ─── Merge/notification events (PR-lifecycle bookkeeping, not reviews) ────
if [ -n "$MERGE_REASONS" ]; then
    WAKE_TEXT=$(printf '🔧 PR Manager report:\n\n%b' "$MERGE_REASONS")
    # Commit the notified_main_prs entries only AFTER a successful wake.
    # A dropped delivery leaves the SHA "not notified" so the next tick
    # retries, matching the review/CI notification contract above.
    if _announce_to_maintainer "$WAKE_TEXT"; then
        for pending in "${PENDING_MAIN_NOTIFICATIONS[@]:-}"; do
            [ -z "$pending" ] && continue
            pending_key="${pending%%|*}"
            pending_sha="${pending##*|}"
            jq --arg key "$pending_key" --arg sha "$pending_sha" \
                '.notified_main_prs[$key] = $sha' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        done
    fi
fi

# ─── State hygiene ───────────────────────────────────────────────────────
# Drop SHA-keyed entries older than 7 days (per-commit bookkeeping only
# needs to live until the next rebase/force-push at most).
# 7-day cutoff. If the portable ``_iso_minutes_ago`` fails for some reason
# we skip the prune entirely instead of the pre-refactor behaviour of
# falling back to *now*, which would delete every state entry on every
# tick and effectively reset wait/renotify bookkeeping.
CUTOFF_7D=$(jq -rn 'now - 604800 | strftime("%Y-%m-%dT%H:%M:%SZ")' 2>/dev/null || true)
if [ -z "$CUTOFF_7D" ]; then
    echo "$LOG_PREFIX ⚠️ 7-day cutoff computation failed; skipping state housekeeping this tick" >&2
else
    jq --arg cutoff "$CUTOFF_7D" '
      .first_seen_unresolved = (.first_seen_unresolved // {} | to_entries | map(select(.value > $cutoff)) | from_entries)
      | .notified_reviews = (.notified_reviews // {} | to_entries | map(select(.value > $cutoff)) | from_entries)
      | .notified_ci = (.notified_ci // {} | to_entries | map(select(.value > $cutoff)) | from_entries)
    ' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

# Reap handler-envelope temp files older than 24h. A successful handler
# run doesn't need the envelope anymore (it's already been read into
# the isolated session's context). Handlers that failed or were killed
# mid-run also leave files behind — 24h is generous enough that a
# long-running handler (20 min cap) can't race the reaper.
find /tmp -maxdepth 1 -name 'pr-handler-*.json' -mtime +1 -delete 2>/dev/null || true

echo "$LOG_PREFIX Done."
