#!/usr/bin/env bash
# check-agents.sh — Monitor all active agents, check CI, detect completion
# Designed to run via cron every 10 minutes. Zero LLM calls — pure shell.
# Outputs JSON status for OpenClaw to consume.

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

REGISTRY="$HOME/.clawdbot/active-tasks.json"
LOG_DIR="$HOME/.clawdbot/logs"
ALERTS=""
# shellcheck disable=SC2034
CHANGED=false

if [ ! -f "$REGISTRY" ] || [ "$(cat "$REGISTRY")" = "[]" ]; then
  echo '{"status":"idle","tasks":0,"alerts":[]}'
  exit 0
fi

TASK_COUNT=$(jq length "$REGISTRY")
RESULTS=()

for i in $(seq 0 $((TASK_COUNT - 1))); do
  TASK=$(jq -r ".[$i]" "$REGISTRY")
  TASK_ID=$(echo "$TASK" | jq -r '.id')
  STATUS=$(echo "$TASK" | jq -r '.status')
  TMUX_SESSION=$(echo "$TASK" | jq -r '.tmuxSession')
  BRANCH=$(echo "$TASK" | jq -r '.branch')
  REPO_PATH=$(echo "$TASK" | jq -r '.repoPath')
  # shellcheck disable=SC2034
  REPO_NAME=$(echo "$TASK" | jq -r '.repo')
  RESPAWN_COUNT=$(echo "$TASK" | jq -r '.respawnCount // 0')
  MAX_RESPAWNS=$(echo "$TASK" | jq -r '.maxRespawns // 3')

  # For done/failed tasks: re-check CI on open PRs, skip the rest
  if [ "$STATUS" = "done" ] || [ "$STATUS" = "failed" ]; then
    PR_NUMBER=""
    CI_STATUS=""
    PR_STATE=""
    MERGEABLE=""
    MERGE_STATE=""
    if [ -d "$REPO_PATH" ] && [ -n "$BRANCH" ] && [ "$BRANCH" != "null" ]; then
      PR_NUMBER=$(cd "$REPO_PATH" && gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
    fi
    if [ -n "$PR_NUMBER" ]; then
      PR_VIEW_JSON=$(cd "$REPO_PATH" && gh pr view "$PR_NUMBER" --json state,mergeable,mergeStateStatus 2>/dev/null || echo "{}")
      PR_STATE=$(echo "$PR_VIEW_JSON" | jq -r '.state // ""')
      MERGEABLE=$(echo "$PR_VIEW_JSON" | jq -r '.mergeable // "UNKNOWN"')
      MERGE_STATE=$(echo "$PR_VIEW_JSON" | jq -r '.mergeStateStatus // "UNKNOWN"')
      CI_STATUS=$(cd "$REPO_PATH" && gh pr checks "$PR_NUMBER" --json bucket --jq '[.[] | .bucket] | if all(. == "pass") then "pass" elif any(. == "fail") then "fail" else "pending" end' 2>/dev/null || echo "unknown")
      # Determine action based on current CI/merge state
      ACTION="skip"
      if [ "$CI_STATUS" = "fail" ]; then
        ACTION="pr-needs-fix"
      elif [ "$CI_STATUS" = "pass" ] && { [ "$MERGEABLE" = "CONFLICTING" ] || [ "$MERGE_STATE" = "DIRTY" ]; }; then
        ACTION="pr-conflicted"
      elif [ "$CI_STATUS" = "pass" ]; then
        ACTION="ready-to-merge"
      elif [ "$CI_STATUS" = "pending" ]; then
        ACTION="pr-open-awaiting-ci"
      fi
      RESULTS+=("{\"id\":\"$TASK_ID\",\"status\":\"$STATUS\",\"pr\":\"$PR_NUMBER\",\"prState\":\"$PR_STATE\",\"mergeable\":\"$MERGEABLE\",\"mergeState\":\"$MERGE_STATE\",\"ci\":\"$CI_STATUS\",\"action\":\"$ACTION\"}")
    else
      RESULTS+=("{\"id\":\"$TASK_ID\",\"status\":\"$STATUS\",\"action\":\"skip\"}")
    fi
    continue
  fi

  # 1. Check if tmux session is alive
  TMUX_ALIVE=false
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    TMUX_ALIVE=true
  fi

  # 2. Check for open PR on branch + whether branch has been pushed
  PR_NUMBER=""
  CI_STATUS=""
  BRANCH_PUSHED=false
  if [ -d "$REPO_PATH" ]; then
    PR_NUMBER=$(cd "$REPO_PATH" && gh pr list --head "$BRANCH" --state all --json number --jq '.[0].number' 2>/dev/null || echo "")
    if cd "$REPO_PATH" && git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
      BRANCH_PUSHED=true
    fi
  fi

  # 3. If PR exists, check PR state + CI + mergeability
  PR_STATE=""
  MERGEABLE=""
  MERGE_STATE=""
  if [ -n "$PR_NUMBER" ]; then
    PR_VIEW_JSON=$(cd "$REPO_PATH" && gh pr view "$PR_NUMBER" --json state,mergeable,mergeStateStatus 2>/dev/null || echo "{}")
    PR_STATE=$(echo "$PR_VIEW_JSON" | jq -r '.state // ""')
    MERGEABLE=$(echo "$PR_VIEW_JSON" | jq -r '.mergeable // "UNKNOWN"')
    MERGE_STATE=$(echo "$PR_VIEW_JSON" | jq -r '.mergeStateStatus // "UNKNOWN"')
    CI_STATUS=$(cd "$REPO_PATH" && gh pr checks "$PR_NUMBER" --json bucket --jq '[.[] | .bucket] | if all(. == "pass") then "pass" elif any(. == "fail") then "fail" else "pending" end' 2>/dev/null || echo "unknown")
  fi

  # 4. Determine action
  ACTION="none"
  NEW_STATUS="$STATUS"

  # If tmux is dead, try to read the wrapped command exit code from the task log.
  EXIT_CODE=""
  if [ "$TMUX_ALIVE" = "false" ]; then
    LOG_FILE="$LOG_DIR/$TASK_ID.log"
    if [ -f "$LOG_FILE" ]; then
      EXIT_CODE=$(grep -Eo 'COMMAND_EXIT_CODE="[0-9]+"' "$LOG_FILE" | tail -n1 | sed -E 's/.*"([0-9]+)"/\1/' || true)
    fi

    if [ -n "$PR_NUMBER" ]; then
      # PR exists: treat coding task as completed (agent may exit after opening PR).
      if [ "$PR_STATE" = "MERGED" ] || [ "$PR_STATE" = "CLOSED" ]; then
        NEW_STATUS="done"
        ACTION="pr-closed"
      elif [ "$CI_STATUS" = "pass" ] && [ "$MERGEABLE" != "CONFLICTING" ] && [ "$MERGE_STATE" != "DIRTY" ]; then
        NEW_STATUS="done"
        ACTION="ready-to-merge"
        ALERTS="$ALERTS\n🟢 $TASK_ID: PR #$PR_NUMBER ready (ci=$CI_STATUS, mergeable=$MERGEABLE, state=$MERGE_STATE)"
      elif [ "$CI_STATUS" = "pass" ] && { [ "$MERGEABLE" = "CONFLICTING" ] || [ "$MERGE_STATE" = "DIRTY" ]; }; then
        NEW_STATUS="done"
        ACTION="pr-conflicted"
        ALERTS="$ALERTS\n🟠 $TASK_ID: PR #$PR_NUMBER has conflicts (mergeable=$MERGEABLE, state=$MERGE_STATE)"
      elif [ "$CI_STATUS" = "fail" ]; then
        NEW_STATUS="done"
        ACTION="pr-needs-fix"
        ALERTS="$ALERTS\n🟠 $TASK_ID: PR #$PR_NUMBER needs follow-up fixes (ci=$CI_STATUS)"
      else
        NEW_STATUS="done"
        ACTION="pr-open-awaiting-ci"
        ALERTS="$ALERTS\n🟡 $TASK_ID: PR #$PR_NUMBER open, waiting for CI"
      fi
    else
      # Agent exited before PR creation
      if [ "$BRANCH_PUSHED" = "true" ]; then
        NEW_STATUS="done"
        ACTION="branch-pushed-no-pr"
      elif [ "$EXIT_CODE" = "0" ]; then
        NEW_STATUS="done"
        ACTION="clean-exit-no-pr"
      elif [ "$RESPAWN_COUNT" -lt "$MAX_RESPAWNS" ]; then
        ACTION="respawn-needed"
        ALERTS="$ALERTS\n🔴 $TASK_ID: no PR and branch not pushed (tmux=dead, exit=${EXIT_CODE:-unknown}) — respawn ($RESPAWN_COUNT/$MAX_RESPAWNS)"
      else
        NEW_STATUS="failed"
        ACTION="max-respawns"
        ALERTS="$ALERTS\n❌ $TASK_ID: no PR and branch not pushed (tmux=dead, exit=${EXIT_CODE:-unknown}), max respawns reached"
      fi
    fi
    # shellcheck disable=SC2034
    CHANGED=true
  else
    # Still running
    ACTION="running"
  fi

  # Update status in registry if changed
  if [ "$NEW_STATUS" != "$STATUS" ]; then
    NOW_MS=$(($(date +%s) * 1000))
    jq --arg id "$TASK_ID" --arg status "$NEW_STATUS" --argjson now "$NOW_MS" --arg pr "$PR_NUMBER" \
      'map(if .id == $id then .status = $status | .completedAt = $now | .pr = ($pr | if . == "" then null else (. | tonumber) end) else . end)' \
      "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"
  fi

  RESULTS+=("{\"id\":\"$TASK_ID\",\"status\":\"$NEW_STATUS\",\"tmux\":$TMUX_ALIVE,\"exitCode\":\"$EXIT_CODE\",\"branchPushed\":$BRANCH_PUSHED,\"pr\":\"$PR_NUMBER\",\"prState\":\"$PR_STATE\",\"mergeable\":\"$MERGEABLE\",\"mergeState\":\"$MERGE_STATE\",\"ci\":\"$CI_STATUS\",\"action\":\"$ACTION\"}")
done

# Build output
echo "{"
echo "  \"status\": \"active\","
echo "  \"tasks\": $TASK_COUNT,"
echo "  \"results\": [$(IFS=,; echo "${RESULTS[*]}")],"
if [ -n "$ALERTS" ]; then
  echo "  \"alerts\": \"$(echo -e "$ALERTS" | sed 's/"/\\"/g' | tr '\n' '|' | sed 's/|$//')\""
else
  echo "  \"alerts\": null"
fi
echo "}"
