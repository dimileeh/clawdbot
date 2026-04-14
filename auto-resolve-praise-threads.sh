#!/usr/bin/env bash
# Auto-resolve praise/affirmation-only review threads so actionable feedback stands out.
set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

# Heuristic: resolve only if message is affirming and does not contain action verbs.
is_praise_only() {
  local body_lc="$1"

  # Must include at least one positive/affirming phrase
  if ! echo "$body_lc" | grep -Eq 'looks good|good addition|great addition|nice|solid|strong positive|keep this|should remain|good guardrail|good safety|good call|good pattern|well done|lgtm'; then
    return 1
  fi

  # Must not include explicit change/fix requests
  if echo "$body_lc" | grep -Eq 'should\s+use|should\s+be|must\s+|fix\b|bug\b|missing\b|incorrect\b|invalid\b|wrong\b|needs\s+to|recommend\b|suggest\b|please\s+|ensure\b|add\s+test|add\s+tests|refactor\b|consider\s+'; then
    return 1
  fi

  return 0
}

resolved=0

for REPO in ${CLAWDBOT_REPOS}; do
  PRS=$(gh pr list --repo "$REPO" --base development --state open --json number --jq '.[].number' 2>/dev/null || true)
  [ -z "$PRS" ] && continue

  while IFS= read -r PR_NUM; do
    [ -z "$PR_NUM" ] && continue

    THREADS_JSON=$(gh api graphql \
      -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{id,isResolved,comments(first:20){nodes{author{login} body createdAt}}}}}}}' \
      -F owner="${REPO%/*}" -F name="${REPO#*/}" -F number="$PR_NUM" \
      2>/dev/null || echo '{}')

    echo "$THREADS_JSON" | jq -c '.data.repository.pullRequest.reviewThreads.nodes[]? | select(.isResolved==false) | {id, comments: [.comments.nodes[]? | {author:(.author.login // ""), body:(.body // ""), createdAt:(.createdAt // "")}]}' | \
    while IFS= read -r T; do
      TID=$(echo "$T" | jq -r '.id')
      BODY=$(echo "$T" | jq -r '.comments[-1].body // ""')
      AUTHOR=$(echo "$T" | jq -r '.comments[-1].author // ""')

      # Only auto-resolve bot-authored praise threads.
      case "$AUTHOR" in
        gemini-code-assist|chatgpt-codex-connector|cursor|cursor[bot]|dependabot[bot]) ;;
        *) continue ;;
      esac

      BODY_LC=$(echo "$BODY" | tr '[:upper:]' '[:lower:]')
      if is_praise_only "$BODY_LC"; then
        gh api graphql \
          -f query='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{id isResolved}}}' \
          -F id="$TID" >/dev/null 2>&1 || true
        resolved=$((resolved+1))
      fi
    done

  done <<< "$PRS"
done

if [ "$resolved" -gt 0 ]; then
  echo "Auto-resolved praise-only review threads: $resolved"
fi
