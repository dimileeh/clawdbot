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

# Cool-down: skip if we restarted within COOLDOWN_MINUTES. This keeps the
# script idempotent under the 5-min cron cadence even when stalls are
# still queued in the log (in-flight grace for the new process).
if [ -f "$STATE_FILE" ]; then
    LAST_RESTART=$(cat "$STATE_FILE" 2>/dev/null || true)
    if [ -n "$LAST_RESTART" ]; then
        CUTOFF=$(jq -rn --argjson m "$COOLDOWN_MINUTES" \
            'now - ($m * 60) | strftime("%Y-%m-%dT%H:%M:%SZ")' 2>/dev/null || true)
        if [ -n "$CUTOFF" ] && [[ "$LAST_RESTART" > "$CUTOFF" ]]; then
            exit 0
        fi
    fi
fi

# Count recent polling stalls. The tail bounds the work; the cool-down
# above prevents historical stalls from tripping a second bounce.
STALL_COUNT=$(tail -n "$TAIL_LINES" "$GATEWAY_ERR_LOG" 2>/dev/null \
    | grep -c "Polling stall detected" || true)

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
