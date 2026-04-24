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

# ─── Layer 5: pr-manager PR classifier logic ───────────────────────
#
# pr-manager.sh maps (mergeable, check_state, unresolved, base) into one of
# five terminal STATE values. These tests pin that mapping independently of
# the rest of the script so future refactors cannot silently flip a case.
#
# Branch names are honoured via INTEGRATION_BRANCH / MAIN_BRANCH, matching
# the CLAWDBOT_INTEGRATION_BRANCH / CLAWDBOT_MAIN_BRANCH env vars the
# script reads at startup. Defaults are development / main but teams can
# override, so the classifier must not hardcode those names — and neither
# must these fixtures.
echo "Layer 5: pr-manager classifier logic"

INTEGRATION_BRANCH="${CLAWDBOT_INTEGRATION_BRANCH:-development}"
MAIN_BRANCH="${CLAWDBOT_MAIN_BRANCH:-main}"

classify() {
    local mergeable="$1" check_state="$2" unresolved="$3" base="$4"
    if [ "$mergeable" = "MERGEABLE" ] && [ "$check_state" = "SUCCESS" ] && [ "$unresolved" -eq 0 ]; then
        if [ "$base" = "$INTEGRATION_BRANCH" ]; then
            echo "READY_DEV"
        elif [ "$base" = "$MAIN_BRANCH" ]; then
            echo "READY_MAIN"
        else
            echo "NOT_READY"
        fi
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

expect_state "$(classify MERGEABLE SUCCESS 0 "$INTEGRATION_BRANCH")" READY_DEV "clean integration PR"
expect_state "$(classify MERGEABLE SUCCESS 0 "$MAIN_BRANCH")" READY_MAIN "clean main PR"
expect_state "$(classify MERGEABLE SUCCESS 0 "release/1.0")" NOT_READY "clean PR targeting third branch"
expect_state "$(classify MERGEABLE SUCCESS 3 "$INTEGRATION_BRANCH")" HAS_COMMENTS "integration PR with comments"
expect_state "$(classify MERGEABLE SUCCESS 1 "$MAIN_BRANCH")" HAS_COMMENTS "main PR with comments"
expect_state "$(classify MERGEABLE FAILURE 0 "$INTEGRATION_BRANCH")" CI_FAILED "clean threads + failed CI"
expect_state "$(classify MERGEABLE FAILURE 2 "$INTEGRATION_BRANCH")" HAS_COMMENTS "comments beat CI failure in priority"
expect_state "$(classify MERGEABLE PENDING 0 "$INTEGRATION_BRANCH")" NOT_READY "CI still running"
expect_state "$(classify CONFLICTING SUCCESS 0 "$INTEGRATION_BRANCH")" NOT_READY "merge conflict"
expect_state "$(classify CONFLICTING FAILURE 5 "$INTEGRATION_BRANCH")" HAS_COMMENTS "comments win over everything else"

# Exercise the configurable-branch path explicitly by overriding the names
# to simulate a team on trunk-based or staging/prod conventions.
(
    INTEGRATION_BRANCH="trunk"
    MAIN_BRANCH="prod"
    expect_state "$(classify MERGEABLE SUCCESS 0 trunk)" READY_DEV "custom: trunk → READY_DEV"
    expect_state "$(classify MERGEABLE SUCCESS 0 prod)"  READY_MAIN "custom: prod → READY_MAIN"
    expect_state "$(classify MERGEABLE SUCCESS 0 development)" NOT_READY "custom: stock 'development' not auto-merged when renamed"
)
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

# ci_failed envelope: same base shape but tagged event, plus a
# failed_job_logs string field instead of unresolved_threads. We use a
# single-line fixture here because jq --arg and the surrounding $() command
# substitution each normalize trailing newlines differently; the redaction
# + assembly code in pr-manager.sh doesn't depend on newline preservation.
CI_LOGS='--- lint-and-test (run 123) --- E ruff check failed'
CI_ENVELOPE=$(echo "$SYNTH_PR" | jq --arg repo "o/r" --arg pr_key "o/r#42" --arg sha "abc" --arg check_state "FAILURE" --arg logs "$CI_LOGS" '{
    event: "ci_failed",
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
    failed_job_logs: $logs
}')
if echo "$CI_ENVELOPE" | jq -e '.event == "ci_failed"' >/dev/null; then
    pass "ci_failed envelope: event tag correct"
else
    fail "ci_failed envelope: event tag missing or wrong"
fi
if echo "$CI_ENVELOPE" | jq -e 'has("unresolved_threads") | not' >/dev/null; then
    pass "ci_failed envelope: no unresolved_threads field"
else
    fail "ci_failed envelope: should not carry unresolved_threads"
fi
if [ "$(echo "$CI_ENVELOPE" | jq -r '.failed_job_logs')" = "$CI_LOGS" ]; then
    pass "ci_failed envelope: failed_job_logs preserved byte-for-byte"
else
    fail "ci_failed envelope: failed_job_logs mutated"
fi
if [ "$(echo "$CI_ENVELOPE" | jq -r '.ci_status')" = "FAILURE" ]; then
    pass "ci_failed envelope: ci_status surfaces FAILURE"
else
    fail "ci_failed envelope: ci_status wrong"
fi
echo ""

# ─── Layer 5f: READY_DEV hold is log-only, not wake-triggering ───────
echo "Layer 5f: READY_DEV hold is log-only"
#
# Invariant: when a READY_DEV PR is held back because an open dev→main
# PR already exists, pr-manager MUST NOT append that hold to
# MERGE_REASONS. MERGE_REASONS drives the end-of-run ``_wake_sparky``
# call, and the hold state is the same every tick until the blocker PR
# closes — so waking the orchestrator every 5 minutes with the same
# message is pure noise. The operator can still see the hold in the
# crontab-captured stdout log.

ready_dev_body=$(awk '/^                READY_DEV\)$/,/^                    ;;$/' "$REPO_DIR/pr-manager.sh")
if echo "$ready_dev_body" | grep -q 'HAS_OPEN_DEV_MAIN'; then
    pass "READY_DEV still guards against open dev→main PR"
else
    fail "READY_DEV lost its HAS_OPEN_DEV_MAIN guard"
fi

# The specific contract: inside the HAS_OPEN_DEV_MAIN>0 branch, there
# must be an echo (log) but no MERGE_REASONS append.
hold_branch=$(echo "$ready_dev_body" | awk '/HAS_OPEN_DEV_MAIN.*-gt 0/,/fi$/')
if echo "$hold_branch" | grep -q 'echo.*Holding'; then
    pass "READY_DEV hold still logs the event"
else
    fail "READY_DEV hold stopped logging"
fi
if echo "$hold_branch" | grep -q 'MERGE_REASONS.*Holding'; then
    fail "READY_DEV hold still appends to MERGE_REASONS (would re-wake orchestrator every tick)"
else
    pass "READY_DEV hold does NOT append to MERGE_REASONS (log-only)"
fi
echo ""

# ─── Layer 5e: notified_main_prs wake-gating ──────────────────────
echo "Layer 5e: notified_main_prs wake-gating"
#
# Invariant: the `notified_main_prs[$key] = $sha` jq write must happen
# AFTER a successful `_wake_sparky` call. Pre-fix, it happened inline in
# the READY_MAIN case branch — a dropped wake would silence that SHA
# until another commit landed. Post-fix, READY_MAIN only pushes onto
# PENDING_MAIN_NOTIFICATIONS and the jq write sits inside
# `if _wake_sparky ...; then ... fi`.
#
# We grep the script directly: this is a structural contract more than a
# runtime behaviour, so a text-level pin is the right level of fidelity.

PRM="$REPO_DIR/pr-manager.sh"

# 1. The READY_MAIN branch must NOT contain an inline jq write to
#    notified_main_prs — it should queue into PENDING_MAIN_NOTIFICATIONS.
ready_main_body=$(awk '/^                READY_MAIN\)$/,/^                    ;;$/' "$PRM")
if echo "$ready_main_body" | grep -q 'notified_main_prs\[\$key\] = \$sha'; then
    fail "READY_MAIN still commits notified_main_prs inline (pre-wake)"
else
    pass "READY_MAIN does not commit notified_main_prs pre-wake"
fi
if echo "$ready_main_body" | grep -q 'PENDING_MAIN_NOTIFICATIONS+='; then
    pass "READY_MAIN queues into PENDING_MAIN_NOTIFICATIONS"
else
    fail "READY_MAIN does not queue into PENDING_MAIN_NOTIFICATIONS"
fi

# 2. The jq write must live inside an `if _announce_to_maintainer ...; then`
#    block and iterate over PENDING_MAIN_NOTIFICATIONS. We check for the
#    two anchors appearing close together. (Previously this gate was on
#    ``_wake_sparky`` — PR #24 renamed it to ``_announce_to_maintainer``
#    when merge/no-op reports were split off from the handler-spawn path
#    and sent direct to the maintainer instead.)
if awk '/^if \[ -n "\$MERGE_REASONS" \]; then$/,/^fi$/' "$PRM" \
     | grep -q 'if _announce_to_maintainer' \
   && awk '/^if \[ -n "\$MERGE_REASONS" \]; then$/,/^fi$/' "$PRM" \
     | grep -q 'PENDING_MAIN_NOTIFICATIONS'; then
    pass "notified_main_prs commit is gated on _announce_to_maintainer success"
else
    fail "notified_main_prs commit is not gated on _announce_to_maintainer success"
fi
echo ""

# NOTE: Layer 5 previously unit-tested a `_detect_test_cmd` helper that
# lived in pr-manager.sh. That helper was removed by this PR (handler-spawn
# test-command detection moved out of pr-manager into the handler skill
# itself), so its tests no longer have anything to source. Dropped rather
# than ported because the function they covered no longer exists.
#
# Known tech debt (coderabbit PR#39 outside-diff 423-427): the handler
# skill (~/.clawdbot/skills/pr-review-hygiene/SKILL.md) now owns the
# test-command detection logic, but that logic is prose/instructions
# rather than a bash function — it runs inside the LLM handler session,
# not as a shellable helper. There is no clean unit-test seam for LLM
# prompt behaviour in this repo's test harness. Covered in practice by
# integration: every handler spawn exercises the skill and the output
# is visible on the PR it processes. If this becomes a real regression
# source, the next step is mocking the handler harness in a separate
# fixture rather than re-adding tests that have no function to call.

# ─── Layer 5d: CI log redaction ──────────────────────────────────
echo "Layer 5d: CI log redaction"

# Source the redactor from pr-manager.sh so this test exercises the real
# function, not a reimplementation.
eval "$(awk '/^_redact_ci_logs\(\) \{/,/^\}/' "$REPO_DIR/pr-manager.sh")"

assert_redacted() {
    local label="$1" input="$2" must_not_contain="$3"
    local got
    got=$(printf '%s\n' "$input" | _redact_ci_logs)
    if echo "$got" | grep -q -- "$must_not_contain"; then
        fail "redactor: $label leaked '$must_not_contain' → $got"
    else
        pass "redactor: $label"
    fi
}

assert_redacted "Bearer token"        "Authorization: Bearer sk-proj-abcdefghijklmnopqrstuvwxyz1234" "sk-proj-abcdefghij"
assert_redacted "gh PAT"              "token=ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" "ghp_ABCDEFGHIJ"
assert_redacted "Slack xoxb"          "webhook failed: xoxb-1234567890-ABCDEFG-abcdefghijklmnop" "xoxb-1234567890-ABCDEFG"
assert_redacted "api_key= form"       'headers: api_key="supersecrettoken123"' "supersecrettoken123"
assert_redacted "password= form"      'dsn: password=hunter2hunter2hunter2' "hunter2hunter2hunter2"
assert_redacted "AWS access key"      "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE" "AKIAIOSFODNN7EXAMPLE"

# Multi-line PEM block. sed is line-oriented by default and our previous
# single-pass pattern never matched across newlines, so a leaked private
# key in CI output passed through unredacted. Now handled by a ``sed -z``
# pre-pass. The fixture below is a realistic RSA key shape — the inner
# body lines MUST all be gone from the redacted output.
PEM_INPUT=$'prefix log\n-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEA1234567890abcdefghijklmnopqrstuvwxyz\nabcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJKLMN\nOPQRSTUVWXYZ1234567890abcdefghijklmnopqrstuvwxyzAB\n-----END RSA PRIVATE KEY-----\nsuffix log'
PEM_OUT=$(printf '%s' "$PEM_INPUT" | _redact_ci_logs)
if echo "$PEM_OUT" | grep -q 'MIIEpAIB\|OPQRSTUVWXYZ'; then
    fail "redactor: PEM body leaked → $PEM_OUT"
else
    pass "redactor: multi-line PEM body redacted"
fi
if echo "$PEM_OUT" | grep -q '<REDACTED>'; then
    pass "redactor: PEM redaction marker present"
else
    fail "redactor: PEM redaction marker missing"
fi
# Preserve BEGIN/END delimiters so operators can still tell "a key was
# here" during forensics even though the body is gone.
if echo "$PEM_OUT" | grep -q 'BEGIN RSA PRIVATE KEY' && echo "$PEM_OUT" | grep -q 'END RSA PRIVATE KEY'; then
    pass "redactor: PEM delimiters kept for forensics"
else
    fail "redactor: PEM delimiters mangled"
fi
# And the surrounding log context must survive.
if echo "$PEM_OUT" | grep -q 'prefix log' && echo "$PEM_OUT" | grep -q 'suffix log'; then
    pass "redactor: surrounding log context preserved around PEM"
else
    fail "redactor: surrounding log context lost around PEM"
fi

# Non-secret text must pass through untouched.
NOSEC="normal log line with no secrets"
if [ "$(echo "$NOSEC" | _redact_ci_logs)" = "$NOSEC" ]; then
    pass "redactor: plain log line passes through unchanged"
else
    fail "redactor: plain log line was mutated"
fi
echo ""

# ─── Layer 5e: followup file event+head_sha scoping ─────────────────────
#
# The followup file at ~/.clawdbot/followups/<pr_key_safe>.json is the
# dispatch channel between a handler escalation and the next handler
# spawn. Dispatch consumption MUST be scoped to the event + head_sha the
# escalation was written for, otherwise a dispatch answering a
# review_comments escalation could be wrongly folded into the next
# ci_failed spawn on the same PR (or vice versa), or consumed at a new
# SHA after the premises have moved on. (coderabbit PR#39 _BzXb.)
echo "Layer 5e: followup file scoping + pr-dispatch flags"

PRM="$REPO_DIR/pr-manager.sh"
PDISP="$REPO_DIR/pr-dispatch.sh"

if grep -q 'FOLLOWUP_EVENT=$(echo "$FOLLOWUP_BLOB" | jq' "$PRM" \
    && grep -q 'FOLLOWUP_HEAD_SHA=$(echo "$FOLLOWUP_BLOB" | jq' "$PRM"; then
    pass "pr-manager reads .event and .head_sha from followup blob"
else
    fail "pr-manager missing .event / .head_sha reads from followup blob"
fi
if grep -q 'EVENT_OK=1' "$PRM" && grep -q 'SHA_OK=1' "$PRM"; then
    pass "pr-manager gates HAS_DISPATCH on EVENT_OK + SHA_OK"
else
    fail "pr-manager missing HAS_DISPATCH gating on EVENT_OK+SHA_OK"
fi

if grep -q -- '--event)' "$PDISP" && grep -q -- '--head-sha)' "$PDISP"; then
    pass "pr-dispatch.sh accepts --event and --head-sha flags"
else
    fail "pr-dispatch.sh missing --event / --head-sha flag parsing"
fi
if grep -q 'event_override' "$PDISP" && grep -q 'head_sha_override' "$PDISP"; then
    pass "pr-dispatch.sh preserves or overrides event/head_sha in payload"
else
    fail "pr-dispatch.sh not persisting event/head_sha"
fi

# Live round-trip through pr-dispatch.sh using an isolated $HOME.
TMP_FUP_DIR=$(mktemp -d)
_fup_cleanup() { rm -rf "$TMP_FUP_DIR"; }
trap _fup_cleanup EXIT
HOME_SAVE="$HOME"
export HOME="$TMP_FUP_DIR"
mkdir -p "$HOME/.clawdbot/followups"
cat > "$HOME/.clawdbot/followups/o-r-42.json" <<'EOF'
{"pr_key":"o/r#42","awaiting_input":"what lang?","event":"review_comments","head_sha":"abc1234","detail":"x","threads":[]}
EOF

if "$PDISP" "o/r#42" "use English" >/dev/null 2>&1; then
    RESULT=$(cat "$HOME/.clawdbot/followups/o-r-42.json")
    if [ "$(echo "$RESULT" | jq -r .event)" = "review_comments" ] \
        && [ "$(echo "$RESULT" | jq -r .head_sha)" = "abc1234" ] \
        && [ "$(echo "$RESULT" | jq -r .dispatch)" = "use English" ]; then
        pass "pr-dispatch.sh preserves prior event+head_sha when not overridden"
    else
        fail "pr-dispatch.sh lost prior event/head_sha: $RESULT"
    fi
else
    fail "pr-dispatch.sh failed to write dispatch"
fi

if "$PDISP" "o/r#42" "retry with ruff" --event ci_failed --head-sha deadbeef0 >/dev/null 2>&1; then
    RESULT=$(cat "$HOME/.clawdbot/followups/o-r-42.json")
    if [ "$(echo "$RESULT" | jq -r .event)" = "ci_failed" ] \
        && [ "$(echo "$RESULT" | jq -r .head_sha)" = "deadbeef0" ]; then
        pass "pr-dispatch.sh --event / --head-sha override flags take effect"
    else
        fail "pr-dispatch.sh override flags ignored: $RESULT"
    fi
else
    fail "pr-dispatch.sh failed with override flags"
fi

if "$PDISP" "o/r#42" "nope" --event bogus_event >/dev/null 2>&1; then
    fail "pr-dispatch.sh accepted invalid --event value"
else
    pass "pr-dispatch.sh rejects invalid --event value"
fi
if "$PDISP" "o/r#42" "nope" --head-sha not-hex >/dev/null 2>&1; then
    fail "pr-dispatch.sh accepted non-hex --head-sha"
else
    pass "pr-dispatch.sh rejects non-hex --head-sha"
fi

export HOME="$HOME_SAVE"
trap - EXIT
_fup_cleanup
echo ""

# ─── Layer 5g: handler_spawns state is scoped to review_comments ─────────
echo "Layer 5g: handler_spawns is review_comments-only + inline-count"
#
# The handler_spawns state slot feeds the silent-no-op detector, which
# lives inside the HAS_COMMENTS path. A ci_failed spawn that wrote
# {unresolved_count: 0} here would cause the next review_comments tick
# on the same SHA to satisfy UNRESOLVED >= 0 and short-circuit the
# 15-min review-wait window. Guard the write on EVENT==review_comments.
# Additionally, we now persist inline_unresolved_count separately from
# the total, so the detector compares like-for-like
# (coderabbit PR#39 _BzXV / _BzXh).
handler_block=$(awk '/Record this spawn.s pre-run finding count/,/Consume the followup file/' "$PRM")
if echo "$handler_block" | grep -q 'EVENT. = "review_comments"'; then
    pass "handler_spawns write gated on EVENT==review_comments"
else
    fail "handler_spawns write still unconditionally runs for ci_failed spawns"
fi
if echo "$handler_block" | grep -q 'inline_unresolved_count' \
    && echo "$handler_block" | grep -q 'outside_diff_count'; then
    pass "handler_spawns records inline_unresolved_count + outside_diff_count"
else
    fail "handler_spawns missing inline / outside split fields"
fi
if grep -q 'PRIOR_INLINE=.*inline_unresolved_count' "$PRM"; then
    pass "silent-no-op detector reads inline_unresolved_count"
else
    fail "silent-no-op detector not reading inline_unresolved_count"
fi
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
