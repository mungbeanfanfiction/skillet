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
Create any missing labels in the CURRENT repo (`REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)`):
`auto`, `epic`, `loop-generated`, `needs-input`. Then present open issues and apply
`auto` only to the ones the user approves. Do NOT bulk-label.

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
- **Atomic** (one focused PR) → `scripts/dispatch.sh <id> "<title>" <slug> <source>`.
- **Too big** (label source only) → decompose autonomously: create ≤6 sub-issues
  with `gh issue create ... --label auto --label loop-generated` and body
  `part of #<n>`; then re-label the parent `epic` and remove `auto`. Do NOT
  dispatch the parent. (Idempotent: epics are filtered out by survey.)

## 5. Report + reschedule
Print: in-flight (issue→state), restarted, PRs open, blocked w/ reason,
needs-input count, foreign-stalled FYI, slots filled, backlog groomed. Append a
run-report under `docs/superpowers/runs/` (use `supervisorlib.runreport`). Release
the lock. The /loop reschedules ~5h.

## Hard rules
No merge, no push to the base branch, only DRAFT PRs (those happen inside
sessions). Never git restore/checkout/clean/reset. Foreign worktrees are
report-only. The per-issue review step uses the `review-fix` skill.
