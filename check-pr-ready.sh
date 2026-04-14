#!/usr/bin/env bash
# check-pr-ready.sh — Check if tracked PRs pass "definition of done"
# Definition of done: CI passed + all reviews approved (no changes_requested) + no merge conflicts
# Outputs JSON lines for PRs that are newly ready.
set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

TASKS_FILE="$HOME/.clawdbot/active-tasks.json"
NOTIFIED_FILE="$HOME/.clawdbot/notified-prs.json"

[ -f "$TASKS_FILE" ] || exit 0
[ -f "$NOTIFIED_FILE" ] || echo '{}' > "$NOTIFIED_FILE"

# Get all tasks with status=done and a PR number (include repoPath for owner resolution)
TASKS=$(jq -r '.[] | select(.status == "done" and .pr != null) | [.id, .repo, (.pr | tostring), (.repoPath // "")] | @tsv' "$TASKS_FILE" 2>/dev/null || true)

[ -z "$TASKS" ] && exit 0

NOTIFIED=$(cat "$NOTIFIED_FILE")
ALERTS=""

while IFS=$'\t' read -r TASK_ID REPO PR_NUM REPO_PATH; do
  # Resolve full OWNER/REPO from git remote if REPO lacks a slash
  if [[ "$REPO" != *"/"* ]] && [ -n "$REPO_PATH" ] && [ -d "$REPO_PATH" ]; then
    REMOTE_URL=$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null || true)
    FULL_REPO=$(echo "$REMOTE_URL" | sed -E 's|.*[:/]([^/]+/[^/]+?)\.git$|\1|; s|.*[:/]([^/]+/[^/]+)$|\1|')
    [ -n "$FULL_REPO" ] && REPO="$FULL_REPO"
  fi
  # Skip if already notified
  KEY="${REPO}#${PR_NUM}"
  ALREADY=$(echo "$NOTIFIED" | jq -r --arg k "$KEY" '.[$k] // "no"')
  [ "$ALREADY" = "yes" ] && continue

  # Check CI status — "no checks reported" exits non-zero, so capture stderr too
  CI_RAW=$(gh pr checks "$PR_NUM" --repo "$REPO" --json name,state 2>&1) || true
  if echo "$CI_RAW" | grep -q "no checks reported"; then
    CI_STATUS="none"
  else
    CI_STATUS=$(echo "$CI_RAW" | jq -r '[.[] | select(.state != "SKIPPED") | .state] as $checks
      | if ($checks | length) == 0 then "none"
        elif all($checks[]; . == "SUCCESS" or . == "NEUTRAL") then "pass"
        elif any($checks[]; . == "FAILURE") then "fail"
        else "pending" end' 2>/dev/null || echo "unknown")
  fi

  # Check review + mergeability + bugbot autofix freshness
  VIEW_JSON=$(gh pr view "$PR_NUM" --repo "$REPO" --json reviewDecision,mergeable,mergeStateStatus,state,comments,commits 2>/dev/null || echo "{}")
  PR_STATE=$(echo "$VIEW_JSON" | jq -r '(.state // "UNKNOWN")')
  if [[ "$PR_STATE" != "OPEN" ]]; then
    continue
  fi
  REVIEW_STATE=$(echo "$VIEW_JSON" | jq -r '(.reviewDecision | if . == null or . == "" then "none" else . end)')
  MERGEABLE=$(echo "$VIEW_JSON" | jq -r '.mergeable // "UNKNOWN"')
  MERGE_STATE=$(echo "$VIEW_JSON" | jq -r '.mergeStateStatus // "UNKNOWN"')
  LATEST_COMMIT_TS=$(echo "$VIEW_JSON" | jq -r '.commits[-1].committedDate // ""')
  # Consider Bugbot pending only when comment includes a concrete push token ("@cursor push <sha>")
  # posted after latest commit; summary-only comments should not block readiness.
  BUGBOT_PENDING=$(echo "$VIEW_JSON" | jq -r --arg latest "$LATEST_COMMIT_TS" '[.comments[]? | select(.author.login == "cursor" and (.body | test("BUGBOT_AUTOFIX_COMMENT"; "i")) and (.body | test("@cursor push [a-f0-9]{8,}"; "i")) and ($latest == "" or .createdAt > $latest))] | if length > 0 then "true" else "false" end')

  # For repos with no CI, treat "none" as pass
  if [ "$CI_STATUS" = "pass" ] || [ "$CI_STATUS" = "none" ]; then
    CI_OK="true"
  else
    CI_OK="false"
  fi

  # For repos with no required reviews, treat "none" as pass
  if [ "$REVIEW_STATE" = "APPROVED" ] || [ "$REVIEW_STATE" = "none" ]; then
    REVIEW_OK="true"
  else
    REVIEW_OK="false"
  fi

  # Require no conflicts / clean merge state
  if [ "$MERGEABLE" = "CONFLICTING" ] || [ "$MERGE_STATE" = "DIRTY" ]; then
    MERGE_OK="false"
  else
    MERGE_OK="true"
  fi

  # If Cursor Bugbot suggested an autofix after the latest commit, require manual review first.
  if [ "$BUGBOT_PENDING" = "true" ]; then
    BUGBOT_OK="false"
  else
    BUGBOT_OK="true"
  fi

  if [ "$CI_OK" = "true" ] && [ "$REVIEW_OK" = "true" ] && [ "$MERGE_OK" = "true" ] && [ "$BUGBOT_OK" = "true" ]; then
    PR_URL=$(gh pr view "$PR_NUM" --repo "$REPO" --json url --jq .url 2>/dev/null || echo "")
    PR_TITLE=$(gh pr view "$PR_NUM" --repo "$REPO" --json title --jq .title 2>/dev/null || echo "")
    ALERTS="${ALERTS}READY|${TASK_ID}|${REPO}|${PR_NUM}|${PR_URL}|${PR_TITLE}\n"
    # Mark as notified
    NOTIFIED=$(echo "$NOTIFIED" | jq --arg k "$KEY" '. + {($k): "yes"}')
  fi
done <<< "$TASKS"

echo "$NOTIFIED" > "$NOTIFIED_FILE"

if [ -n "$ALERTS" ]; then
  echo -e "$ALERTS"
fi
