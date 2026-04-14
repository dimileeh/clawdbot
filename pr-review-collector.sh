#!/bin/bash
# pr-review-collector.sh — Collect unresolved PR review threads as structured JSON
#
# Output: JSON array of PRs with unresolved, non-outdated review threads.
# Zero LLM tokens. Called by the pr-review-handler cron job.

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

REPOS="${CLAWDBOT_REPOS}"
STATE_FILE="$HOME/.clawdbot/pr-review-handler-state.json"

[ -f "$STATE_FILE" ] || echo '{"handled_threads":{}}' > "$STATE_FILE"

RESULTS="[]"

for REPO in $REPOS; do
    REPO_NAME=$(echo "$REPO" | cut -d/ -f2)

    PR_DATA=$(gh api graphql -f query="
    {
      repository(owner: \"${CLAWDBOT_GITHUB_OWNER}\", name: \"$REPO_NAME\") {
        pullRequests(states: OPEN, first: 15) {
          nodes {
            number
            title
            baseRefName
            headRefName
            url
            isDraft
            reviewThreads(first: 100) {
              nodes {
                id
                isResolved
                isOutdated
                comments(first: 15) {
                  nodes {
                    id
                    body
                    author { login }
                    path
                    line
                    createdAt
                  }
                }
              }
            }
          }
        }
      }
    }" 2>/dev/null || echo '{"data":{"repository":{"pullRequests":{"nodes":[]}}}}')

    # Filter to PRs with unresolved non-outdated threads, skip dependabot/drafts/pending CI
    FILTERED=$(echo "$PR_DATA" | jq --arg repo "$REPO" '
      [.data.repository.pullRequests.nodes[]
       | select(.isDraft == false)
       | select(.title | test("^chore\\(deps"; "i") | not)
       # No CI gate — review threads should be addressed regardless of check status
       | . as $pr
       | {
           repo: $repo,
           number: .number,
           title: .title,
           base: .baseRefName,
           head: .headRefName,
           url: .url,
           unresolved_threads: [
             .reviewThreads.nodes[]
             | select(.isResolved == false and .isOutdated == false)
             | {
                 thread_id: .id,
                 comments: [.comments.nodes[] | {
                   id: .id,
                   author: .author.login,
                   path: .path,
                   line: .line,
                   body: .body,
                   created_at: .createdAt
                 }]
               }
           ]
         }
       | select(.unresolved_threads | length > 0)
      ]' 2>/dev/null || echo '[]')

    # Filter out already-handled threads
    HANDLED=$(jq -r '.handled_threads | keys[]' "$STATE_FILE" 2>/dev/null || true)

    if [ -n "$HANDLED" ]; then
        FILTERED=$(echo "$FILTERED" | jq --argjson handled "$(jq '.handled_threads' "$STATE_FILE")" '
          [.[] | .unresolved_threads = [
            .unresolved_threads[] | select(.thread_id as $tid | $handled[$tid] == null)
          ] | select(.unresolved_threads | length > 0)]
        ')
    fi

    RESULTS=$(echo "$RESULTS" "$FILTERED" | jq -s '.[0] + .[1]')
done

echo "$RESULTS"
