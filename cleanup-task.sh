#!/usr/bin/env bash
# cleanup-task.sh — Remove worktree and deregister a completed task
# Usage: cleanup-task.sh <task-id>

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

TASK_ID="${1:?Usage: cleanup-task.sh <task-id>}"
REGISTRY="$HOME/.clawdbot/active-tasks.json"

WORKTREE=$(jq -r --arg id "$TASK_ID" '.[] | select(.id == $id) | .worktree' "$REGISTRY")
REPO_PATH=$(jq -r --arg id "$TASK_ID" '.[] | select(.id == $id) | .repoPath' "$REGISTRY")
TMUX_SESSION=$(jq -r --arg id "$TASK_ID" '.[] | select(.id == $id) | .tmuxSession' "$REGISTRY")

# Kill tmux if still running
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Remove worktree
if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
  cd "$REPO_PATH"
  git worktree remove "$WORKTREE" --force 2>/dev/null || rm -rf "$WORKTREE"
fi

# Remove from registry
jq --arg id "$TASK_ID" 'map(select(.id != $id))' "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"

echo "✅ Cleaned up task: $TASK_ID"
