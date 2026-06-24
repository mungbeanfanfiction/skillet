---
name: issue-supervisor
description: Supervise auto-labeled GitHub issues (or a markdown checklist) across git worktrees — survey ground truth, restart stalled background sessions, dispatch new work to fill 3 slots, groom the backlog. Repo-agnostic. Use when running the ~5h supervisor loop.
argument-hint: "[--label <name> | --file <path>]"
---

# issue-supervisor

The heavy ~5h loop. Repo-agnostic: it derives the repo and base branch from the
current git context. Run order each cycle. Concurrency lock first.

## 0. Lock
Acquire `<repo>/.claude/issue-supervisor/supervisor.lock` (create the file; if it
exists and is <6h old, exit — another cycle is running). Remove it at the end.

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
`docs/superpowers/runs/` (use `supervisorlib.runreport`). Release the lock. The
/loop reschedules ~5h.

## Hard rules
No merge, no push to the base branch, only DRAFT PRs (those happen inside
sessions). Never git restore/checkout/clean/reset. Foreign worktrees are
report-only. The per-issue review step dispatches the
`pr-review-toolkit:code-reviewer` subagent (a headless session can't invoke the
`/code-review` slash command), applies its high/medium findings, cap 3 rounds.
