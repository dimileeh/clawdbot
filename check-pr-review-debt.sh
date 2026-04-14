#!/usr/bin/env bash
# check-pr-review-debt.sh — Report PR readiness blockers (conflicts, failing checks, unresolved threads)
#
# Emits NOTHING if there is no change since last run (to avoid spam).
# Otherwise prints a concise report.
set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

STATE_FILE="$HOME/.clawdbot/pr-review-debt-state.json"
mkdir -p "$HOME/.clawdbot"

# --- helpers ---
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

graphql_unresolved_threads() {
  local repo="$1" pr_number="$2"
  # Returns count (int). Best-effort: returns 0 on error.
  gh api graphql -f query='query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{isResolved}}}}}' \
    -F owner="${repo%/*}" -F name="${repo#*/}" -F number="$pr_number" \
    --jq '.data.repository.pullRequest.reviewThreads.nodes | map(select(.isResolved==false)) | length' \
    2>/dev/null || echo 0
}

collect_repo() {
  local repo="$1"
  gh pr list --repo "$repo" --base development --state open \
    --json number,title,url,headRefName,isDraft \
    --jq '.[] | @base64' 2>/dev/null || true
}

REPORT_LINES=()
RAW_ITEMS=()

for REPO in ${CLAWDBOT_REPOS}; do
  while IFS= read -r pr_b64; do
    [ -z "$pr_b64" ] && continue
    pr_json="$(echo "$pr_b64" | base64 -d)"

    num="$(echo "$pr_json" | jq -r '.number')"
    title="$(echo "$pr_json" | jq -r '.title')"
    url="$(echo "$pr_json" | jq -r '.url')"
    head="$(echo "$pr_json" | jq -r '.headRefName')"
    draft="$(echo "$pr_json" | jq -r '.isDraft')"

    view_json="$(gh pr view "$num" --repo "$REPO" \
      --json mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,isDraft \
      2>/dev/null || echo '{}')"

    mergeable="$(echo "$view_json" | jq -r '.mergeable // "UNKNOWN"')"
    merge_state="$(echo "$view_json" | jq -r '.mergeStateStatus // "UNKNOWN"')"
    review_decision="$(echo "$view_json" | jq -r '.reviewDecision // ""')"

    # checks
    failing_checks="$(echo "$view_json" | jq -r '[.statusCheckRollup.contexts[]? | select((.conclusion // "")|IN("FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE"))] | length' 2>/dev/null || echo 0)"
    pending_checks="$(echo "$view_json" | jq -r '[.statusCheckRollup.contexts[]? | select((.conclusion==null) and (.state!=null) and (.state!="SUCCESS"))] | length' 2>/dev/null || echo 0)"

    unresolved_threads="$(graphql_unresolved_threads "$REPO" "$num")"

    # determine blockers
    blockers=()
    if [ "$mergeable" = "CONFLICTING" ] || [ "$merge_state" = "DIRTY" ]; then
      blockers+=("conflicts")
    fi
    if [ "$failing_checks" != "0" ]; then
      blockers+=("checks failing:$failing_checks")
    fi
    if [ "$pending_checks" != "0" ]; then
      blockers+=("checks pending:$pending_checks")
    fi
    if [ "$unresolved_threads" != "0" ]; then
      blockers+=("unresolved threads:$unresolved_threads")
    fi
    if [ "$review_decision" = "CHANGES_REQUESTED" ]; then
      blockers+=("changes requested")
    fi
    if [ "$draft" = "true" ]; then
      blockers+=("draft")
    fi

    RAW_ITEMS+=("$(jq -c -n --arg repo "$REPO" --argjson num "$num" --arg url "$url" --arg head "$head" --arg title "$title" --arg mergeable "$mergeable" --arg merge_state "$merge_state" --arg review "$review_decision" --argjson failing "$failing_checks" --argjson pending "$pending_checks" --argjson threads "$unresolved_threads" --argjson draft "$draft" '{repo:$repo,number:$num,url:$url,head:$head,title:$title,mergeable:$mergeable,mergeStateStatus:$merge_state,reviewDecision:$review,failingChecks:$failing,pendingChecks:$pending,unresolvedThreads:$threads,isDraft:$draft}')")

    if [ ${#blockers[@]} -gt 0 ]; then
      REPORT_LINES+=("- $REPO #$num — $title")
      REPORT_LINES+=("  $url")
      REPORT_LINES+=("  blockers: $(IFS=', '; echo "${blockers[*]}")")
    fi
  done < <(collect_repo "$REPO")

done

raw_json="$(printf '%s\n' "${RAW_ITEMS[@]:-}" | jq -s 'sort_by(.repo,.number)')"
raw_hash="$(echo "$raw_json" | sha256)"

last_hash=""
if [ -f "$STATE_FILE" ]; then
  last_hash="$(jq -r '.lastHash // ""' "$STATE_FILE" 2>/dev/null || echo "")"
fi

# If no blockers, still keep state, but don't output.
if [ "$raw_hash" = "$last_hash" ]; then
  exit 0
fi

echo "{\"lastHash\":\"$raw_hash\",\"updatedAt\":$(date +%s)}" > "$STATE_FILE"

# Only output when there are blockers.
if [ ${#REPORT_LINES[@]} -eq 0 ]; then
  exit 0
fi

printf '%s\n' "${REPORT_LINES[@]}"
