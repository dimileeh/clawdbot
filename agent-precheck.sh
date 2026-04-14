#!/bin/bash
# agent-precheck.sh — Layer 1: zero-token tmux pre-check
# Run from system crontab every 10 minutes.
# Only wakes OpenClaw when agent-* tmux sessions exist.

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

# Count tmux sessions starting with "agent-"
ACTIVE=$(tmux ls 2>/dev/null | grep -c "^agent-" || true)

if [ "$ACTIVE" -eq 0 ]; then
    # Nothing running — exit silently, zero tokens burned
    exit 0
fi

# Collect agent names for context
AGENTS=$(tmux ls 2>/dev/null | grep "^agent-" | cut -d: -f1 | tr '\n' ', ' | sed 's/,$//')

# Wake OpenClaw with agent context
openclaw system event \
    --mode now \
    --text "🐝 Swarm pre-check: $ACTIVE active agent(s) in tmux [$AGENTS]. Run: bash ~/.clawdbot/check-agents.sh — parse JSON output and report status of running/completed agents. If any agents completed with PRs, report links. If all still running, give a brief status update." \
    --timeout 5000 2>/dev/null || true
