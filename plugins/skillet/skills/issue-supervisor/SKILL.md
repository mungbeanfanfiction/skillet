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
- `pr-open` → leave the merge/review decision to the human, but watch it for
  follow-up work in step 3a.
- `blocked` → report with its `blocked_reason`; do not touch. The reason tells you
  what happened: `task_md_missing` (registry points at a worktree whose task.md is
  gone — likely registry/disk drift, worth investigating), `restart_cap` (hit the
  restart budget — a real repeated failure for a human), `done_no_pr` (session
  marked done but never opened a PR — needs a human).
- `working` → leave alone.
NEVER touch worktrees with `"owned": false` (state `foreign`) — list them in the
report's FYI, nothing more.

**Oversize-diff flag.** The survey marks any owned, pre-PR worktree whose diff has
grown past the 400-line cap (added + deleted vs base, lockfiles/generated files
excluded) with `"oversize_diff": true` and a `diff_changed_lines` count. `open-pr`
hard-blocks PRs over 400 lines, so flag these before they get there: surface them
in the step-5 report (e.g. `oversize: #56 (612 lines) — needs split`) and let the
session split the work into smaller, logically focused PRs. Do NOT restart or
otherwise touch the worktree on this flag alone — it is advisory and independent
of the state classification; a `working` session may already be planning the
split (every dispatch carries the ≤400-line constraint, see step 4).

## 3a. Watch open PRs (comments + conflicts)
Run `scripts/pr-watch.sh`. For every OWNED worktree whose branch has an open PR,
it checks two signals and, when either fires, dispatches a follow-up session
**into that PR's existing worktree** (the branch is already checked out there) —
through the same detached-`claude` mechanism as a normal dispatch, no one-off
code path:

- **New/unaddressed comments** — via the `check-pr-comments` skill (run with
  `--json` and the stored `--since` checkpoint), which covers inline review
  threads, review summaries, and top-level PR comments and excludes already
  resolved threads. The follow-up session addresses the feedback (code changes
  and/or thread replies) and pushes to the PR branch.
- **A merge conflict** — when `gh`'s `mergeStateStatus` is `DIRTY`/`BEHIND`. The
  follow-up session runs the `resolve-conflicts` skill, which conservatively
  resolves only safe conflicts and pushes, or escalates cleanly when a conflict
  needs human judgment.

**De-dup is automatic.** A per-PR checkpoint in the registry
(`pr_checkpoint.comments_since` + `pr_checkpoint.conflict_oid`) records the
handled state, so the loop never re-dispatches the same comments or the same
unchanged conflict state. A checkpoint advances only for the signal it actually
dispatched on; a fresh conflict (base or head moved) or newer comments re-trigger
on a later pass. The script **skips** any worktree with a live session or a
pending `question.md`, so it never clobbers in-flight work. A PR-watch session
does not consume one of the 3 issue slots (a `pr-open` worktree is not
in-flight); it is PR maintenance, not new issue work. Surface each acted-on PR
(number + reasons) in the step-5 report.

## 4. Refill slots
While `free_slots > 0` and the queue is non-empty, take the next item:
- **Label queue:** lowest `eligible_issues` number. Fetch the body
  (`gh issue view <n>`), judge scope.
- **File queue (`--file`):** next unchecked `- [ ]` item.
Every dispatched session's prompt carries an explicit **≤400-line-per-PR
constraint** (added by `supervisorlib.spawn`), with guidance to split larger work
into separate, logically focused PRs. You don't add this per-dispatch — it ships
in the pipeline prompt automatically.

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
Print a **tight, scannable digest** — only what changed or was acted on this
cycle. Default to a few lines, not a long-form report. Suggested shape (omit any
line that's empty/zero rather than printing "none"):
```
survey: N working, M stalled, K needs-input, J pr-open  (P foreign) · slots F/3
acted: restarted #12 #34 · dispatched #56 #78 · groomed #90→epic (+3 sub-issues)
pr-watch: #43 comment-dispatched · #45 conflict-dispatched
oversize: #56 (612 lines) — needs split
blocked: #41 restart_cap
```
Lead with the counts, then the verbs (restarted / dispatched / groomed / blocked /
pr-watch). Do NOT dump per-worktree narration, full STATUS.md text, or unchanged
"working" items into the printed output — that detail belongs in the run-report
file, not the per-iteration summary. If nothing was acted on, say so in one line.

The full detail still gets persisted: append a run-report under
`docs/superpowers/runs/` (use `supervisorlib.runreport`) capturing shipped,
skipped, and flagged items. The `worktree-status` skill (per-worktree `STATUS.md`
+ live git state) and any foreign-worktree FYI are for that run-report and for
answering follow-up questions on demand — do NOT fold their narrative into the
default printed digest. The automated classification stays ground-truth based
(`survey.sh`); `worktree-status` only enriches the persisted report, it does not
drive restart/dispatch decisions. Release the lock. The /loop reschedules ~5h.

## Hard rules
No merge, no push to the base branch, only DRAFT PRs (those happen inside
sessions). Never git restore/checkout/clean/reset. Foreign worktrees are
report-only. The per-issue review step dispatches the
`pr-review-toolkit:code-reviewer` subagent (a headless session can't invoke the
`/code-review` slash command), applies its high/medium findings, cap 3 rounds.
PR-watch (step 3a) only ever spawns into an OWNED worktree's existing branch, and
only when that worktree is idle (no live session, no pending question); its
follow-up sessions push to the PR branch but, like every other session, never
merge or push to the base branch.
