#!/usr/bin/env bash
# gateway-supervisor.sh — Layer-2 watchdog for the OpenClaw gateway's
# Telegram polling loop.
#
# launchd already restarts the gateway process on crash (KeepAlive). The
# failure mode this script catches is different: the process stays UP but
# its in-process Telegram polling loop stalls — getUpdates hangs for 400-
# 1000s, the loop logs "Polling stall detected; restarting in 30s",
# rebuilds transport, immediately stalls again. Sparky becomes unreachable
# from Telegram even though `launchctl list` shows the gateway healthy.
#
# 2026-04-28 04:00–10:00: 50+ stall/restart cycles, several >900s, no
# recovery. The maintainer eventually noticed and poked manually.
#
# Logic:
#   - Count "Polling stall detected" entries in the recent log tail.
#   - If >= STALL_THRESHOLD, bounce the gateway via `launchctl kickstart -k`.
#   - Cool-down state file prevents thrash (one bounce per COOLDOWN_MINUTES).
#   - If `gh` / `openclaw message send` is wired, notify the maintainer.

set -euo pipefail

CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

GATEWAY_ERR_LOG="${OPENCLAW_GATEWAY_ERR_LOG:-$HOME/.openclaw/logs/gateway.err.log}"
SERVICE_ID="${OPENCLAW_LAUNCHCTL_SERVICE:-ai.openclaw.gateway}"
STATE_FILE="$CLAWDBOT_HOME/gateway-supervisor.state"
LOG_FILE="$CLAWDBOT_HOME/logs/gateway-supervisor.log"

# Tunables.
STALL_THRESHOLD="${GATEWAY_SUPERVISOR_STALL_THRESHOLD:-5}"
TAIL_LINES="${GATEWAY_SUPERVISOR_TAIL_LINES:-2000}"
COOLDOWN_MINUTES="${GATEWAY_SUPERVISOR_COOLDOWN_MINUTES:-30}"

mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"; }

[ -f "$GATEWAY_ERR_LOG" ] || exit 0

# Read the last bounce time from state (used both for cool-down and to
# floor the stall-count window so we never re-count historical pre-bounce
# stalls after cool-down expires).
LAST_RESTART=""
LAST_BOUNCE_EPOCH=0
if [ -f "$STATE_FILE" ]; then
    LAST_RESTART=$(cat "$STATE_FILE" 2>/dev/null || true)
    if [ -n "$LAST_RESTART" ]; then
        LAST_BOUNCE_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_RESTART" +%s 2>/dev/null || echo 0)
    fi
fi

# Cool-down: skip if we restarted within COOLDOWN_MINUTES.
NOW_EPOCH=$(date +%s)
if [ "$LAST_BOUNCE_EPOCH" -gt 0 ]; then
    COOLDOWN_END_EPOCH=$((LAST_BOUNCE_EPOCH + COOLDOWN_MINUTES * 60))
    if [ "$NOW_EPOCH" -lt "$COOLDOWN_END_EPOCH" ]; then
        exit 0
    fi
fi

# Floor the count window: only stalls newer than max(last-bounce, now-2h).
# Without this floor, after cool-down expires the tail would still contain
# historical pre-bounce stalls and would re-trigger a bounce on a healthy
# gateway. The 2h cap is the no-state fallback for first-run.
FLOOR_EPOCH=$((NOW_EPOCH - 2 * 3600))
if [ "$LAST_BOUNCE_EPOCH" -gt "$FLOOR_EPOCH" ]; then
    FLOOR_EPOCH=$LAST_BOUNCE_EPOCH
fi

# Count "Polling stall detected" entries newer than FLOOR_EPOCH. Log lines
# start with an ISO-8601 timestamp like "2026-04-28T10:45:11.286+01:00";
# strip the milliseconds and reformat the TZ (BSD date wants +HHMM, not
# +HH:MM) before parsing to epoch.
STALL_COUNT=0
while IFS= read -r line; do
    ts=$(printf '%s\n' "$line" | awk '{print $1}')
    [ -z "$ts" ] && continue
    ts_norm=$(printf '%s' "$ts" \
        | sed -E 's/\.[0-9]+//; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
    epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ts_norm" +%s 2>/dev/null || echo 0)
    if [ "$epoch" -gt "$FLOOR_EPOCH" ]; then
        STALL_COUNT=$((STALL_COUNT + 1))
    fi
done < <(tail -n "$TAIL_LINES" "$GATEWAY_ERR_LOG" 2>/dev/null | grep "Polling stall detected" || true)

if [ "${STALL_COUNT:-0}" -lt "$STALL_THRESHOLD" ]; then
    exit 0
fi

DOMAIN="gui/$(id -u)"
log "stall-count=$STALL_COUNT (threshold=$STALL_THRESHOLD); kickstarting $SERVICE_ID"
if launchctl kickstart -k "${DOMAIN}/${SERVICE_ID}" >/dev/null 2>&1; then
    NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "$NOW" > "$STATE_FILE"
    log "kickstart ok ($SERVICE_ID)"

    if [ -n "${CLAWDBOT_NOTIFY_TARGET:-}" ]; then
        openclaw message send \
            --channel "${CLAWDBOT_NOTIFY_CHANNEL:-telegram}" \
            --target "$CLAWDBOT_NOTIFY_TARGET" \
            --message "🛠 gateway-supervisor: bounced openclaw-gateway after $STALL_COUNT polling stall(s) in last ${TAIL_LINES} log lines" \
            >/dev/null 2>&1 || log "maintainer announce failed (non-fatal)"
    fi
else
    log "kickstart FAILED for $SERVICE_ID; will retry next tick"
    exit 1
fi
