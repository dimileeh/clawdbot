#!/usr/bin/env bash
# spawn-agent.sh — Create worktree, install deps, launch coding agent in tmux
# Usage: spawn-agent.sh <task-id> <repo-path> <branch> <agent> <model> <thinking> "<prompt>"
#
# The prompt is written to a file and piped via stdin to avoid shell escaping issues.

set -euo pipefail

# Load configuration
CLAWDBOT_HOME="${CLAWDBOT_HOME:-$HOME/.clawdbot}"
[ -f "$CLAWDBOT_HOME/.env" ] && set -a && source "$CLAWDBOT_HOME/.env" && set +a

export PATH="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:$PATH"

# ── gh wrapper: enforce base branch + stamp attribution ──
# Generated at runtime into a temp dir (not committed to repo).
REAL_GH_BIN="$(command -v gh || true)"
CLAWDBOT_BIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clawdbot-bin.XXXXXX")"
if [ -n "$REAL_GH_BIN" ]; then
  cat > "$CLAWDBOT_BIN_DIR/gh" <<'GHWRAPPER'
#!/usr/bin/env bash
set -euo pipefail

REAL_GH_BIN="${REAL_GH_BIN:?REAL_GH_BIN env var not set}"

# Enforce: NEVER allow PRs targeting main from automation.
if [ "${1-}" = "pr" ] && [ "${2-}" = "create" ]; then
  # Require explicit base.
  if ! printf '%q ' "$@" | grep -q -- "--base"; then
    echo "ERROR: gh pr create must specify --base development (never default)" >&2
    exit 2
  fi

  # Reject base=main.
  if printf '%q ' "$@" | grep -q -- "--base main"; then
    echo "ERROR: gh pr create --base main is forbidden" >&2
    exit 2
  fi

  # Enforce base=development.
  if ! printf '%q ' "$@" | grep -q -- "--base development"; then
    echo "ERROR: gh pr create must use --base development" >&2
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
THINKING="${6:?Missing thinking level}"
PROMPT="${7:?Missing prompt}"

REGISTRY="$HOME/.clawdbot/active-tasks.json"
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

# Append completion instructions
cat >> "$PROMPT_FILE" << 'EOF'

---
## When you are completely finished with the coding task above:

1. Run all tests and make sure they pass
2. Stage all changes: git add -A
3. Commit with a conventional commit message: git commit -m "feat: <description>"
4. Push the branch: git push origin HEAD
5. Create a PR **ONLY** against development (NEVER main):
   - gh pr create --base development --fill
6. In the PR body, include this footer (verbatim):
   - Created-by: <agent>
   - Task-id: <task-id>
   - Worktree: <path>
7. Then exit
EOF

# ── Fetch latest & create worktree ──
cd "$REPO_PATH"
# Always update development (our integration branch); also fetch the target branch if it exists on origin (needed for respawns)
git fetch origin development --quiet 2>/dev/null || true
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
  # Base all new work on origin/development. Agents must never branch from main.
  git worktree add -b "$BRANCH" "$WORKTREE_DIR" origin/development 2>/dev/null || \
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
  # Enforce Dmitri preference: Codex always runs as GPT-5.3 Codex with xhigh reasoning.
  # IMPORTANT: Codex CLI expects bare model name (no provider prefix) for current auth mode.
  MODEL="gpt-5.3-codex"
  THINKING="xhigh"
  AGENT_CMD="${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}/codex exec -m $MODEL -c model_reasoning_effort=\"$THINKING\" --dangerously-bypass-approvals-and-sandbox \"Read and follow all instructions in .clawdbot_prompt.md\""
elif [ "$AGENT" = "claude" ]; then
  MODEL="claude-opus-4-6"
  AGENT_CMD="claude --model $MODEL --dangerously-skip-permissions -p 'Read and follow all instructions in .clawdbot_prompt.md'"
elif [ "$AGENT" = "gemini" ]; then
  MODEL="gemini-3"
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
export PATH="$CLAWDBOT_BIN_DIR:${CLAWDBOT_NODE_PATH:-$HOME/.nvm/versions/node/v24.13.0/bin}:$HOME/.local/bin:\$PATH"
export REAL_GH_BIN="$REAL_GH_BIN"

# Provide attribution context to the gh wrapper
export CLAWDBOT_TASK_ID="$TASK_ID"
export CLAWDBOT_AGENT="$AGENT"
export CLAWDBOT_WORKTREE="$WORKTREE_DIR"

cd "$WORKTREE_DIR"

# Reconcile task state immediately when the agent process exits.
trap 'ec=\$?; $HOME/.clawdbot/finalize-task.sh "$TASK_ID" "$REPO_PATH" "$BRANCH" "\$ec" || true' EXIT

# Force a recognizable git identity per agent so commits are attributable.
case "$AGENT" in
  codex)  git config user.name "Aira Swarm (Codex)";  git config user.email "aira-swarm+codex@users.noreply.github.com" ;;
  claude) git config user.name "Aira Swarm (Claude)"; git config user.email "aira-swarm+claude@users.noreply.github.com" ;;
  gemini) git config user.name "Aira Swarm (Gemini)"; git config user.email "aira-swarm+gemini@users.noreply.github.com" ;;
  *)      ;;
esac

${INSTALL_CMD}
exec ${AGENT_CMD}
EOF
chmod +x "$RUNNER"

# Ensure we don't reuse a half-dead session
if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  tmux kill-session -t "$TMUX_SESSION" || true
fi

tmux new-session -d -s "$TMUX_SESSION" \
  "script -f '$LOG_DIR/$TASK_ID.log' -c 'bash \"$RUNNER\"'" || \
  { echo "Failed to create tmux session $TMUX_SESSION"; exit 1; }

# ── Register task ──
REPO_NAME=$(basename "$REPO_PATH")
NOW_MS=$(($(date +%s) * 1000))
SAFE_DESC=$(echo "$PROMPT" | head -c 200 | tr -d '"\\' | tr '\n' ' ')

jq --arg id "$TASK_ID" \
   --arg tmux "$TMUX_SESSION" \
   --arg agent "$AGENT" \
   --arg model "$MODEL" \
   --arg desc "$SAFE_DESC" \
   --arg repo "$REPO_NAME" \
   --arg repoPath "$REPO_PATH" \
   --arg worktree "$WORKTREE_DIR" \
   --arg branch "$BRANCH" \
   --argjson now "$NOW_MS" \
   '. += [{id: $id, tmuxSession: $tmux, agent: $agent, model: $model, description: $desc, repo: $repo, repoPath: $repoPath, worktree: $worktree, branch: $branch, startedAt: $now, status: "running", respawnCount: 0, maxRespawns: 3, notifyOnComplete: true}]' \
   "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"

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
