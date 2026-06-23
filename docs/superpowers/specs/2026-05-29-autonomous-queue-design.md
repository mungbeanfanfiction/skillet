# Design: Autonomous task queue — `/drain-queue` + `/review-fix`

> **Superseded (2026-06-23):** `drain-queue` is retired and folded into
> `issue-supervisor` + `question-sweeper`. See
> `2026-06-23-issue-supervisor-v2-design.md`. `review-fix` is retained.

**Date:** 2026-05-29
**Status:** Approved (design); pending implementation plan
**Repo:** skillet (personal Claude Code skill marketplace)

## Problem

The user wants to start a long-running session, walk away, and return to a
batch of completed, improved work. The real bottleneck is not slow tasks — it
is that:

1. Individual tasks finish quickly, so no single task fills the away-time.
2. The agent stalls on permission prompts and clarifying questions, so even a
   queue of tasks would sit idle waiting for input.
3. Work returns unverified or un-polished.

The fix is to **chain many small tasks into an unattended pipeline that never
stops to ask anything, verifies itself, and even iterates on its own PRs via
code review** before the user returns.

## Solution overview

Two new skills in `plugins/skillet/skills/`, following the existing
`SKILL.md` pattern. One composes the other.

1. **`/review-fix`** — Standalone. Reviews a PR and auto-fixes high/medium
   findings without asking, looping until clean. Independently useful outside
   the queue.
2. **`/drain-queue`** — Orchestrator. Gathers a task queue, dispatches
   capped-parallel subagents to work each task end-to-end (worktree → work →
   verify → PR → `/review-fix`), loops until the queue is empty, and writes a
   run-report.

Both reuse existing skills as building blocks: `create-worktree`, `open-pr`,
the superpowers `dispatching-parallel-agents` skill, and the project's
`/code-review` command.

---

## Skill 1 — `/review-fix`

### Purpose

Given a PR, run code review and automatically apply fixes for serious findings
without requiring authorization, so that by the time the user returns the PR
has already been iterated on and improved.

### Interface

- **Argument:** a PR number. If omitted, infer the PR from the current
  branch.
- **Optional `effort`:** code-review effort level. Default `medium`
  (fewer, high-confidence findings — appropriate for unattended runs).

### Behavior — review/fix loop

Loop, maximum **3 rounds**:

1. Run `/code-review medium` (or the provided effort) against the PR's diff.
2. Partition findings by severity:
   - **High + Medium** → fix candidates.
   - **Low** → logged only, never auto-fixed.
3. For each fix candidate, judge whether it is **safe to auto-fix**:
   - **Safe** (clear, mechanical, behavior-preserving) → apply the fix to the
     working tree.
   - **Unsafe** (requires a judgment call, or could change behavior) → post
     the finding as an **inline PR comment** for the human, and record it in
     the output. Do **not** modify code for it.
4. If any fixes were applied this round → commit and push, then re-review
   (this catches issues introduced by the fixes themselves).
5. **Stop** when a round produces no new high/medium findings, or after the
   3rd round (whichever comes first).

### Output

A short summary:

- Rounds run.
- Fixes applied (with brief descriptions).
- Findings posted as PR comments for human review (the "unsafe" pile).
- Low-severity findings logged.

### Guarantees

- Never prompts for permission on the fixes it applies — that is the point.
- Nothing is silently dropped: every finding is either fixed, commented, or
  logged.

---

## Skill 2 — `/drain-queue`

### Purpose

Drain a queue of tasks autonomously: each task is worked in isolation,
verified, turned into a draft PR, and auto-improved via `/review-fix` — with
no human input required until the user returns to a run-report.

### Interface

- **Queue source (one of):**
  - A **GitHub label** (e.g. `--label ready-for-claude`) — agent lists
    matching issues.
  - A **markdown checklist file** — agent parses unchecked (`- [ ]`) items as
    tasks.
- **`--cap N`** — maximum concurrent tasks. Default **3** (parallel with a
  cap: some speed, bounded conflict risk).

### Flow

1. **Gather queue.** List matching GitHub issues, or parse unchecked items
   from the markdown file. Build an ordered task list.
2. **Dispatch, capped at N concurrent.** For each task, spawn a subagent (via
   the superpowers `dispatching-parallel-agents` skill) with a strict prompt
   that does the following, in order:
   1. Create an isolated worktree via `create-worktree` (tasks cannot collide).
   2. Do the work for the task.
   3. **Verify** using the repo's own check command — detect `make ci`,
      `npm test`, or equivalent; if none exists, note that in the result.
      Only proceed when green.
   4. Open a **draft PR** via `open-pr`.
   5. Run **`/review-fix`** on that PR.
   6. Return a **structured result**: `done` (with PR link + review summary),
      or `skipped` (with reason).
3. **Never stall.** The subagent prompt forbids asking the human anything. On
   genuine ambiguity (missing info, unclear spec): attempt a **documented best
   guess**; if no safe guess is possible, **skip the task and log why**, then
   move on.
4. **Loop** until the queue is drained, respecting the concurrency cap.
5. **Run-report.** Write `docs/superpowers/runs/YYYY-MM-DD-drain-queue.md`:
   - What shipped (task → PR link → one-line review summary).
   - What was skipped, and why.
   - What was flagged for the user's attention (the PR comments / unsafe pile
     surfaced by `/review-fix`).

### The "never stall" guarantee

Three mechanisms combine to ensure the pipeline never idles waiting for the
user:

1. **Isolation** — each task runs in its own worktree, so parallel tasks never
   block on shared state or merge conflicts.
2. **No-questions prompt** — the subagent is explicitly instructed never to ask
   the human; it must best-guess-and-document or skip-and-log.
3. **Unambiguous "done"** — verification uses the repo's existing check
   command, so there is no judgment call about whether a task is complete.

---

## Components & dependencies

| Component        | Role                                | Depends on |
|------------------|-------------------------------------|------------|
| `/review-fix`    | PR review + auto-fix loop           | `/code-review`, `gh` |
| `/drain-queue`   | Queue orchestration                 | `create-worktree`, `open-pr`, `/review-fix`, `dispatching-parallel-agents`, `gh` |

Both are prose `SKILL.md` skills (Approach A). A future v2 could reimplement
`/drain-queue` as a `Workflow()` JS script for crash-resume and structured
concurrency, and a `/schedule` cron routine for nightly unattended runs —
explicitly out of scope here.

## Out of scope (YAGNI)

- Workflow-script implementation (v2).
- Scheduled / cron execution (v2).
- Non-GitHub queue sources (Linear, etc.).
- `ultra` cloud review inside the loop (billed + user-triggered; not
  auto-launchable from a skill).

## Open questions

None. Design approved.
