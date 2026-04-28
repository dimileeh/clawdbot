#!/bin/bash
# agent-precheck.sh — Layer 1: zero-token agent pre-check
# Run from system crontab every 10 minutes.
# Only wakes OpenClaw when there are live agent runners.
#
# Uses two overlapping signals so nothing is missed when either path breaks:
#   1. live runnerPid values from the active-tasks.json registry (primary
#      since spawn-agent.sh moved to nohup; tmux can legitimately be dead
#      while the runner is still producing work)
#   2. tmux sessions starting with "agent-" (legacy, still populated as a
#      best-effort observability wrapper)

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

REGISTRY="$HOME/.clawdbot/active-tasks.json"

# Gather live-runner task ids from the registry.
LIVE_IDS=()
if [ -f "$REGISTRY" ]; then
    while IFS=$'\t' read -r TASK_ID PID; do
        [ -z "$TASK_ID" ] && continue
        [ -z "$PID" ] && continue
        [ "$PID" = "null" ] && continue
        if kill -0 "$PID" 2>/dev/null; then
            LIVE_IDS+=("$TASK_ID")
        fi
    done < <(jq -r '.[] | select(.status == "running") | [.id, (.runnerPid // "")] | @tsv' "$REGISTRY" 2>/dev/null || true)
fi

# Also count matching tmux sessions (pre-nohup tasks + current observability panes).
TMUX_IDS=$(tmux ls 2>/dev/null | grep "^agent-" | cut -d: -f1 | sed 's/^agent-//' | tr '\n' ' ' || true)

# Union the two sources. The `${LIVE_IDS[@]+...}` expansion is required under
# `set -u` because an empty array would otherwise trip "unbound variable".
COMBINED=$(printf '%s\n' ${LIVE_IDS[@]+"${LIVE_IDS[@]}"} $TMUX_IDS | sort -u | grep -v '^$' || true)
ACTIVE=$(printf '%s\n' "$COMBINED" | grep -c . || true)

# Reap zombies: any status=running entry whose runnerPid AND tmux session are
# both dead. check-agents.sh already knows how to transition those to done/
# failed/etc. and is pure shell (no LLM call), so we invoke it directly when
# we find any. Without this, ghost entries linger forever — they don't show
# up in $ACTIVE so the wake path skips them, and Sparky never sees them.
if [ -f "$REGISTRY" ]; then
    ZOMBIES=0
    while IFS=$'\t' read -r ZID ZPID ZTMUX; do
        [ -z "$ZID" ] && continue
        if [ -n "$ZPID" ] && [ "$ZPID" != "null" ] && kill -0 "$ZPID" 2>/dev/null; then
            continue
        fi
        if [ -n "$ZTMUX" ] && [ "$ZTMUX" != "null" ] && tmux has-session -t "$ZTMUX" 2>/dev/null; then
            continue
        fi
        ZOMBIES=$((ZOMBIES + 1))
    done < <(jq -r '.[] | select(.status == "running") | [.id, (.runnerPid // ""), (.tmuxSession // "")] | @tsv' "$REGISTRY" 2>/dev/null || true)
    if [ "$ZOMBIES" -gt 0 ]; then
        bash "$CLAWDBOT_HOME/check-agents.sh" >/dev/null 2>&1 || true
    fi
fi

if [ "$ACTIVE" -eq 0 ]; then
    exit 0
fi

AGENTS=$(printf '%s' "$COMBINED" | paste -sd, -)

# Wake OpenClaw with agent context
openclaw system event \
    --mode now \
    --text "🐝 Swarm pre-check: $ACTIVE active agent runner(s) [$AGENTS]. Run: bash ~/.clawdbot/check-agents.sh — parse JSON output and report status of running/completed agents. If any agents completed with PRs, report links. If all still running, give a brief status update." \
    --timeout 5000 2>/dev/null || true
