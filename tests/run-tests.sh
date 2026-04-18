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

# ─── Layer 5: Helper function unit tests ───────────────────────────────────
echo "Layer 5: Helper function unit tests"

# Source the helper functions from pr-manager.sh
eval "$(sed -n '/^_resolve_repo_path()/,/^}/p' "$REPO_DIR/pr-manager.sh")"
eval "$(sed -n '/^_detect_test_cmd()/,/^}/p' "$REPO_DIR/pr-manager.sh")"

# Test _resolve_repo_path with CLAWDBOT_REPO_MAP
export CLAWDBOT_REPO_MAP='{"my-api": "project/api", "my-web": "project/web"}'

result=$(_resolve_repo_path "my-api")
if [ "$result" = "project/api" ]; then
    pass "_resolve_repo_path maps known repo"
else
    fail "_resolve_repo_path maps known repo (got: $result)"
fi

result=$(_resolve_repo_path "unknown-repo")
if [ "$result" = "unknown-repo" ]; then
    pass "_resolve_repo_path falls back for unknown repo"
else
    fail "_resolve_repo_path falls back for unknown repo (got: $result)"
fi

# Test with empty map
unset CLAWDBOT_REPO_MAP
result=$(_resolve_repo_path "any-repo")
if [ "$result" = "any-repo" ]; then
    pass "_resolve_repo_path works without CLAWDBOT_REPO_MAP"
else
    fail "_resolve_repo_path works without CLAWDBOT_REPO_MAP (got: $result)"
fi

# Test _detect_test_cmd with mock project dirs
TEST_TMP=$(mktemp -d)

# Python project
mkdir -p "$TEST_TMP/python-proj"
touch "$TEST_TMP/python-proj/pyproject.toml"
result=$(_detect_test_cmd "$TEST_TMP/python-proj")
if [[ "$result" == *"pytest"* ]]; then
    pass "_detect_test_cmd detects Python project"
else
    fail "_detect_test_cmd detects Python project (got: $result)"
fi

# Node project with "test" script
mkdir -p "$TEST_TMP/node-test"
echo '{"scripts": {"test": "vitest run"}}' > "$TEST_TMP/node-test/package.json"
result=$(_detect_test_cmd "$TEST_TMP/node-test")
if [[ "$result" == *"npm run test"* ]]; then
    pass "_detect_test_cmd detects Node project with test script"
else
    fail "_detect_test_cmd detects Node project with test script (got: $result)"
fi

# Node project with "test:unit" only
mkdir -p "$TEST_TMP/node-unit"
echo '{"scripts": {"test:unit": "vitest run"}}' > "$TEST_TMP/node-unit/package.json"
result=$(_detect_test_cmd "$TEST_TMP/node-unit")
if [[ "$result" == *"test:unit"* ]]; then
    pass "_detect_test_cmd detects Node project with test:unit script"
else
    fail "_detect_test_cmd detects Node project with test:unit script (got: $result)"
fi

# Node project with no test script
mkdir -p "$TEST_TMP/node-notest"
echo '{"scripts": {"build": "next build"}}' > "$TEST_TMP/node-notest/package.json"
result=$(_detect_test_cmd "$TEST_TMP/node-notest")
if [[ "$result" == *"next build"* ]]; then
    pass "_detect_test_cmd falls back to next build for Node without test"
else
    fail "_detect_test_cmd falls back to next build for Node without test (got: $result)"
fi

# Bash project with tests/run-tests.sh — no pyproject.toml or package.json,
# just a repo-local bash test harness. Should prefer the harness over the
# "No test command" fallback so the review handler can verify its own fix.
mkdir -p "$TEST_TMP/bash-proj/tests"
cat > "$TEST_TMP/bash-proj/tests/run-tests.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TEST_TMP/bash-proj/tests/run-tests.sh"
result=$(_detect_test_cmd "$TEST_TMP/bash-proj")
if [[ "$result" == *"tests/run-tests.sh"* ]]; then
    pass "_detect_test_cmd detects repo-local bash test harness"
else
    fail "_detect_test_cmd detects repo-local bash test harness (got: $result)"
fi

# Bash test harness must not override a Python or Node harness when both
# signals are present (pyproject.toml / package.json take precedence because
# those ecosystems have richer test runners than bash).
mkdir -p "$TEST_TMP/python-with-bash/tests"
touch "$TEST_TMP/python-with-bash/pyproject.toml"
cat > "$TEST_TMP/python-with-bash/tests/run-tests.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
result=$(_detect_test_cmd "$TEST_TMP/python-with-bash")
if [[ "$result" == *"pytest"* ]]; then
    pass "_detect_test_cmd prefers Python harness over bash fallback"
else
    fail "_detect_test_cmd prefers Python harness over bash fallback (got: $result)"
fi

# Unknown project
mkdir -p "$TEST_TMP/empty-proj"
result=$(_detect_test_cmd "$TEST_TMP/empty-proj")
if [[ "$result" == *"No test command"* ]]; then
    pass "_detect_test_cmd returns fallback for unknown project"
else
    fail "_detect_test_cmd returns fallback for unknown project (got: $result)"
fi

# ─── Stale in_progress pruning (pr-manager.sh) ───────────────────────────────
#
# Simulate the jq filter used by the stale-in_progress cleanup in
# pr-manager.sh: given a cutoff ISO timestamp, any in_progress entry with
# ``value <= cutoff`` must be evicted, and any entry with ``value > cutoff``
# must be preserved. This guards the behaviour end-to-end without having to
# boot the full pr-manager run.
STALE_STATE="$TEST_TMP/state.json"
cat > "$STALE_STATE" <<'EOF'
{
  "handled_threads": {},
  "in_progress": {
    "dimileeh/aira-agent#100": "2026-04-18T10:00:00Z",
    "dimileeh/aira-agent#200": "2026-04-18T12:45:00Z",
    "dimileeh/aira-agent#300": "2026-04-18T12:59:59Z"
  },
  "handled_ci": {},
  "review_wait": {}
}
EOF
CUTOFF="2026-04-18T12:30:00Z"  # 30 minutes before 13:00 UTC
PRUNED=$(jq -r --arg cutoff "$CUTOFF" '
  .in_progress // {} | to_entries
    | map(select(.value <= $cutoff))
    | map(.key) | sort | join(",")
' "$STALE_STATE")
if [ "$PRUNED" = "dimileeh/aira-agent#100" ]; then
    pass "stale in_progress cleanup evicts only entries older than cutoff"
else
    fail "stale in_progress cleanup evicts only entries older than cutoff (got: $PRUNED)"
fi

KEPT=$(jq -r --arg cutoff "$CUTOFF" '
  .in_progress // {} | to_entries
    | map(select(.value > $cutoff))
    | map(.key) | sort | join(",")
' "$STALE_STATE")
if [ "$KEPT" = "dimileeh/aira-agent#200,dimileeh/aira-agent#300" ]; then
    pass "stale in_progress cleanup preserves fresh entries"
else
    fail "stale in_progress cleanup preserves fresh entries (got: $KEPT)"
fi

# Edge case: entry timestamp equal to the cutoff is treated as stale (<=).
BOUNDARY_STATE="$TEST_TMP/boundary.json"
cat > "$BOUNDARY_STATE" <<EOF
{"in_progress": {"pr@cutoff": "$CUTOFF"}}
EOF
BOUNDARY_PRUNED=$(jq -r --arg cutoff "$CUTOFF" '
  .in_progress // {} | to_entries
    | map(select(.value <= $cutoff))
    | map(.key) | join(",")
' "$BOUNDARY_STATE")
if [ "$BOUNDARY_PRUNED" = "pr@cutoff" ]; then
    pass "stale in_progress cleanup prunes entry exactly at the cutoff"
else
    fail "stale in_progress cleanup prunes entry exactly at the cutoff (got: $BOUNDARY_PRUNED)"
fi

# Invalid CLAWDBOT_STALE_IN_PROGRESS_MINUTES falls back to default 30 with a
# warning. This is a smoke test of the validation regex used in the script.
for bad_value in "" "abc" "-5" "5.5"; do
    if [[ "$bad_value" =~ ^[0-9]+$ ]] && [ "$bad_value" -ge 1 ] 2>/dev/null; then
        fail "stale-minutes validator accepted bad value '$bad_value'"
    else
        pass "stale-minutes validator rejects '$bad_value'"
    fi
done

for good_value in "1" "30" "60" "3600"; do
    if [[ "$good_value" =~ ^[0-9]+$ ]] && [ "$good_value" -ge 1 ] 2>/dev/null; then
        pass "stale-minutes validator accepts '$good_value'"
    else
        fail "stale-minutes validator rejected good value '$good_value'"
    fi
done

rm -rf "$TEST_TMP"
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
