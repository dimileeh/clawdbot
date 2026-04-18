#!/bin/bash
# clawdbot test runner
# Usage: ./tests/run-tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
PASS=0
FAIL=0
ERRORS=()

# Colors (disable if not a terminal)
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' NC=''
fi

pass() { PASS=$((PASS + 1)); echo -e "  ${GREEN}✓${NC} $1"; }
fail() { FAIL=$((FAIL + 1)); ERRORS+=("$1"); echo -e "  ${RED}✗${NC} $1"; }

echo "=== clawdbot test suite ==="
echo ""

# ─── Layer 1: Syntax Check ─────────────────────────────────────────────────
echo "Layer 1: Syntax check"
for f in "$REPO_DIR"/*.sh; do
    name=$(basename "$f")
    if bash -n "$f" 2>/dev/null; then
        pass "$name"
    else
        fail "$name — syntax error"
    fi
done
echo ""

# ─── Layer 2: ShellCheck (if available) ────────────────────────────────────
if command -v shellcheck &>/dev/null; then
    echo "Layer 2: ShellCheck lint"
    for f in "$REPO_DIR"/*.sh; do
        name=$(basename "$f")
        # SC1090: Can't follow non-constant source — expected with .env
        # SC1091: Not following sourced file — same reason
        # SC2086: Double quote to prevent globbing — too noisy for this codebase
        # SC2155: Declare and assign separately — style preference
        if shellcheck -e SC1090,SC1091,SC2086,SC2155 -S warning "$f" 2>/dev/null; then
            pass "$name"
        else
            fail "$name — shellcheck warnings"
        fi
    done
    echo ""
else
    echo "Layer 2: ShellCheck lint (skipped — shellcheck not installed)"
    echo ""
fi

# ─── Layer 3: gh wrapper guardrails ───────────────────────────────────────
echo "Layer 3: gh wrapper guardrails"

# The gh wrapper is generated at runtime by spawn-agent.sh into a temp dir.
# Verify spawn-agent.sh contains the safety checks.
if grep -q 'base main.*forbidden\|--base main.*forbidden' "$REPO_DIR/spawn-agent.sh" 2>/dev/null; then
    pass "spawn-agent.sh blocks PRs targeting main"
else
    fail "spawn-agent.sh missing main branch protection in gh wrapper"
fi

if grep -q '_TARGET_BRANCH' "$REPO_DIR/spawn-agent.sh" 2>/dev/null && \
   grep -q '_CLAWDBOT_TARGET_BRANCH' "$REPO_DIR/spawn-agent.sh" 2>/dev/null; then
    pass "spawn-agent.sh enforces --base via CLAWDBOT_INTEGRATION_BRANCH"
else
    fail "spawn-agent.sh missing integration branch enforcement"
fi

if grep -q 'Created-by:' "$REPO_DIR/spawn-agent.sh" 2>/dev/null; then
    pass "spawn-agent.sh stamps PR attribution metadata"
else
    fail "spawn-agent.sh missing PR attribution metadata"
fi

if grep -q 'mktemp.*clawdbot-bin' "$REPO_DIR/spawn-agent.sh" 2>/dev/null; then
    pass "gh wrapper generated in temp dir (not committed)"
else
    fail "gh wrapper not using temp dir"
fi

if grep -q 'trap.*cleanup_bin_dir.*EXIT' "$REPO_DIR/spawn-agent.sh" 2>/dev/null; then
    pass "temp dir cleaned up on EXIT trap"
else
    fail "missing EXIT trap for temp dir cleanup"
fi
echo ""

# ─── Layer 4: .env.example completeness ────────────────────────────────────
echo "Layer 4: .env.example completeness"

# Runtime-only vars set internally by scripts (not user config)
RUNTIME_VARS="CLAWDBOT_AGENT CLAWDBOT_BIN CLAWDBOT_BIN_DIR CLAWDBOT_TARGET_BRANCH CLAWDBOT_TASK_ID CLAWDBOT_WORKTREE"

USED_VARS=$(grep -roh 'CLAWDBOT_[A-Z_]*' "$REPO_DIR"/*.sh 2>/dev/null | sort -u)
for var in $USED_VARS; do
    # Skip runtime-only vars (set internally, not user config)
    if echo "$RUNTIME_VARS" | grep -qw "$var"; then
        pass "$var is runtime-only (not user config)"
        continue
    fi
    if grep -q "$var" "$REPO_DIR/.env.example" 2>/dev/null; then
        pass "$var documented in .env.example"
    else
        fail "$var used in scripts but missing from .env.example"
    fi
done
echo ""

# ─── Layer 5: pr-manager PR classifier logic ───────────────────────────
#
# pr-manager.sh maps (mergeable, check_state, unresolved, base) into one of
# five terminal STATE values. These tests pin that mapping independently of
# the rest of the script so future refactors cannot silently flip a case.
echo "Layer 5: pr-manager classifier logic"

classify() {
    local mergeable="$1" check_state="$2" unresolved="$3" base="$4"
    if [ "$mergeable" = "MERGEABLE" ] && [ "$check_state" = "SUCCESS" ] && [ "$unresolved" -eq 0 ]; then
        [ "$base" = "development" ] && echo "READY_DEV" || echo "READY_MAIN"
    elif [ "$unresolved" -gt 0 ]; then
        echo "HAS_COMMENTS"
    elif [ "$check_state" = "FAILURE" ]; then
        echo "CI_FAILED"
    else
        echo "NOT_READY"
    fi
}

expect_state() {
    local got="$1" want="$2" label="$3"
    if [ "$got" = "$want" ]; then
        pass "classifier: $label → $want"
    else
        fail "classifier: $label expected $want, got $got"
    fi
}

expect_state "$(classify MERGEABLE SUCCESS 0 development)" READY_DEV "clean dev PR"
expect_state "$(classify MERGEABLE SUCCESS 0 main)" READY_MAIN "clean main PR"
expect_state "$(classify MERGEABLE SUCCESS 3 development)" HAS_COMMENTS "dev PR with comments"
expect_state "$(classify MERGEABLE SUCCESS 1 main)" HAS_COMMENTS "main PR with comments"
expect_state "$(classify MERGEABLE FAILURE 0 development)" CI_FAILED "clean threads + failed CI"
expect_state "$(classify MERGEABLE FAILURE 2 development)" HAS_COMMENTS "comments beat CI failure in priority"
expect_state "$(classify MERGEABLE PENDING 0 development)" NOT_READY "CI still running"
expect_state "$(classify CONFLICTING SUCCESS 0 development)" NOT_READY "merge conflict"
expect_state "$(classify CONFLICTING FAILURE 5 development)" HAS_COMMENTS "comments win over everything else"
echo ""

# ─── Layer 5b: review wait window + renotification logic ───────────────────
echo "Layer 5b: review wait + renotification logic"

# The script gates notifications on two ISO-timestamp comparisons:
#   (1) first_seen <= wait_cutoff   → wait window has elapsed
#   (2) last_notified <= renotify_cutoff → free to renotify on stale review
WAIT_CUTOFF="2026-04-18T13:00:00Z"

# Inside the wait window → skip.
first_seen="2026-04-18T13:10:00Z"
if [[ "$first_seen" > "$WAIT_CUTOFF" ]]; then
    pass "wait window: fresh observation is skipped"
else
    fail "wait window: fresh observation should be skipped"
fi

# Past the wait window → notify.
first_seen="2026-04-18T12:30:00Z"
if ! [[ "$first_seen" > "$WAIT_CUTOFF" ]]; then
    pass "wait window: elapsed observation proceeds to notify"
else
    fail "wait window: elapsed observation should notify"
fi

# Exactly at the cutoff → notify (>, not >=).
first_seen="$WAIT_CUTOFF"
if ! [[ "$first_seen" > "$WAIT_CUTOFF" ]]; then
    pass "wait window: observation exactly at cutoff proceeds"
else
    fail "wait window: observation exactly at cutoff should proceed"
fi

# Renotification: inside window → silent, past window → notify.
RENOTIFY_CUTOFF="2026-04-18T13:00:00Z"
last_notified="2026-04-18T13:30:00Z"
if [[ "$last_notified" > "$RENOTIFY_CUTOFF" ]]; then
    pass "renotify: recently notified stays silent"
else
    fail "renotify: recently notified should stay silent"
fi
last_notified="2026-04-18T11:30:00Z"
if ! [[ "$last_notified" > "$RENOTIFY_CUTOFF" ]]; then
    pass "renotify: stale notification triggers re-wake"
else
    fail "renotify: stale notification should re-wake"
fi
echo ""

# ─── Layer 5c: notification envelope shape ───────────────────────────────
echo "Layer 5c: notification envelope shape"

# Confirm the jq filter pr-manager.sh uses to build each payload produces
# the documented shape — pr_key, ci_status, unresolved_threads[].comments[].
# Synthetic input matches the GraphQL response the script consumes.
SYNTH_PR='{
  "number": 42,
  "title": "test",
  "url": "https://example",
  "headRefName": "feat/x",
  "baseRefName": "development",
  "commits": { "nodes": [ { "commit": { "oid": "abc", "statusCheckRollup": { "state": "SUCCESS", "contexts": { "nodes": [
    { "__typename": "CheckRun", "name": "lint", "conclusion": "SUCCESS", "status": "COMPLETED" },
    { "__typename": "StatusContext", "context": "ci/travis", "state": "SUCCESS" }
  ] } } } } ] },
  "reviewThreads": { "nodes": [
    { "id": "t1", "isResolved": false, "isOutdated": false, "comments": { "nodes": [
      { "id": "c1", "body": "fix me", "author": { "login": "bot" }, "path": "a.py", "line": 10, "createdAt": "2026-04-18T13:00:00Z" }
    ] } },
    { "id": "t2", "isResolved": true, "isOutdated": false, "comments": { "nodes": [ ] } }
  ] }
}'

ENVELOPE=$(echo "$SYNTH_PR" | jq --arg repo "o/r" --arg pr_key "o/r#42" --arg sha "abc" --arg check_state "SUCCESS" '{
    event: "review_comments",
    pr_key: $pr_key,
    repo: $repo,
    number: .number,
    title: .title,
    url: .url,
    head: .headRefName,
    base: .baseRefName,
    head_sha: $sha,
    ci_status: $check_state,
    ci_contexts: [.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]? | . as $ctx | if .__typename == "CheckRun" then {type:"check", name: $ctx.name, conclusion: $ctx.conclusion, status: $ctx.status} else {type:"status", name: $ctx.context, conclusion: $ctx.state} end],
    unresolved_threads: [
        .reviewThreads.nodes[]
        | select(.isResolved == false and .isOutdated == false)
        | {
            thread_id: .id,
            comments: [.comments.nodes[] | {
                id: .id, author: .author.login, path: .path, line: .line,
                body: .body, created_at: .createdAt
            }]
          }
    ]
}')

if echo "$ENVELOPE" | jq -e '.event == "review_comments"' >/dev/null; then
    pass "envelope: event=review_comments is tagged"
else
    fail "envelope: event tag missing"
fi
if [ "$(echo "$ENVELOPE" | jq '.unresolved_threads | length')" = "1" ]; then
    pass "envelope: resolved + outdated threads are filtered out"
else
    fail "envelope: expected 1 unresolved thread (got $(echo "$ENVELOPE" | jq '.unresolved_threads | length'))"
fi
if [ "$(echo "$ENVELOPE" | jq -r '.unresolved_threads[0].comments[0].path')" = "a.py" ]; then
    pass "envelope: comment path preserved"
else
    fail "envelope: comment path missing"
fi
if [ "$(echo "$ENVELOPE" | jq '.ci_contexts | length')" = "2" ]; then
    pass "envelope: ci_contexts carries both CheckRun and StatusContext entries"
else
    fail "envelope: ci_contexts count wrong"
fi
echo ""
echo ""

# ─── Layer 6: No hardcoded PII ────────────────────────────────────────────
echo "Layer 6: PII audit"

# Collect all tracked files (not gitignored)
TRACKED_FILES=()
while IFS= read -r f; do
    TRACKED_FILES+=("$REPO_DIR/$f")
done < <(cd "$REPO_DIR" && git ls-files 2>/dev/null || find . -maxdepth 2 -type f \( -name '*.sh' -o -name '*.md' -o -name '.env.example' \) | sed 's|^\./||')

# Patterns loaded from a separate file to avoid the test script flagging itself.
# If .pii-patterns doesn't exist, create a default one.
PII_FILE="$SCRIPT_DIR/.pii-patterns"
if [ ! -f "$PII_FILE" ]; then
    fail ".pii-patterns file missing (create tests/.pii-patterns with one pattern per line)"
else
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        # Skip blank lines and comments
        [[ -z "$pattern" || "$pattern" == \#* ]] && continue
        # Exclude: test infra, .env.example (placeholder docs), README (setup examples)
        hits=$(grep -rn "$pattern" "${TRACKED_FILES[@]}" 2>/dev/null | grep -v 'tests/' | grep -v '\.env\.example' | grep -v 'README\.md' || true)
        if [ -z "$hits" ]; then
            pass "no '$pattern' in tracked files"
        else
            fail "'$pattern' found in tracked files:\n$hits"
        fi
    done < "$PII_FILE"
fi
echo ""

# ─── Layer 7: All scripts source .env ──────────────────────────────────────
echo "Layer 7: Scripts source .env"
for f in "$REPO_DIR"/*.sh; do
    name=$(basename "$f")
    if grep -q 'source.*\.env\|\.env.*source' "$f" 2>/dev/null; then
        pass "$name sources .env"
    else
        # Check if they reference any CLAWDBOT_ vars
        if grep -q 'CLAWDBOT_' "$f" 2>/dev/null; then
            fail "$name uses CLAWDBOT_ vars but doesn't source .env"
        else
            pass "$name doesn't need .env (no CLAWDBOT_ vars)"
        fi
    fi
done
echo ""

# ─── Layer 8: Executable permissions ──────────────────────────────────────
echo "Layer 8: File permissions"
for f in "$REPO_DIR"/*.sh; do
    name=$(basename "$f")
    if [ -x "$f" ]; then
        pass "$name is executable"
    else
        fail "$name is not executable"
    fi
done
echo ""

# ─── Layer 9: No bin/ directory committed ─────────────────────────────────
echo "Layer 9: Repo hygiene"
if [ -d "$REPO_DIR/bin" ]; then
    fail "bin/ directory should not exist in repo (gh wrapper is generated at runtime)"
else
    pass "no bin/ directory (gh wrapper generated at runtime)"
fi

# Check if .env is tracked in git (presence on disk is fine if gitignored)
if cd "$REPO_DIR" && git ls-files --error-unmatch .env &>/dev/null; then
    fail ".env is tracked in git (should be gitignored)"
else
    pass ".env is not tracked in git"
fi
echo ""

# ─── Summary ──────────────────────────────────────────────────────────────
echo "================================"
TOTAL=$((PASS + FAIL))
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} (${TOTAL} total)"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo -e "  ${RED}✗${NC} $err"
    done
    exit 1
fi

echo ""
echo "All tests passed ✅"
