#!/usr/bin/env bash
# check-pr-reviews.sh — Check for new PR review comments (safe for multiline bodies)
# Watches open PRs targeting: development + main.
# Output format (line-oriented, parseable):
#   REPO:<owner/repo>|PR:<num>|TITLE:<title>|BRANCH:<head>
#   <comment_id>|<author>|<path>|<line>|<body_b64>
#   (blank line between PR blocks)
set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

HANDLED_FILE="$HOME/.clawdbot/handled-review-comments.json"
[ -f "$HANDLED_FILE" ] || echo '[]' > "$HANDLED_FILE"

HANDLED=$(cat "$HANDLED_FILE")
OUTPUT=""

for REPO in ${CLAWDBOT_REPOS}; do
  PRS=""
  for BASE in development main; do
    BATCH=$(gh pr list --repo "$REPO" --base "$BASE" --json number,title,headRefName --jq '.[] | "\(.number)\t\(.title)\t\(.headRefName)"' 2>/dev/null || true)
    [ -n "$BATCH" ] && PRS="${PRS}${BATCH}"$'\n'
  done
  PRS=$(echo "$PRS" | sed '/^$/d' | sort -u)
  [ -z "$PRS" ] && continue

  while IFS=$'\t' read -r PR_NUM PR_TITLE PR_BRANCH; do
    COMMENTS_JSON=$(gh api "repos/$REPO/pulls/$PR_NUM/comments" --jq '[.[] | {id, author: .user.login, path, line: (.line // 0), body: (.body // "")} ]' 2>/dev/null || echo '[]')
    COUNT=$(echo "$COMMENTS_JSON" | jq -r 'length')
    [ "$COUNT" = "0" ] && continue

    NEW_COMMENTS=""
    while IFS= read -r C; do
      CID=$(echo "$C" | jq -r '.id')
      ALREADY=$(echo "$HANDLED" | jq --arg id "$CID" 'map(select(. == ($id | tonumber))) | length')
      [ "$ALREADY" != "0" ] && continue

      AUTHOR=$(echo "$C" | jq -r '.author')
      FILEPATH=$(echo "$C" | jq -r '.path')
      LINE=$(echo "$C" | jq -r '.line')
      BODY_B64=$(echo "$C" | jq -r '.body' | base64 -w0)

      NEW_COMMENTS+="${CID}|${AUTHOR}|${FILEPATH}|${LINE}|${BODY_B64}"$'\n'
    done < <(echo "$COMMENTS_JSON" | jq -c '.[]')

    if [ -n "$NEW_COMMENTS" ]; then
      OUTPUT+="REPO:${REPO}|PR:${PR_NUM}|TITLE:${PR_TITLE}|BRANCH:${PR_BRANCH}"$'\n'
      OUTPUT+="$NEW_COMMENTS"$'\n'
    fi
  done <<< "$PRS"
done

if [ -n "$OUTPUT" ]; then
  echo -e "$OUTPUT"
else
  echo "NO_NEW_COMMENTS"
fi
