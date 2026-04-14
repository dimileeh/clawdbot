#!/usr/bin/env bash
# pr-hygiene.sh
# Safe PR hygiene automation:
# 1) Auto-merge truly ready PRs (clean/mergeable + CI pass + no pending Cursor patch token)
# 2) Auto-close superseded PRs (all meaningful changed files already covered by a newer merged PR)
# 3) When development queue is empty, auto-open sync PR: development -> main (never auto-merge it)
# SAFETY: NEVER auto-merge non-development PRs (e.g., main/master). Human-only.

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

read -ra REPOS <<< "${CLAWDBOT_REPOS}"
BASE_BRANCH="development"
MERGED_LOOKBACK_DAYS=2

NOISE_FILE_REGEX='^(\.clawdbot_prompt\.md|AGENTS\.md|package-lock\.json|pnpm-lock\.yaml|\.gitignore)$'

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

say() { printf '%s\n' "$*"; }

ci_state() {
  local pr="$1" repo="$2"
  local raw
  raw=$(gh pr checks "$pr" --repo "$repo" --json name,state 2>/dev/null || true)
  if [[ -z "$raw" || "$raw" == "[]" ]]; then
    echo "none"; return
  fi
  echo "$raw" | jq -r '[.[] | select(.state != "SKIPPED") | .state] as $checks
    | if ($checks | length) == 0 then "none"
      elif all($checks[]; . == "SUCCESS" or . == "NEUTRAL") then "pass"
      elif any($checks[]; . == "FAILURE") then "fail"
      else "pending" end'
}

cursor_pending_patch() {
  local pr_json="$1"
  local latest tokens tok handled unresolved
  latest=$(echo "$pr_json" | jq -r '.commits[-1].committedDate // ""')

  tokens=$(echo "$pr_json" | jq -r --arg latest "$latest" '
    [.comments[]?
     | select(.author.login == "cursor")
     | select(.body | test("BUGBOT_AUTOFIX_COMMENT"; "i"))
     | select($latest == "" or .createdAt > $latest)
     | (.body | capture("@cursor push (?<tok>[a-f0-9]{8,})"; "i").tok // empty)
    ] | unique | .[]')

  [[ -z "$tokens" ]] && { echo "false"; return; }

  unresolved=0
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    handled=$(echo "$pr_json" | jq -r --arg tok "$tok" '
      [ .comments[]?
        | select((.body|test("@cursor push " + $tok; "i")) or (.body|test("\\[Spark Cursor Decision token:" + $tok + "\\]"; "i")))
      ] | length')
    # count includes the original cursor comment carrying the token
    if [[ "$handled" -le 1 ]]; then
      unresolved=$((unresolved + 1))
    fi
  done <<< "$tokens"

  if [[ "$unresolved" -gt 0 ]]; then echo "true"; else echo "false"; fi
}

bugbot_state() {
  local pr_json="$1"
  echo "$pr_json" | jq -r '
    ([.statusCheckRollup[]? | select(.name == "Cursor Bugbot")][0]) as $b |
    if $b == null then "MISSING"
    elif ($b.status // "") != "COMPLETED" then "PENDING"
    elif ($b.conclusion // "") == "SUCCESS" then "SUCCESS"
    elif ($b.conclusion // "") == "NEUTRAL" then "SUCCESS"
    elif ($b.conclusion // "") == "" then "PENDING"
    else "NOT_SUCCESS"
    end'
}


files_for_pr() {
  local pr="$1" repo="$2"
  gh pr diff "$pr" --repo "$repo" --name-only 2>/dev/null | sed '/^$/d' | sort -u
}

meaningful_files() {
  grep -Ev "$NOISE_FILE_REGEX" || true
}

is_subset() {
  local a="$1" b="$2"
  # return success if every line in a exists in b
  if [[ ! -s "$a" ]]; then
    return 1
  fi
  while IFS= read -r line; do
    grep -Fxq "$line" "$b" || return 1
  done < "$a"
  return 0
}

ensure_sync_pr_main() {
  local repo="$1"

  # Only when no open PRs targeting development remain.
  local open_dev
  open_dev=$(gh pr list --repo "$repo" --state open --base "$BASE_BRANCH" --json number --jq 'length' 2>/dev/null || echo 0)
  if [[ "$open_dev" != "0" ]]; then
    return 0
  fi

  # If a sync PR already exists (development -> main), do nothing.
  local existing
  existing=$(gh pr list --repo "$repo" --state open --base main --head development --json number --jq 'length' 2>/dev/null || echo 0)
  if [[ "$existing" != "0" ]]; then
    return 0
  fi

  # Open sync PR only if development is ahead of main.
  local ahead
  ahead=$(gh api "repos/$repo/compare/main...development" --jq '.ahead_by' 2>/dev/null || echo 0)
  if [[ "$ahead" == "0" ]]; then
    return 0
  fi

  local title="chore(release): sync development into main"
  local body="Auto-created by pr-hygiene.sh after development queue reached zero.\n\n- Base: main\n- Head: development\n- Please run final review/checks and merge manually."

  if gh pr create --repo "$repo" --base main --head development --title "$title" --body "$body" >/dev/null 2>&1; then
    local url
    url=$(gh pr list --repo "$repo" --state open --base main --head development --json url --jq '.[0].url' 2>/dev/null || echo "")
    say "📦 Opened sync PR: $repo development->main ${url}"
    ACTIONS=$((ACTIONS + 1))
  fi
}

scan_main_pr_feedback() {
  local repo="$1"

  # Evaluate main-targeted PRs with the same readiness conditions as development,
  # but never auto-merge (human-only merge for main).
  while IFS= read -r PR_NUM; do
    [[ -z "$PR_NUM" ]] && continue
    local view
    view=$(gh pr view "$PR_NUM" --repo "$repo" --json number,title,url,mergeable,mergeStateStatus,isDraft,reviewDecision,comments,commits,statusCheckRollup 2>/dev/null || echo '{}')

    local cursor_pending ci url mergeable merge_state draft review bugbot reason title
    title=$(echo "$view" | jq -r '.title // ""')
    cursor_pending=$(cursor_pending_patch "$view")
    ci=$(ci_state "$PR_NUM" "$repo")
    url=$(echo "$view" | jq -r '.url // ""')
    mergeable=$(echo "$view" | jq -r '.mergeable // "UNKNOWN"')
    merge_state=$(echo "$view" | jq -r '.mergeStateStatus // "UNKNOWN"')
    draft=$(echo "$view" | jq -r '.isDraft // false')
    review=$(echo "$view" | jq -r '.reviewDecision // "none"')
    bugbot=$(bugbot_state "$view")

    reason=""
    if [[ "$draft" == "true" ]]; then
      reason="DRAFT"
    elif [[ "$mergeable" == "CONFLICTING" ]]; then
      reason="CONFLICTING"
    elif [[ "$merge_state" == "DIRTY" ]]; then
      reason="DIRTY"
    elif ! [[ "$ci" =~ ^(pass|none)$ ]]; then
      reason="CI:${ci}"
    elif [[ "$bugbot" != "SUCCESS" ]]; then
      reason="BUGBOT:${bugbot}"
    elif [[ "$cursor_pending" == "true" ]]; then
      reason="CURSOR_ACTION_NEEDED"
    elif [[ "$review" == "CHANGES_REQUESTED" || "$review" == "REVIEW_REQUIRED" ]]; then
      reason="REVIEW_REQUIRED"
    fi

    if [[ -n "$reason" ]]; then
      say "📝 Main PR needs action: $repo #$PR_NUM | ${reason} | merge:${mergeable}/${merge_state} | ci:${ci} | bugbot:${bugbot} | review:${review} | $url"
      ACTIONS=$((ACTIONS + 1))
      continue
    fi

    say "✅ Main PR ready for manual merge: $repo #$PR_NUM — $title | merge:${mergeable}/${merge_state} | ci:${ci} | bugbot:${bugbot} | review:${review} | $url"
    ACTIONS=$((ACTIONS + 1))
  done < <(gh pr list --repo "$repo" --state open --base main --json number --jq '.[].number' )
}

ACTIONS=0

for REPO in "${REPOS[@]}"; do
  # -------- auto-merge ready PRs --------
  while IFS= read -r PR_NUM; do
    [[ -z "$PR_NUM" ]] && continue
    VIEW=$(gh pr view "$PR_NUM" --repo "$REPO" --json number,title,url,baseRefName,author,mergeable,mergeStateStatus,isDraft,comments,commits,statusCheckRollup 2>/dev/null || echo '{}')

    # Hard guard: auto-merge only PRs targeting development.
    BASE=$(echo "$VIEW" | jq -r '.baseRefName // ""')
    if [[ "$BASE" != "$BASE_BRANCH" ]]; then
      continue
    fi

    AUTHOR=$(echo "$VIEW" | jq -r '.author.login // ""')
    if [[ "$REPO" == "${CLAWDBOT_DEPENDABOT_REPO:-}" ]] && [[ "$AUTHOR" == *"dependabot"* ]]; then
      case "$PR_NUM" in
        96|95|94|93|92|91)
          # Special-case Dependabot dependency updates: manual review first.
          continue
          ;;
      esac
    fi

    DRAFT=$(echo "$VIEW" | jq -r '.isDraft // false')
    MERGEABLE=$(echo "$VIEW" | jq -r '.mergeable // "UNKNOWN"')
    MERGE_STATE=$(echo "$VIEW" | jq -r '.mergeStateStatus // "UNKNOWN"')
    CURSOR_PENDING=$(cursor_pending_patch "$VIEW")
    BUGBOT=$(bugbot_state "$VIEW")
    CI=$(ci_state "$PR_NUM" "$REPO")

    if [[ "$DRAFT" == "true" ]]; then
      continue
    fi

    if [[ "$MERGEABLE" != "CONFLICTING" && "$MERGE_STATE" != "DIRTY" && "$CI" =~ ^(pass|none)$ && "$BUGBOT" == "SUCCESS" && "$CURSOR_PENDING" == "false" ]]; then
      if gh pr merge "$PR_NUM" --repo "$REPO" --squash --delete-branch >/dev/null 2>&1; then
        URL=$(echo "$VIEW" | jq -r '.url')
        TITLE=$(echo "$VIEW" | jq -r '.title')
        say "✅ Merged: $REPO #$PR_NUM — $TITLE — $URL"
        ACTIONS=$((ACTIONS + 1))
      fi
    fi
  done < <(gh pr list --repo "$REPO" --state open --base "$BASE_BRANCH" --json number --jq '.[].number')

  # -------- close superseded PRs --------
  cutoff_date=$(date -u -d "$MERGED_LOOKBACK_DAYS days ago" +%Y-%m-%d)

  MERGED_JSON=$(gh pr list --repo "$REPO" --state merged --base "$BASE_BRANCH" --search "merged:>=$cutoff_date" --limit 40 --json number,mergedAt,url,title 2>/dev/null || echo '[]')

  # cache merged PR meaningful files
  echo "$MERGED_JSON" | jq -r '.[].number' | while IFS= read -r MNUM; do
    [[ -z "$MNUM" ]] && continue
    mf="$TMP_DIR/merged-${REPO//\//-}-$MNUM.txt"
    files_for_pr "$MNUM" "$REPO" | meaningful_files > "$mf"
  done

  while IFS= read -r OPEN_PR; do
    [[ -z "$OPEN_PR" ]] && continue

    # refresh open PR info each pass
    OPEN_VIEW=$(gh pr view "$OPEN_PR" --repo "$REPO" --json number,title,url,updatedAt 2>/dev/null || echo '{}')
    OPEN_UPDATED=$(echo "$OPEN_VIEW" | jq -r '.updatedAt // ""')

    of="$TMP_DIR/open-${REPO//\//-}-$OPEN_PR.txt"
    files_for_pr "$OPEN_PR" "$REPO" | meaningful_files > "$of"

    # if no meaningful files, skip superseded close (could be hygiene-only PR)
    [[ -s "$of" ]] || continue

    SUP_MERGED_NUM=""
    SUP_MERGED_URL=""
    while IFS=$'\t' read -r MNUM MMERGED MURL; do
      mf="$TMP_DIR/merged-${REPO//\//-}-$MNUM.txt"
      [[ -f "$mf" ]] || continue
      # merged PR must be newer than open PR update
      if [[ -n "$OPEN_UPDATED" && -n "$MMERGED" && "$MMERGED" < "$OPEN_UPDATED" ]]; then
        continue
      fi
      if is_subset "$of" "$mf"; then
        SUP_MERGED_NUM="$MNUM"
        SUP_MERGED_URL="$MURL"
        break
      fi
    done < <(echo "$MERGED_JSON" | jq -r '.[] | [.number, .mergedAt, .url] | @tsv')

    if [[ -n "$SUP_MERGED_NUM" ]]; then
      gh pr comment "$OPEN_PR" --repo "$REPO" --body "Closing as superseded by #$SUP_MERGED_NUM ($SUP_MERGED_URL): all meaningful file changes in this PR are already covered by that newer merged PR." >/dev/null 2>&1 || true
      if gh pr close "$OPEN_PR" --repo "$REPO" --comment "Superseded by #$SUP_MERGED_NUM." >/dev/null 2>&1; then
        URL=$(echo "$OPEN_VIEW" | jq -r '.url')
        TITLE=$(echo "$OPEN_VIEW" | jq -r '.title')
        say "🧹 Closed superseded: $REPO #$OPEN_PR — $TITLE — $URL (superseded by #$SUP_MERGED_NUM)"
        ACTIONS=$((ACTIONS + 1))
      fi
    fi
  done < <(gh pr list --repo "$REPO" --state open --base "$BASE_BRANCH" --json number --jq '.[].number')

  # If development queue is drained, prepare manual release PR to main.
  ensure_sync_pr_main "$REPO"

  # Always inspect main-targeted PRs for pending Cursor patch suggestions.
  scan_main_pr_feedback "$REPO"

done

# If no actions, stay silent for cron friendliness.
if [[ "$ACTIONS" -eq 0 ]]; then
  exit 0
fi
