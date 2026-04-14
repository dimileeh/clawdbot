#!/usr/bin/env bash
# check-cursor-risk.sh — Flag Cursor auto-fix PRs with large net deletions.
# Rule: if head branch starts with "cursor/" and (deletions - additions) > 100 → flag.
# Output lines: RISKY|<repo>|<pr>|<url>|<title>|<additions>|<deletions>|<net>
set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

STATE_FILE="$HOME/.clawdbot/notified-risky-prs.json"
[ -f "$STATE_FILE" ] || echo '{}' > "$STATE_FILE"

STATE=$(cat "$STATE_FILE")
OUT=""

for REPO in ${CLAWDBOT_REPOS}; do
  PRS_JSON=$(gh pr list --repo "$REPO" --state open --json number,title,url,headRefName,additions,deletions --jq '.[]' 2>/dev/null || true)
  [ -z "$PRS_JSON" ] && continue

  # Iterate each PR object (one per line)
  while IFS= read -r PR_OBJ; do
    PR_NUM=$(echo "$PR_OBJ" | jq -r '.number')
    HEAD=$(echo "$PR_OBJ" | jq -r '.headRefName')
    [[ "$HEAD" != cursor/* ]] && continue

    ADD=$(echo "$PR_OBJ" | jq -r '.additions // 0')
    DEL=$(echo "$PR_OBJ" | jq -r '.deletions // 0')
    NET=$((DEL - ADD))

    [ "$NET" -le 100 ] && continue

    KEY="${REPO}#${PR_NUM}"
    ALREADY=$(echo "$STATE" | jq -r --arg k "$KEY" '.[$k] // "no"')
    [ "$ALREADY" = "yes" ] && continue

    URL=$(echo "$PR_OBJ" | jq -r '.url')
    TITLE=$(echo "$PR_OBJ" | jq -r '.title')

    OUT+="RISKY|${REPO}|${PR_NUM}|${URL}|${TITLE}|${ADD}|${DEL}|${NET}\n"
    STATE=$(echo "$STATE" | jq --arg k "$KEY" '. + {($k): "yes"}')
  done <<< "$(echo "$PRS_JSON")"
done

echo "$STATE" > "$STATE_FILE"

if [ -n "$OUT" ]; then
  echo -e "$OUT"
else
  echo "NO_RISKY_CURSOR_PRS"
fi
