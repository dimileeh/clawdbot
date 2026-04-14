#!/usr/bin/env bash
# finalize-task.sh — Best-effort immediate task state reconciliation on agent exit
# Usage: finalize-task.sh <task-id> <repo-path> <branch> <exit-code>

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

TASK_ID="${1:?task id}"
REPO_PATH="${2:?repo path}"
BRANCH="${3:?branch}"
EXIT_CODE="${4:?exit code}"
REGISTRY="$HOME/.clawdbot/active-tasks.json"

[ -f "$REGISTRY" ] || exit 0

# Skip if task already terminal or missing
CURRENT_STATUS=$(jq -r --arg id "$TASK_ID" '.[] | select(.id == $id) | .status' "$REGISTRY" 2>/dev/null || true)
[ -z "$CURRENT_STATUS" ] && exit 0
if [ "$CURRENT_STATUS" = "done" ] || [ "$CURRENT_STATUS" = "failed" ]; then
  exit 0
fi

PR_NUMBER=""
BRANCH_PUSHED=false
if [ -d "$REPO_PATH" ]; then
  PR_NUMBER=$(cd "$REPO_PATH" && gh pr list --head "$BRANCH" --state all --json number --jq '.[0].number' 2>/dev/null || echo "")
  if cd "$REPO_PATH" && git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    BRANCH_PUSHED=true
  fi
fi

NOW_MS=$(($(date +%s) * 1000))
NEW_STATUS="running"
NOTE=""

if [ "$EXIT_CODE" = "0" ]; then
  NEW_STATUS="done"
  if [ -n "$PR_NUMBER" ]; then
    NOTE="agent exited cleanly; PR detected"
  elif [ "$BRANCH_PUSHED" = "true" ]; then
    NOTE="agent exited cleanly; branch pushed without PR"
  else
    NOTE="agent exited cleanly; no PR/branch push (likely no-op or non-PR completion)"
  fi
else
  if [ -n "$PR_NUMBER" ] || [ "$BRANCH_PUSHED" = "true" ]; then
    NEW_STATUS="done"
    NOTE="agent exited with code $EXIT_CODE after producing output"
  else
    NEW_STATUS="failed"
    NOTE="agent exited with code $EXIT_CODE; no PR/branch push"
  fi
fi

jq --arg id "$TASK_ID" \
   --arg status "$NEW_STATUS" \
   --arg note "$NOTE" \
   --arg pr "$PR_NUMBER" \
   --argjson now "$NOW_MS" \
   'map(if .id == $id then . as $o | .status = $status | .completedAt = $now | .note = $note | .pr = (if $pr == "" then $o.pr else ($pr | tonumber? // $o.pr) end) else . end)' \
   "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"

exit 0
