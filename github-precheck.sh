#!/bin/bash
# github-precheck.sh — Layer 1: zero-token GitHub pre-check
# Run from system crontab every 10 minutes.
# Checks GitHub state with gh CLI (zero LLM tokens).
# Only wakes OpenClaw when NEW action items appear.

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

REPOS="${CLAWDBOT_REPOS}"
STATE_FILE="$HOME/.clawdbot/github-precheck-state.json"
WAKE_REASONS=""

[ -f "$STATE_FILE" ] || echo '{"last_dev_shas":{},"last_pr_comments":{},"last_check":"","notified_drifts":{}}' > "$STATE_FILE"

# Ensure notified_drifts key exists
if ! jq -e '.notified_drifts' "$STATE_FILE" >/dev/null 2>&1; then
    jq '. + {"notified_drifts":{}}' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

# ─── Check 1: New PR review comments needing attention ───
for REPO in $REPOS; do
    UNRESOLVED=$(gh pr list --repo "$REPO" --state open --json number,title,reviewDecision \
        --jq '.[] | select(.reviewDecision == "CHANGES_REQUESTED" or .reviewDecision == "REVIEW_REQUIRED") | "\(.number):\(.title)"' 2>/dev/null || true)

    if [ -n "$UNRESOLVED" ]; then
        LAST_CHECK=$(jq -r '.last_check // ""' "$STATE_FILE")
        while IFS= read -r PR_LINE; do
            PR_NUM=$(echo "$PR_LINE" | cut -d: -f1)
            NEW_COMMENTS=$(gh api "repos/$REPO/pulls/$PR_NUM/comments" \
                --jq "[.[] | select(.updated_at > \"${LAST_CHECK:-2000-01-01T00:00:00Z}\")] | length" 2>/dev/null || echo "0")
            if [ "$NEW_COMMENTS" -gt 0 ]; then
                WAKE_REASONS="${WAKE_REASONS}📝 $REPO PR #$PR_NUM has $NEW_COMMENTS new review comment(s)\n"
            fi
        done <<< "$UNRESOLVED"
    fi
done

# ─── Check 2: Development ahead of main (merge opportunity) ───
for REPO in $REPOS; do
    AHEAD=$(gh api "repos/$REPO/compare/main...development" \
        --jq '.ahead_by' 2>/dev/null || echo "0")

    if [ "$AHEAD" -gt 0 ]; then
        EXISTING_PR=$(gh pr list --repo "$REPO" --base main --head development --state open \
            --json number --jq 'length' 2>/dev/null || echo "0")

        CURRENT_SHA=$(gh api "repos/$REPO/branches/development" --jq '.commit.sha' 2>/dev/null || echo "")
        NOTIFIED_SHA=$(jq -r ".notified_drifts[\"$REPO\"] // \"\"" "$STATE_FILE")

        if [ "$EXISTING_PR" = "0" ] && [ "$CURRENT_SHA" != "$NOTIFIED_SHA" ]; then
            # New drift or new commits since last notification
            WAKE_REASONS="${WAKE_REASONS}🔀 $REPO: development is $AHEAD commit(s) ahead of main, no PR exists\n"
            # Mark as notified at this SHA — won't re-fire until new commits
            jq --arg repo "$REPO" --arg sha "$CURRENT_SHA" \
                '.notified_drifts[$repo] = $sha' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        fi

        # Update dev SHA tracking
        if [ -n "$CURRENT_SHA" ]; then
            jq --arg repo "$REPO" --arg sha "$CURRENT_SHA" \
                '.last_dev_shas[$repo] = $sha' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        fi
    else
        # Development is even with main — clear drift notification state
        jq --arg repo "$REPO" '.notified_drifts[$repo] = ""' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
done

# ─── Check 3: PRs ready to merge (CI green + approved) ───
for REPO in $REPOS; do
    READY_PRS=$(gh pr list --repo "$REPO" --state open \
        --json number,title,mergeable,reviewDecision,statusCheckRollup \
        --jq '.[] | select(.mergeable == "MERGEABLE" and .reviewDecision == "APPROVED") |
              select(.statusCheckRollup != null) |
              select([.statusCheckRollup[] | select(.conclusion == "FAILURE")] | length == 0) |
              "\(.number):\(.title)"' 2>/dev/null || true)

    if [ -n "$READY_PRS" ]; then
        while IFS= read -r PR_LINE; do
            PR_NUM=$(echo "$PR_LINE" | cut -d: -f1)
            PR_TITLE=$(echo "$PR_LINE" | cut -d: -f2-)
            WAKE_REASONS="${WAKE_REASONS}✅ $REPO PR #$PR_NUM ready to merge: $PR_TITLE\n"
        done <<< "$READY_PRS"
    fi
done

# ─── Update last check timestamp ───
jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_check = $ts' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"

# ─── Wake OpenClaw only if there are reasons ───
if [ -n "$WAKE_REASONS" ]; then
    WAKE_TEXT=$(printf "🔍 GitHub pre-check found action items:\n${WAKE_REASONS}\nReview and take appropriate action. For new review comments, read them and address or spawn fix agents. For merge opportunities, ask Dmitri if he wants to open a dev→main PR. For ready PRs, confirm merge with Dmitri.")

    openclaw system event \
        --mode now \
        --text "$WAKE_TEXT" \
        --timeout 5000 2>/dev/null || true
fi
