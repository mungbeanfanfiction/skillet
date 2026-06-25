---
name: issue-supervisor
description: Supervise auto-labeled GitHub issues (or a markdown checklist) across git worktrees — survey ground truth, restart stalled background sessions, dispatch new work to fill 3 slots, groom the backlog. Repo-agnostic. Use when running the ~5h supervisor loop.
argument-hint: "[--label <name> | --file <path>]"
---

# issue-supervisor

The heavy ~5h loop. Repo-agnostic: it derives the repo and base branch from the
current git context. Run order each cycle. Concurrency lock first.

## 0. Lock
Acquire the lock with `scripts/lock.sh acquire` (prints `acquired` or `busy`). It
creates `<repo>/.claude/issue-supervisor/supervisor.lock`; if a fresh lock exists
(<6h old) it prints `busy` — another cycle or an event-driven refill is running,
so exit. Release it at the end with `scripts/lock.sh release`. The same helper
guards the event-driven refill (see "Completion-notification path") so the two
can never run concurrently.

## 1. Bootstrap (first run only)
Seed the canonical label taxonomy with the `/sync-repo-labels` skill. It reads
`_shared/labels.json` (the single source of truth for names, colors, and
descriptions) and creates/drift-fixes every label in the current repo, additive
and non-destructive. This includes the supervisor's lifecycle labels — `epic`,
`loop-generated`, and `needs-input` — which now live in `labels.json` alongside
`auto`, `explore`, and the type/area/priority set. Do NOT create these labels
inline with hardcoded hex colors; `/sync-repo-labels` owns them. Then present
open issues and apply `auto` only to the ones the user approves. Do NOT
bulk-label.

## 2. Survey
Run `scripts/survey.sh`. If it returns `{"error": ...}`, report the error and STOP
this cycle (reschedule). Never act on partial data.

## 3. Act on owned worktrees (from survey JSON)
- `stalled` → run `scripts/restart.sh <path> <issue>`.
- `needs-input` → leave alone (the sweeper owns it; never restart).
- `pr-open` → leave to the human.
- `blocked` → report with its `blocked_reason`; do not touch. The reason tells you
  what happened: `task_md_missing` (registry points at a worktree whose task.md is
  gone — likely registry/disk drift, worth investigating), `restart_cap` (hit the
  restart budget — a real repeated failure for a human), `done_no_pr` (session
  marked done but never opened a PR — needs a human).
- `working` → leave alone.
NEVER touch worktrees with `"owned": false` (state `foreign`) — list them in the
report's FYI, nothing more.

## 4. Refill slots
While `free_slots > 0` and the queue is non-empty, take the next item:
- **Label queue:** lowest `eligible_issues` number. Fetch the body
  (`gh issue view <n>`), judge scope.
- **File queue (`--file`):** next unchecked `- [ ]` item.
Run the **dispatch-time triage gate**:
- **Explore** (issue labeled `explore`) → dispatch normally, passing the labels so
  the session routes itself to the `explore-issue` skill (no scope decomposition —
  exploration is inherently one focused investigation):
  `scripts/dispatch.sh <id> "<title>" <slug> label "<comma-separated-labels>"`.
- **Atomic** (one focused PR) → `scripts/dispatch.sh <id> "<title>" <slug> <source> "<labels>"`.
  Pass the issue's labels as the 5th arg (comma-separated, e.g. `auto,bug`) so the
  session's pipeline can route on them; omit for file-source tasks.
- **Too big** (label source only, NOT explore) → decompose autonomously: create ≤6
  sub-issues with `gh issue create ... --label auto --label loop-generated` and body
  `part of #<n>`; then re-label the parent `epic` and remove `auto`. Do NOT
  dispatch the parent. (Idempotent: epics are filtered out by survey.)

## 5. Report + reschedule
Print: in-flight (issue→state), restarted, PRs open, blocked w/ reason,
needs-input count, foreign-worktree FYI, slots filled, backlog groomed. For the
human-readable narrative — especially the foreign-worktree FYI and staleness —
run the `worktree-status` skill and fold its output into the report (it reads each
worktree's `STATUS.md` + live git state). The automated classification above stays
ground-truth based (`survey.sh`); `worktree-status` only enriches the report, it
does not drive restart/dispatch decisions. Append a run-report under
`docs/superpowers/runs/` (use `supervisorlib.runreport`). Also clear any pending
completion sentinels — this cycle already surveyed ground truth, so they are
subsumed: `python3 -c "import sys; sys.path.insert(0,'lib'); from supervisorlib
import signals; signals.clear('<repo>/.claude/issue-supervisor')"` (or just delete
`<repo>/.claude/issue-supervisor/signals/`). Release the lock with
`scripts/lock.sh release`. The /loop reschedules ~5h.

## Completion-notification path (event-driven refill)
The ~5h cycle is the backstop, but a session that finishes mid-cycle leaves its
slot idle until the next poll. To refill promptly:
- **Signal:** every dispatched session calls `scripts/notify-completion.sh` as its
  last step (wired into the session pipeline in `spawn.PIPELINE`). That drops a
  sentinel under `<repo>/.claude/issue-supervisor/signals/` naming the freed
  worktree. It is best-effort and ownership-checked — a foreign worktree finishing
  signals nothing.
- **Consume:** run a lightweight refill loop alongside the heavy one —
  `/loop <short-interval> issue-supervisor --refill-signals` (or invoke the path
  below on a fast cadence). Each tick runs `scripts/refill-signals.sh`:
  - It exits early with `{"skipped":"no_signals"}` when nothing is pending.
  - It acquires `supervisor.lock` via `lock.sh`; if a cycle holds it, it prints
    `{"skipped":"busy"}` and exits — the running cycle is the backstop, nothing to
    do.
  - On success it clears the consumed sentinels, leaves the **lock held**, and
    prints the survey JSON (with `pending_signals`/`signals_seen`). Run **only
    §4 (Refill slots)** on that survey — the same scope-triage/dispatch gate — then
    **always** release the lock with `scripts/lock.sh release`. Skip §3
    (act-on-worktrees) and decomposition narration; this is a focused refill, not a
    full cycle.
- **Recovery (important):** the refill path hands a HELD lock across a process
  boundary, so if this session dies or is interrupted between acquire and release,
  the lock is left behind. `lock.sh` recovers it automatically once it ages past 6h
  (`LOCK_TTL_HOURS`); to clear a stuck lock sooner, run `scripts/lock.sh release`.
  Always release after a manual or interrupted refill.
- **Safety:** the refill decision is driven solely by the survey's `free_slots`, so
  a stale or spurious sentinel costs at most one survey, never a wrong dispatch.
  `lock.sh` uses an atomic `mkdir` lock with a serialized (atomic-`mkdir` marker)
  stale reclaim, so two acquirers can never both win; because both paths share it,
  an event-driven refill can never race the scheduled cycle.

## Hard rules
No merge, no push to the base branch, only DRAFT PRs (those happen inside
sessions). Never git restore/checkout/clean/reset. Foreign worktrees are
report-only. The per-issue review step dispatches the
`pr-review-toolkit:code-reviewer` subagent (a headless session can't invoke the
`/code-review` slash command), applies its high/medium findings, cap 3 rounds.
