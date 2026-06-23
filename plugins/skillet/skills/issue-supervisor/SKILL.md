---
name: issue-supervisor
description: Supervise auto-labeled GitHub issues (or a markdown checklist) across git worktrees — survey ground truth, restart stalled background sessions, dispatch new work to fill 3 slots, groom the backlog. Repo-agnostic; reuses review-fix. Use when running the ~5h supervisor loop.
argument-hint: "[--label <name> | --file <path>]"
---

# issue-supervisor

The heavy ~5h loop. Repo-agnostic: it derives the repo and base branch from the
current git context. Run order each cycle. Concurrency lock first.

## 0. Lock
Acquire `<repo>/.claude/issue-supervisor/supervisor.lock` (create the file; if it
exists and is <6h old, exit — another cycle is running). Remove it at the end.

## 1. Bootstrap (first run only)
Seed the canonical label taxonomy with the `/sync-repo-labels` skill (it creates
`auto`, `explore`, type/area/priority labels in the current repo, additive and
drift-fixing). Then create the three supervisor-internal lifecycle labels that are
NOT part of the canonical set:
`gh label create epic --description "decomposed parent — not directly dispatched" --color 5319E7`,
`gh label create loop-generated --description "auto-created sub-issue" --color BFD4F2`,
`gh label create needs-input --description "session parked on a design question" --color D93F0B`
(each `|| true` if it already exists). Then present open issues and apply `auto`
only to the ones the user approves. Do NOT bulk-label.

## 2. Survey
Run `scripts/survey.sh`. If it returns `{"error": ...}`, report the error and STOP
this cycle (reschedule). Never act on partial data.

## 3. Act on owned worktrees (from survey JSON)
- `stalled` → run `scripts/restart.sh <path> <issue>`.
- `needs-input` → leave alone (the sweeper owns it; never restart).
- `pr-open` → leave to the human.
- `blocked` → report with reason; do not touch.
- `working` → leave alone.
NEVER touch worktrees with `"owned": false` — report them if stalled, nothing more.

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
needs-input count, foreign-stalled FYI, slots filled, backlog groomed. For the
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
report-only. The per-issue review step uses the `review-fix` skill.
