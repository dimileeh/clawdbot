---
name: pr-review-hygiene
description: "Rules for the orchestrator (the LLM driving clawdbot) when it acts on pr-manager wake events. Covers the review-reply-resolve loop, when to fix inline vs delegate to a swarm agent, when NOT to resolve a thread, and how to avoid lagging behind fresh review-bot comments. Use when: handling any `📝 pr-manager: ... unresolved review thread(s)` or `🔴 pr-manager: ... failed CI run` structured event, OR when replying to review bots on a PR you own."
metadata:
  { "openclaw": { "emoji": "🔎" } }
---

# PR Review Hygiene

`pr-manager.sh` is a pure GitHub watchdog. It classifies each PR, auto-merges the safe ones, and wakes **you** (the orchestrator) with a structured JSON envelope when a PR needs judgement. This skill is the contract for what to do after that wake.

You hold business context, memory, and the authority to decide *which* findings matter. Bash can't make those calls. Your job is to close the loop between "pr-manager saw a problem" and "the PR is clean again — reviewed, fixed, replied-to, resolved."

## The loop

```
  pr-manager wake
        ↓
  Triage (aggregate → plan → post plan to chat)
        ↓
  Act (fix inline OR delegate to swarm agent OR defer-with-reason)
        ↓
  Push
        ↓
  Verify fresh state (gh pr view + unresolved-threads check)
        ↓
  Reply to each addressed thread
        ↓
  Resolve each addressed thread
        ↓
  Done — report to the human
```

Each step below has a non-negotiable rule.

## Step 1: Triage before acting

When a `review_comments` or `ci_failed` envelope arrives:

1. **Read every comment body fully.** Review bots pack context inside collapsibles and `<details>` blocks; the one-line subject often undersells the issue.
2. **Aggregate by theme + severity.** Don't just walk the list top-to-bottom. Look for patterns (three comments about the same function, two that contradict each other).
3. **Post a short plan in chat** before you start editing. Humans get to course-correct cheap here. Format:

   ```
   PR #N — M threads.

   Fixing (k):
   - <severity> <one-line summary> — fix inline
   - <severity> <one-line summary> — delegate to swarm (reason)

   Skipping (j):
   - <severity> <one-line summary> — <reason: duplicate / already fixed / out of scope / policy call>
   ```

4. **If the human is actively chatting**, wait for their nod on the plan before executing. If they've said "just handle these going forward" / "you have my approval for routine review fixes," proceed without asking.

## Step 2: Fix inline vs. delegate to swarm

**Fix inline** when:
- ≤ ~30 lines touched across ≤ 2 files
- Surgical, well-understood change (off-by-one, missing guard, typo, dead code)
- No architectural trade-offs

**Delegate to a swarm agent** when:
- > ~30 lines OR > 2 files
- Requires fresh reasoning over a module you haven't read yet
- Touches cross-cutting concerns (auth, migrations, public APIs)
- Cursor/CodeRabbit suggested a refactor that needs its own test sweep

See the sibling `swarm` skill for the delegation workflow.

## Step 3: When NOT to resolve a thread

Resolving a thread is an assertion: *"this concern has been addressed."* Never resolve a thread you've deferred or skipped. Specifically:

- **Deferred:** reply with the reason (scope, follow-up issue, policy call) and **leave the thread open**. Human reviewers will see it and decide.
- **Disagreed:** reply with the argument, leave open, let the human moderate.
- **Already-fixed-elsewhere:** reply with the commit SHA of the prior fix, resolve.
- **Fixed in this PR:** reply with the new commit SHA, resolve.

A thread left open without a reply is worse than leaving it unresolved *with* a reply. Always leave the reasoning for your choice.

## Step 4: **THE RULE** — verify fresh state after every push

After every `git push` to a PR branch, **before** declaring the work done:

```bash
# Wait for GitHub + review bots to pick up the new SHA (≥ 30s).
sleep 30

# Check PR state.
gh pr view <N> --json headRefOid,mergeable,mergeStateStatus

# Check for unresolved threads (including freshly-added ones).
gh api graphql -f query='
{
  repository(owner:"OWNER", name:"REPO") {
    pullRequest(number: <N>) {
      reviewThreads(first:100) {
        nodes {
          id
          isResolved
          comments(first:1) { nodes { databaseId author{login} path line body } }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)'
```

If unresolved threads exist, go back to **Step 1** in the same turn. **Do not wait for the next `pr-manager` wake** — the debounce window (default 15 min) exists to let review bots converge, not to let you ignore live findings.

Pre-fix-era failure mode this rule prevents: *"I pushed c21941, Cursor posted a follow-up finding 15 seconds later, I declared the PR clean, and the human saw the unresolved thread on GitHub before pr-manager's timer fired 14 minutes later."* Don't do that.

## Step 5: Reply before resolving

Every resolved thread must have a reply from you first. The reply should include:

- The commit SHA that addressed it (not just "fixed")
- What specifically changed (one-line summary, not "addressed")
- What tests now pin it (if any were added)
- Test status (e.g., "189/189 Slack tests passing, ruff + mypy clean")

Review-bot threads get resolved via GraphQL:

```bash
gh api graphql -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { id isResolved }
    }
  }' -F threadId="<THREAD_ID>"
```

The thread ID comes from the GraphQL query in Step 4.

## Step 6: Report to the human

One summary message per wake cycle, not per commit. Include:

- PR URL + current head SHA
- Threads resolved, threads deliberately left open (with reason)
- Test numbers (`N/N passing, 0 regressions`)
- `mergeable` and `mergeStateStatus` (don't claim "awaiting merge" if state is `BLOCKED` or `UNSTABLE` without explaining why)

## Known failure modes

| Failure | How it happens | How to avoid |
|---|---|---|
| **"Pre-existing failure"** excuse | Agent blames a broken test on the base branch without evidence. Almost never true. | Assume your commit broke it. Prove otherwise with git bisect before claiming it's pre-existing. |
| **Resolving without reply** | Automation macro that resolves in bulk. | Always reply first, always with SHA + summary. |
| **Stale "done" report** | Declaring "all threads resolved" without re-checking after push. | Step 4 is non-negotiable. |
| **Fix-triggers-followup loop** | Your fix introduces a second-order bug the same bot catches on the new SHA. | Expected. Handle in the same turn via Step 4 check. |
| **Scope creep on nits** | Rewriting a module to address a trivial nit. | Nits → inline surgical fix or defer with reply. Refactors → dedicated PR. |

## Anti-patterns to reject

- ❌ "Fixed in a future commit" — either fix now or reply with reason and don't resolve
- ❌ "This is a nit, resolving" without a reply explaining the call
- ❌ Resolving bot threads with a generic "done" or "addressed"
- ❌ Declaring a PR "clean" without running Step 4
- ❌ Treating pr-manager wakes as the only signal — they're a floor, not a ceiling
- ❌ Merging dev→main PRs yourself (that's the human's call, always)

## Rules

1. **Never resolve a thread without a reply.**
2. **Never skip Step 4** (fresh-state check) after a push.
3. **Never merge main-targeted PRs** — that's the human's decision.
4. **Never claim a test failure is pre-existing** without evidence.
5. **Always include the commit SHA** in reply text so readers can verify.
6. **Always leave deferred threads open** with a written reason.
