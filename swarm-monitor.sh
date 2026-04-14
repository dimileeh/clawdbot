#!/usr/bin/env bash
# swarm-monitor.sh — Zero-LLM swarm monitor
# Runs via system crontab. Only wakes Spark (via openclaw cron wake) when:
#   - A PR becomes ready-to-merge (CI pass + mergeable)
#   - A PR CI fails (needs fix)
#   - A PR has merge conflicts
# Silent otherwise. No LLM tokens burned on "nothing new".

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:/home/linuxbrew/.linuxbrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

SCRIPT_DIR="$HOME/.clawdbot"
ANNOUNCED="$SCRIPT_DIR/announced.json"
CHECK_SCRIPT="$SCRIPT_DIR/check-agents.sh"
LOG_FILE="$SCRIPT_DIR/logs/swarm-monitor.log"

log() { echo "[swarm-monitor $(date -u +%H:%M:%S)] $*" >> "$LOG_FILE"; }

[ -f "$ANNOUNCED" ] || echo '{}' > "$ANNOUNCED"

# Run check-agents
OUTPUT=$("$CHECK_SCRIPT" 2>/dev/null) || { log "check-agents.sh failed"; exit 0; }

TASK_COUNT=$(echo "$OUTPUT" | jq '.tasks')
if [ "$TASK_COUNT" = "0" ]; then
  log "No tasks"
  exit 0
fi

# Parse results, find NEW actionable items
WAKE_MESSAGES=()

for row in $(echo "$OUTPUT" | jq -c '.results[]'); do
  ID=$(echo "$row" | jq -r '.id')
  ACTION=$(echo "$row" | jq -r '.action')
  PR=$(echo "$row" | jq -r '.pr // ""')
  CI=$(echo "$row" | jq -r '.ci // ""')

  # Skip non-actionable
  [ "$ACTION" = "skip" ] && continue
  [ "$ACTION" = "running" ] && continue
  [ "$ACTION" = "pr-open-awaiting-ci" ] && continue

  # Only announce: ready-to-merge, pr-needs-fix, pr-conflicted
  ANNOUNCE_KEY="${ID}:${ACTION}"
  ALREADY=$(jq -r --arg k "$ANNOUNCE_KEY" '.[$k] // ""' "$ANNOUNCED")
  [ -n "$ALREADY" ] && continue

  # New actionable item!
  case "$ACTION" in
    ready-to-merge)
      MSG="🟢 PR #${PR} (${ID}) — CI passed, ready to merge"
      ;;
    pr-needs-fix)
      MSG="🔴 PR #${PR} (${ID}) — CI failed, needs fix (ci=${CI})"
      ;;
    pr-conflicted)
      MSG="🟠 PR #${PR} (${ID}) — merge conflicts detected"
      ;;
    *)
      MSG="📋 PR #${PR} (${ID}) — action: ${ACTION}"
      ;;
  esac

  WAKE_MESSAGES+=("$MSG")

  # Record in announced.json
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg k "$ANNOUNCE_KEY" --arg v "$NOW" '. + {($k): $v}' "$ANNOUNCED" > "$ANNOUNCED.tmp" && mv "$ANNOUNCED.tmp" "$ANNOUNCED"
  log "Announced: $ANNOUNCE_KEY"
done

# If there's anything to announce, wake Spark
if [ ${#WAKE_MESSAGES[@]} -gt 0 ]; then
  COMBINED=$(printf '%s\n' "${WAKE_MESSAGES[@]}")
  log "Waking Spark with ${#WAKE_MESSAGES[@]} items"
  openclaw cron wake --text "SWARM ALERT:\n${COMBINED}\n\nIf any PR has ci=fail, auto-fix it: pull failed CI logs, diagnose, fix if <20 lines, commit and push. If complex, message Dmitri. Announce results via message tool." --mode now 2>/dev/null || log "Wake failed"
else
  log "Nothing new"
fi
