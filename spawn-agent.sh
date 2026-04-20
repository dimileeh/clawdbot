#!/usr/bin/env bash
# spawn-agent.sh — Create worktree, install deps, launch coding agent in tmux
# Usage: spawn-agent.sh <task-id> <repo-path> <branch> <agent> <model> <thinking> "<prompt>"
#
# The prompt is written to a file and piped via stdin to avoid shell escaping issues.

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

# Signal the ~/.openclaw/bin shims (claude, git) that we are inside a
# legitimate spawn flow, so they don't block `claude -p` or
# `git checkout -b agents/*`.
export SPAWN_AGENT_CONTEXT=1

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

# ── gh wrapper: enforce base branch + stamp attribution ──
# Generated at runtime into a per-task dir under ~/.clawdbot/bin/. Previous
# versions used mktemp under $TMPDIR and `trap cleanup EXIT`, but since the
# runner is nohup-launched and outlives spawn-agent.sh, the trap deleted
# the wrapper before the runner could use it — the agent fell through to
# the real /opt/homebrew/bin/gh and `--base` enforcement was lost. The
# persistent per-task dir is cleaned by cleanup-task.sh after merge.
REAL_GH_BIN="$(command -v gh || true)"
CLAWDBOT_BIN_DIR="$HOME/.clawdbot/bin/${1:-unknown}"
mkdir -p "$CLAWDBOT_BIN_DIR"
_INTEGRATION="${CLAWDBOT_INTEGRATION_BRANCH:-development}"
# MAIN_BRANCH is the trunk/long-lived branch new work branches off (via
# ``git worktree add ... origin/$MAIN_BRANCH``). Distinct from _INTEGRATION
# which is the staging branch PRs target. On Canopy, .env sets
# CLAWDBOT_MAIN_BRANCH=develop. The ``main`` default is a last-resort
# fallback — any .env setting CLAWDBOT_MAIN_BRANCH overrides. This line
# must appear BEFORE the first $MAIN_BRANCH reference below or set -u
# aborts the script with "MAIN_BRANCH: unbound variable".
MAIN_BRANCH="${CLAWDBOT_MAIN_BRANCH:-main}"
if [ -n "$REAL_GH_BIN" ]; then
  cat > "$CLAWDBOT_BIN_DIR/gh" <<'GHWRAPPER'
#!/usr/bin/env bash
set -euo pipefail

REAL_GH_BIN="${REAL_GH_BIN:?REAL_GH_BIN env var not set}"
_TARGET_BRANCH="${_CLAWDBOT_TARGET_BRANCH:?_CLAWDBOT_TARGET_BRANCH not set}"

# Enforce: NEVER allow PRs targeting main from automation.
if [ "${1-}" = "pr" ] && [ "${2-}" = "create" ]; then
  # Require explicit base.
  if ! printf '%q ' "$@" | grep -q -- "--base"; then
    echo "ERROR: gh pr create must specify --base $_TARGET_BRANCH (never default)" >&2
    exit 2
  fi

  # Reject base=main.
  if printf '%q ' "$@" | grep -q -- "--base main"; then
    echo "ERROR: gh pr create --base main is forbidden" >&2
    exit 2
  fi

  # Enforce base=$_TARGET_BRANCH.
  if ! printf '%q ' "$@" | grep -q -- "--base $_TARGET_BRANCH"; then
    echo "ERROR: gh pr create must use --base $_TARGET_BRANCH" >&2
    exit 2
  fi

  out="$($REAL_GH_BIN "$@")"
  echo "$out"

  url="$(echo "$out" | grep -Eo 'https://github.com/[^ ]+' | head -n 1 || true)"
  if [ -n "$url" ]; then
    agent="${CLAWDBOT_AGENT:-unknown}"
    task_id="${CLAWDBOT_TASK_ID:-unknown}"
    worktree="${CLAWDBOT_WORKTREE:-unknown}"

    body="$($REAL_GH_BIN pr view "$url" --json body --jq .body)"
    footer=$'\n\n---\nCreated-by: '$agent$'\nTask-id: '$task_id$'\nWorktree: '$worktree$'\n'

    # Only add footer if not already present.
    if ! echo "$body" | grep -q "^Created-by:"; then
      tmpfile="$(mktemp)"
      printf '%s%s' "$body" "$footer" > "$tmpfile"
      $REAL_GH_BIN pr edit "$url" --body-file "$tmpfile" >/dev/null
      rm -f "$tmpfile"
    fi
  fi

  exit 0
fi

exec "$REAL_GH_BIN" "$@"
GHWRAPPER
  chmod +x "$CLAWDBOT_BIN_DIR/gh"
fi


TASK_ID="${1:?Usage: spawn-agent.sh <task-id> <repo-path> <branch> <agent> <model> <thinking> <prompt>}"
REPO_PATH="${2:?Missing repo path}"
BRANCH="${3:?Missing branch name}"
AGENT="${4:?Missing agent: codex|claude|gemini}"
MODEL="${5:?Missing model}"
REQUESTED_MODEL="$MODEL"
THINKING="${6:?Missing thinking level}"
PROMPT="${7:?Missing prompt}"

REGISTRY="$HOME/.clawdbot/active-tasks.json"
# Initialize as an empty array if missing or empty. jq errors on missing
# input and leaves behind a 0-byte .tmp file; that in turn surfaces as a
# spawn-agent.sh failure Sparky interprets as "spawn didn't work" —
# prompting her to fall back to manually running the runner, resulting in
# two concurrent claude processes against the same worktree.
if [ ! -s "$REGISTRY" ]; then
  echo '[]' > "$REGISTRY"
fi
# Keep worktrees inside each repo for locality/isolation, e.g. <repo>/.worktrees/<task-id>
WORKTREE_BASE="$REPO_PATH/.worktrees"
WORKTREE_DIR="$WORKTREE_BASE/$TASK_ID"
TMUX_SESSION="agent-$TASK_ID"
LOG_DIR="$HOME/.clawdbot/logs"
PROMPT_DIR="$HOME/.clawdbot/prompts"

mkdir -p "$WORKTREE_BASE" "$LOG_DIR" "$PROMPT_DIR"

# ── Write prompt to file (global) ──
PROMPT_FILE="$PROMPT_DIR/$TASK_ID.md"
printf '%s' "$PROMPT" > "$PROMPT_FILE"

# Append completion instructions (heredoc interpolates $AGENT, $TASK_ID, $_INTEGRATION).
cat >> "$PROMPT_FILE" <<EOF

---
## When you are completely finished with the coding task above:

1. Run all tests and make sure they pass.
2. Stage all changes: \`git add -A\`
3. Commit with a conventional commit message. In the message body, add a
   \`Generated-by:\` trailer so the swarm agent that authored the work is
   attributable (the commit author itself is the maintainer, so Vercel /
   CI identity checks work). Example:

       git commit -m 'feat: <description>' -m 'Generated-by: $AGENT ($TASK_ID)'

4. Push the branch: \`git push origin HEAD\`
5. Create a PR against \`$_INTEGRATION\` (NEVER \`main\`, NEVER \`develop\`).
   A runtime \`gh\` wrapper enforces the base branch and auto-stamps an
   attribution footer in the PR body, so just run:

       gh pr create --base $_INTEGRATION --fill

   Do not add footer lines yourself; the wrapper handles it.
6. Then exit.
EOF

# ── Fetch latest & create worktree ──
cd "$REPO_PATH"
# Refresh the integration branch (where new work branches off) + the target
# branch if it already exists on origin (needed for respawns).
git fetch origin "$MAIN_BRANCH" --quiet 2>/dev/null || true
git fetch origin "$BRANCH" --quiet 2>/dev/null || true

# If the requested branch is already attached to another worktree, auto-suffix.
ORIG_BRANCH="$BRANCH"
if git worktree list --porcelain | grep -q "^branch refs/heads/$BRANCH$"; then
  i=2
  while git worktree list --porcelain | grep -q "^branch refs/heads/${ORIG_BRANCH}-r${i}$"; do
    i=$((i + 1))
  done
  BRANCH="${ORIG_BRANCH}-r${i}"
  echo "Branch '$ORIG_BRANCH' is already used by another worktree; switching to '$BRANCH'."
fi

# Cleanup stale git lockfiles from previous interrupted runs (best-effort, old locks only).
find "$REPO_PATH/.git" -type f -name "index.lock" -mmin +5 -print -delete 2>/dev/null || true

if [ -d "$WORKTREE_DIR" ]; then
  echo "Worktree $WORKTREE_DIR already exists, reusing..."
else
  # Base all new work on origin/$MAIN_BRANCH. Agents must never branch from
  # another main/trunk (CLAWDBOT_MAIN_BRANCH in .env defines the integration
  # source; on Canopy this is `develop`, on Dimitri's setup it's `main`).
  git worktree add -b "$BRANCH" "$WORKTREE_DIR" "origin/$MAIN_BRANCH" 2>/dev/null || \
    git worktree add "$WORKTREE_DIR" "$BRANCH" 2>/dev/null || \
    git worktree add "$WORKTREE_DIR" "origin/$BRANCH" 2>/dev/null || \
    { echo "Failed to create worktree"; exit 1; }
fi

# ── Inject global AGENTS.md (merge with repo-local) ──
GLOBAL_AGENTS="$HOME/.clawdbot/AGENTS.md"
if [ -f "$GLOBAL_AGENTS" ]; then
  if [ -f "$WORKTREE_DIR/AGENTS.md" ]; then
    # Append global rules to repo-local AGENTS.md (repo-specific first, then global)
    printf '\n\n---\n# Global Agent Rules\n\n' >> "$WORKTREE_DIR/AGENTS.md"
    cat "$GLOBAL_AGENTS" >> "$WORKTREE_DIR/AGENTS.md"
  else
    cp "$GLOBAL_AGENTS" "$WORKTREE_DIR/AGENTS.md"
  fi
fi

# ── Make prompt available inside worktree ──
# Gemini CLI restricts file access to the current workspace dir, so copy prompt there.
WORKTREE_PROMPT_FILE="$WORKTREE_DIR/.clawdbot_prompt.md"
cp "$PROMPT_FILE" "$WORKTREE_PROMPT_FILE"

# ── Build agent command (interactive mode, prompt file as instruction) ──
# Elvis's approach: interactive mode in tmux (not exec), enables multi-step work + mid-task steering
if [ "$AGENT" = "codex" ]; then
  # Team preference: Codex always runs as GPT-5.3 Codex with xhigh reasoning.
  # IMPORTANT: Codex CLI expects bare model name (no provider prefix) for current auth mode.
  MODEL="gpt-5.3-codex"
  THINKING="xhigh"
  AGENT_CMD="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}/codex exec -m $MODEL -c model_reasoning_effort=\"$THINKING\" --dangerously-bypass-approvals-and-sandbox \"Read and follow all instructions in .clawdbot_prompt.md\""
elif [ "$AGENT" = "claude" ]; then
  MODEL="${REQUESTED_MODEL:-${CLAWDBOT_CLAUDE_MODEL:-claude-opus-4-7}}"
  AGENT_CMD="claude --model $MODEL --dangerously-skip-permissions -p 'Read and follow all instructions in .clawdbot_prompt.md'"
elif [ "$AGENT" = "gemini" ]; then
  MODEL="${REQUESTED_MODEL:-${CLAWDBOT_GEMINI_MODEL:-gemini-2.5-pro}}"
  AGENT_CMD="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}/gemini --model $MODEL --yolo -p 'Read and follow all instructions in .clawdbot_prompt.md'"
else
  echo "Unknown agent: $AGENT (use codex, claude, or gemini)"
  exit 1
fi

# ── Install deps if needed ──
INSTALL_CMD=""
if [ -f "$WORKTREE_DIR/package.json" ]; then
  if [ -f "$WORKTREE_DIR/pnpm-lock.yaml" ]; then
    INSTALL_CMD="pnpm install --frozen-lockfile 2>/dev/null || pnpm install; "
  else
    INSTALL_CMD="npm install; "
  fi
elif [ -f "$WORKTREE_DIR/pyproject.toml" ]; then
  INSTALL_CMD="python3 -m venv .venv 2>/dev/null; source .venv/bin/activate && pip install -e '.[dev]' -q; "
fi

# ── Launch in tmux ──
# Avoid nested-quote hell by writing an explicit runner script.
RUNNER_DIR="$HOME/.clawdbot/runners"
mkdir -p "$RUNNER_DIR"
RUNNER="$RUNNER_DIR/$TASK_ID.sh"
cat > "$RUNNER" <<EOF
#!/usr/bin/env bash
set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a
# Signal the ~/.openclaw/bin shims that we're a legitimate spawn context.
export SPAWN_AGENT_CONTEXT=1
export PATH="$CLAWDBOT_BIN_DIR:${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:\$PATH"
export REAL_GH_BIN="$REAL_GH_BIN"
export _CLAWDBOT_TARGET_BRANCH="$_INTEGRATION"

# Provide attribution context to the gh wrapper
export CLAWDBOT_TASK_ID="$TASK_ID"
export CLAWDBOT_AGENT="$AGENT"
export CLAWDBOT_WORKTREE="$WORKTREE_DIR"

cd "$WORKTREE_DIR"

# Reconcile task state immediately when the agent process exits.
trap 'ec=\$?; $HOME/.clawdbot/finalize-task.sh "$TASK_ID" "$REPO_PATH" "$BRANCH" "\$ec" || true' EXIT

# Commit as Mira (matches her existing commits) so Vercel's GitHub
# integration recognizes the author and deploys previews. Agent attribution
# is preserved via (a) the branch name "agents/<task-id>", (b) the PR body
# footer added by the gh wrapper, and (c) a "Generated-by:" trailer the
# agent is instructed to add in its commit message (see prompt append).
git config user.name "lkdimitrova"
git config user.email "lyubomira.dimitrova91@gmail.com"

${INSTALL_CMD}
exec ${AGENT_CMD}
EOF
chmod +x "$RUNNER"

# ── Launch runner (nohup primary + tmux observability wrapper) ──
#
# Primary launch is `nohup … </dev/null &` + `disown`. This is bulletproof
# against parent-kill: even if OpenClaw's exec tool SIGKILLs the whole
# child-process tree when `spawn-agent.sh` exits, the nohup'd runner has
# already daemonized and survives.
#
# `tmux new-session` is attempted as a best-effort observability wrapper:
# it tails the log so `tmux attach -t agent-<task-id>` works for live
# debugging when tmux is available. If tmux fails (known to happen inside
# some OpenClaw exec contexts — the session dies instantly despite working
# in a normal terminal), we skip silently; the runner is already running
# independently and will complete.

: > "$LOG_DIR/$TASK_ID.log"   # truncate any stale log from a prior run
nohup bash "$RUNNER" >> "$LOG_DIR/$TASK_ID.log" 2>&1 </dev/null &
RUNNER_PID=$!
disown "$RUNNER_PID" 2>/dev/null || true

# Best-effort tmux observability. Never fatal.
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
fi
tmux new-session -d -s "$TMUX_SESSION" "tail -F '$LOG_DIR/$TASK_ID.log'" 2>/dev/null || true

# Verify the nohup'd runner actually started (catches the case where bash
# fails immediately — missing binary in PATH, syntax error in runner, etc.).
sleep 1
if ! kill -0 "$RUNNER_PID" 2>/dev/null; then
  # It may have finished that fast, which is fine if the log shows success.
  # Only fail when the log is empty AND process is gone — indicates startup failure.
  if [ ! -s "$LOG_DIR/$TASK_ID.log" ]; then
    echo "Runner pid $RUNNER_PID exited immediately with no output; check $LOG_DIR/$TASK_ID.log" >&2
    exit 1
  fi
fi

# ── Register task ──
REPO_NAME=$(basename "$REPO_PATH")
NOW_MS=$(($(date +%s) * 1000))
SAFE_DESC=$(echo "$PROMPT" | head -c 200 | tr -d '"\\' | tr '\n' ' ')

jq --arg id "$TASK_ID" \
   --arg tmux "$TMUX_SESSION" \
   --argjson pid "$RUNNER_PID" \
   --arg agent "$AGENT" \
   --arg model "$MODEL" \
   --arg desc "$SAFE_DESC" \
   --arg repo "$REPO_NAME" \
   --arg repoPath "$REPO_PATH" \
   --arg worktree "$WORKTREE_DIR" \
   --arg branch "$BRANCH" \
   --argjson now "$NOW_MS" \
   '. += [{id: $id, tmuxSession: $tmux, runnerPid: $pid, agent: $agent, model: $model, description: $desc, repo: $repo, repoPath: $repoPath, worktree: $worktree, branch: $branch, startedAt: $now, status: "running", respawnCount: 0, maxRespawns: 3, notifyOnComplete: true}]' \
   "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"

# ── Notify maintainer directly (infrastructure push) ──
# Bypasses Sparky entirely. Previous attempts to drive updates from Sparky's
# response text failed in different ways (watchdog-kill mid-poll, wrong
# sessions_send label, empty reply interpretation). Pushing from here is
# deterministic: every spawn that reaches this line fires exactly one
# Telegram message to the maintainer, independent of Sparky's discretion.
_NOTIFY_CHANNEL="${CLAWDBOT_NOTIFY_CHANNEL:-telegram}"
_NOTIFY_TARGET="${CLAWDBOT_NOTIFY_TARGET:-}"
if [ -n "$_NOTIFY_TARGET" ]; then
  _SPAWN_MSG=$(printf '🛫 Spawned agent \`%s\` → branch \`%s\` (%s · %s).\nRunner PID %s; pr-manager will ping when PR is ready.' \
    "$TASK_ID" "$BRANCH" "$AGENT" "$MODEL" "$RUNNER_PID")
  # Never block spawn success on this; worst case the message is just missed.
  openclaw message send \
    --channel "$_NOTIFY_CHANNEL" \
    --target "$_NOTIFY_TARGET" \
    --message "$_SPAWN_MSG" >/dev/null 2>&1 || \
    echo "⚠️ Failed to announce spawn to $_NOTIFY_CHANNEL target $_NOTIFY_TARGET; continuing" >&2
fi

echo "✅ Agent spawned:"
echo "   Task: $TASK_ID"
echo "   Branch: $BRANCH"
echo "   Worktree: $WORKTREE_DIR"
echo "   tmux: $TMUX_SESSION"
echo "   Prompt: $PROMPT_FILE"
echo "   Agent: $AGENT ($MODEL, thinking=$THINKING)"
echo ""
echo "Monitor: tmux attach -t $TMUX_SESSION"
echo "Logs: tail -f $LOG_DIR/$TASK_ID.log"
