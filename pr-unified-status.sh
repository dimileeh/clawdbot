#!/usr/bin/env bash
# pr-unified-status.sh
# Unified PR status across all monitored repos with strict mergeability semantics.

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a
export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

read -ra REPOS <<< "${CLAWDBOT_REPOS}"

has_output=0

for repo in "${REPOS[@]}"; do
  prs=$(gh pr list --repo "$repo" --state open --json number --jq '.[].number' 2>/dev/null || true)
  [[ -z "$prs" ]] && continue

  echo "$repo"
  has_output=1

  while IFS= read -r pr; do
    [[ -z "$pr" ]] && continue
    view=$(gh pr view "$pr" --repo "$repo" --json number,url,author,mergeable,mergeStateStatus,commits,comments,statusCheckRollup 2>/dev/null || echo '{}')

    mergeable=$(echo "$view" | jq -r '.mergeable // "UNKNOWN"')
    merge_state=$(echo "$view" | jq -r '.mergeStateStatus // "UNKNOWN"')
    author=$(echo "$view" | jq -r '.author.login // ""')
    is_dependabot=false
    if [[ "$repo" == "${CLAWDBOT_DEPENDABOT_REPO:-}" ]] && [[ "$author" == *"dependabot"* ]]; then
      case "$pr" in
        96|95|94|93|92|91)
          is_dependabot=true
          ;;
      esac
    fi

    # CI state from checks buckets (pass/fail/pending). Ignore SKIPPED and treat NEUTRAL as pass-equivalent.
    ci_raw=$(gh pr checks "$pr" --repo "$repo" --json name,state 2>/dev/null || echo '[]')
    ci=$(echo "$ci_raw" | jq -r '[.[] | select(.state != "SKIPPED") | .state] as $checks
      | if ($checks | length) == 0 then "none"
        elif all($checks[]; . == "SUCCESS" or . == "NEUTRAL") then "pass"
        elif any($checks[]; . == "FAILURE") then "fail"
        else "pending" end')

    # Cursor Bugbot can be SUCCESS or NEUTRAL to consider merge-ready.
    bugbot=$(echo "$view" | jq -r '
      ([.statusCheckRollup[]? | select(.name == "Cursor Bugbot")][0]) as $b |
      if $b == null then "MISSING"
      elif ($b.status // "") != "COMPLETED" then "PENDING"
      elif ($b.conclusion // "") == "SUCCESS" then "SUCCESS"
      elif ($b.conclusion // "") == "NEUTRAL" then "SUCCESS"
      elif ($b.conclusion // "") == "" then "PENDING"
      else "FAIL"
      end')

    # Detect pending cursor patch tokens newer than latest commit and not yet handled.
    latest=$(echo "$view" | jq -r '.commits[-1].committedDate // ""')
    pending_tokens=$(echo "$view" | jq -r --arg latest "$latest" '
      [.comments[]?
       | select(.author.login == "cursor")
       | select(.body|test("BUGBOT_AUTOFIX_COMMENT","i"))
       | select($latest == "" or .createdAt > $latest)
       | (.body | capture("@cursor push (?<tok>[a-f0-9]{8,})"; "i").tok // empty)
      ] | unique | .[]')

    action_needed="NO ACTION"
    if [[ -n "$pending_tokens" ]]; then
      unresolved=0
      while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        handled=$(echo "$view" | jq -r --arg tok "$tok" '
          [ .comments[]?
            | select(.body|test("@cursor push " + $tok; "i") or (.body|test("\\[Spark Cursor Decision token:" + $tok + "\\]"; "i"))
          ] | length')
        # handled > 1 means someone acted/commented beyond the original suggestion.
        if [[ "$handled" -le 1 ]]; then
          unresolved=$((unresolved + 1))
        fi
      done <<< "$pending_tokens"
      if [[ "$unresolved" -gt 0 ]]; then
        action_needed="ACTION NEEDED"
      fi
    fi

    strict="NOT_MERGEABLE"
    if [[ "$is_dependabot" == true ]]; then
      if [[ "$mergeable" != "CONFLICTING" && "$merge_state" != "DIRTY" && "$ci" == "pass" && "$action_needed" == "NO ACTION" ]]; then
        strict="MANUAL_EVAL"
        action_needed="MANUAL REVIEW"
      fi
      # Dependabot dependency bumps should be evaluated manually even when CI is green.
      bugbot="SKIP"
    elif [[ "$mergeable" != "CONFLICTING" && "$merge_state" != "DIRTY" && "$ci" == "pass" && "$bugbot" == "SUCCESS" && "$action_needed" == "NO ACTION" ]]; then
      strict="MERGEABLE"
    fi

    url=$(echo "$view" | jq -r '.url // ""')
    echo "- #$pr $strict | merge:${mergeable}/${merge_state} | CI:${ci} | BugBot:${bugbot} | Cursor:${action_needed} | $url"
  done <<< "$prs"

  echo

done

# no output when no open PRs
if [[ "$has_output" -eq 0 ]]; then
  exit 0
fi
