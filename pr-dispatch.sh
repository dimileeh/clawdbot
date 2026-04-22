#!/usr/bin/env bash
# pr-dispatch.sh — Sparky-side helper to respond to a PR handler escalation
# via the file-based followup channel.
#
# Background (2026-04-21 incident): the old escalation path routed handler
# questions through ``sessions_send`` to Sparky's main session, and Sparky
# replied the same way to the handler's ``child_session_key``. Two failure
# modes made that unreliable:
#
#   1. Handlers exited immediately after escalating, tearing down the
#      session before Sparky's reply could land.
#   2. Even when alive, once the handler session exited ``sessions_send``
#      reply evaporated with no error, no queue, no retry.
#
# File-based followups fix both. Handlers persist escalations to
# ``~/.clawdbot/followups/<pr_key_safe>.json``. Sparky responds with this
# script, which writes a ``dispatch`` field into the same file. The next
# pr-manager tick folds the dispatch into a fresh handler envelope (and
# bypasses the review-wait + renotification cooldown so it happens fast).
#
# Usage:
#   pr-dispatch.sh <pr_key> <plan_text_or_- >
#
# Arguments:
#   pr_key      e.g. ``dimileeh/aira-agent#325``
#   plan        the dispatch text. If ``-`` read from stdin.
#
# The pr_key is converted to a safe filename the same way pr-manager.sh
# does: ``tr '/#' '--'``. This keeps both sides in lockstep without an
# out-of-band config shared between the two scripts.

set -euo pipefail

FOLLOWUPS_DIR="$HOME/.clawdbot/followups"
mkdir -p "$FOLLOWUPS_DIR"

if [ $# -lt 2 ]; then
    echo "usage: $0 <pr_key> <plan | ->" >&2
    echo "  pr_key examples: dimileeh/aira-agent#325, dimileeh/aira-web#259" >&2
    exit 2
fi

PR_KEY="$1"
# Collect all arguments from position 2 onward so unquoted multi-word
# plans (e.g. ``pr-dispatch.sh owner/repo#1 fix the flaky test``) are
# preserved instead of silently truncated to just ``$2``.
PLAN_ARG="${*:2}"

if [ "$PLAN_ARG" = "-" ]; then
    PLAN_TEXT=$(cat)
else
    PLAN_TEXT="$PLAN_ARG"
fi

if [ -z "$PLAN_TEXT" ]; then
    echo "error: empty dispatch plan" >&2
    exit 3
fi

# Validate pr_key shape: owner/repo#N
if ! [[ "$PR_KEY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[0-9]+$ ]]; then
    echo "error: pr_key must be owner/repo#N, got: $PR_KEY" >&2
    exit 4
fi

PR_KEY_SAFE=$(echo "$PR_KEY" | tr '/#' '--')
FOLLOWUP_FILE="$FOLLOWUPS_DIR/$PR_KEY_SAFE.json"

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Preserve prior escalation context if present so the next handler sees
# both the question the prior handler asked AND the maintainer's answer.
# If no file exists yet, start from {} (maintainer can preempt an expected
# escalation by dispatching proactively).
# Read any existing followup payload in fail-closed mode: jq -e exits
# 0 on truthy output, 1 on falsy output, and >=2 on parse/IO errors. We
# treat a parse error as hard fail (corrupt file -> don't silently drop
# prior escalation context), and only fall back to ``{}`` when the file
# simply doesn't exist. Use ``-c`` so the accumulated JSON stays compact
# for the downstream jq pipe.
if [ -f "$FOLLOWUP_FILE" ]; then
    set +e
    EXISTING=$(jq -ce . "$FOLLOWUP_FILE" 2>/dev/null)
    RC=$?
    set -e
    if [ $RC -ge 2 ]; then
        echo "error: failed to parse $FOLLOWUP_FILE (jq rc=$RC)" >&2
        exit 5
    fi
    if [ $RC -ne 0 ] || [ -z "$EXISTING" ]; then
        EXISTING='{}'
    fi
else
    EXISTING='{}'
fi

# Feed the prior payload via stdin to dodge argv size limits (E2BIG)
# if the followup ever grows large (multi-handler escalation history).
printf '%s' "$EXISTING" | jq \
    --arg dispatch "$PLAN_TEXT" \
    --arg dispatched_at "$NOW_ISO" \
    --arg pr_key "$PR_KEY" \
    '. + {pr_key: $pr_key, dispatch: $dispatch, dispatched_at: $dispatched_at}' \
    > "$FOLLOWUP_FILE.tmp"

mv "$FOLLOWUP_FILE.tmp" "$FOLLOWUP_FILE"

# Confirm for Sparky's logs
BYTES=$(wc -c < "$FOLLOWUP_FILE" | tr -d ' ')
echo "wrote dispatch for $PR_KEY to $FOLLOWUP_FILE ($BYTES bytes)"
echo "next pr-manager tick will fold it into a fresh handler spawn (no wait, no cooldown)"
