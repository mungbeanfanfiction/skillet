# Design: Issue Supervisor v2 — unified autonomous queue

**Date:** 2026-06-23
**Status:** Approved (design); pending implementation plan
**Repo:** skillet (personal Claude Code skill marketplace)

## Problem

skillet has a designed-and-built but unmerged `drain-queue` skill (branch
`feat/drain-queue`): a one-shot, in-session, never-ask queue drainer. Separately,
a more advanced supervisor was built in another repo — a recurring, crash-resilient
loop with stalled-session restart, a human-in-the-loop design-question escape hatch,
and autonomous decomposition of oversized issues. The two overlap ~60% (label →
worktree → verify → draft PR → review-fix → cap 3 → run-report) but diverge on
execution model and philosophy.

Running both would create two competing queue systems in a personal plugin. This
design **folds the advanced supervisor into drain-queue's successor** as a single
unified system: `issue-supervisor` (the recurring loop) + `question-sweeper` (the
design-question lifecycle). drain-queue is retired/absorbed; `review-fix` is kept
and reused as a building block.

## What changes vs. the original autonomous-queue design

| Dimension | drain-queue (v1) | issue-supervisor (v2) |
|---|---|---|
| Execution | one session, in-session subagents | **detached background `claude` + recurring `/loop`** |
| Lifetime | one drain pass, then stop | **runs indefinitely on a cadence** |
| Crash/limit recovery | none (dies with session) | **restart stalled sessions from disk** |
| Design questions | never ask (best-guess-or-skip) | **best-guess by default, escalate to `needs-input` on genuine design questions** |
| Oversized issues | not handled | **autonomous decomposition into ≤6 sub-issues** |
| State | none | **ground-truth-every-cycle + a worktree registry** |
| Implementation | prose `SKILL.md` | **tested `supervisorlib` Python package + thin shell glue + prose `SKILL.md`** |
| Queue source | label OR markdown checklist | **label OR markdown checklist (both kept)** |
| Review | `review-fix` | **`review-fix`** (kept) |
| Repo/CI | `gh repo view` + detect `make ci`/`npm test`/`pytest` | **same — repo-agnostic** |

## Architecture

Two skills under `plugins/skillet/skills/`, plus a shared tested Python package:

```
plugins/skillet/skills/issue-supervisor/
  SKILL.md                       # ~5h loop procedure (model judgment)
  lib/supervisorlib/             # tested, stdlib-only deterministic logic
    registry.py  gitstatus.py  state.py  slots.py  gh.py
    survey.py  spawn.py  questions.py  queue_source.py  runreport.py
    (+ tests/, pytest.ini)   # task.md handled inline in dispatch.sh (no taskmd.py);
                             # runtime-state paths owned by scripts/common.sh (no paths.py)
  scripts/                       # thin injection-safe bash glue
    survey.sh  dispatch.sh  restart.sh  resume.sh
plugins/skillet/skills/question-sweeper/
  SKILL.md                       # ~1h sweep procedure
  scripts/sweep.sh
docs/superpowers/questions/<issue#>.md   # queued design questions (runtime)
docs/superpowers/runs/YYYY-MM-DD-*.md     # run-reports (from drain-queue heritage)
```

**Layering (unchanged from the proven build):** deterministic logic
(registry I/O, state classification, slot accounting, eligibility filtering,
restart-count parsing, answer detection, queue parsing) lives in
`supervisorlib` with plain-pytest unit tests. Shell scripts are thin glue that
shell out to the package and to `gh`/`git`/`claude`. Model judgment (triage,
decomposition, review-loop, question authoring) lives in `SKILL.md`. The only
persisted state is a worktree registry JSON; the filesystem and GitHub are the
source of truth (ground-truth every cycle).

## Repo-agnostic (the key port change)

The proven build hard-coded one repo and CI command. v2 derives everything from
the **current git context**, matching skillet's existing convention
(`cleanup-worktrees` already does this):

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
```

- **Repo slug** → `REPO` (no hard-coded `owner/name`).
- **Base branch** → `BASE` (no hard-coded `main`).
- **CI command** → detect in order: `make ci`, then `npm test` / `npm run test`,
  then `pytest`, then a check documented in the repo's CLAUDE.md/README; if none,
  record "no check command found" and proceed (drain-queue's rule).
- **Labels** (`auto`, `epic`, `loop-generated`, `needs-input`) created in the
  current repo at bootstrap if missing.

## The two loops

### issue-supervisor (~5h, `/loop issue-supervisor`)

Each cycle (lock → survey → act → refill → report → reschedule):

1. **Lock** `scripts/.lock` (skip if a fresh lock exists).
2. **Bootstrap (first run):** create the four labels if missing; for label
   queues, present open issues and apply `auto` only to user-approved ones.
3. **Survey** (`scripts/survey.sh` → JSON `{worktrees, free_slots, eligible_issues}`).
   On error, STOP the cycle (never act on partial data).
4. **Act on owned worktrees** by state: `stalled` → `restart.sh`; `needs-input`
   → leave (sweeper owns it, never restart); `pr-open`/`blocked` → leave/report;
   `working` → leave. **Foreign (un-owned) worktrees are report-only — never
   touched.**
5. **Refill slots** (cap 3, in-flight = `working`+`stalled` only): take the next
   queue item and run the **dispatch-time triage gate** — atomic → dispatch
   (`dispatch.sh`); too-big → autonomously decompose into ≤6 `auto`+`loop-generated`
   sub-issues, re-label parent `epic` (remove `auto`).
6. **Report + reschedule** ~5h. Also append/update a run-report under
   `docs/superpowers/runs/` (drain-queue heritage).

Each dispatched session runs the per-issue pipeline (pickup → triage → work →
review via **`review-fix`** → CI (repo-detected) → draft PR) and opens its own
draft PR. The supervisor never opens or merges PRs.

### question-sweeper (~1h, `/loop question-sweeper`)

Manages the design-question lifecycle only; never dispatches fresh work or
restarts mechanical stalls.

1. **Sweep** (`scripts/sweep.sh` → `{raised, answered}`).
2. **Newly raised:** copy `question.md` → `docs/superpowers/questions/<issue#>.md`
   (with an empty `## Answer`), label the issue `needs-input`, post the question as
   a GitHub comment. The worktree's slot is now free (`needs-input` ∉ in-flight).
3. **Answered** (inbox file is source of truth): if a slot is free, inject the
   answer into `task.md`, delete `question.md`, remove the `needs-input` label, and
   **`resume.sh`** (NOT `restart.sh` — resuming an answered question must not burn
   the restart budget). Else leave answered-and-queued.
4. **Report + reschedule** ~1h.

## Design-question philosophy (the reconciliation)

Per-task, the worker:
- **Best-guess by default** (drain-queue's stance) — for minor ambiguity, make a
  documented best guess and note the assumption in the PR/commit. Do not stall.
- **Escalate to `needs-input`** when the question is genuinely **design-related or
  unsafe to guess** (API shape, product behavior, irreversible choice, ambiguous
  acceptance criteria). Write `question.md` and exit; the sweeper routes it to the
  human. This is the real stall — reserved for decisions only the user can make.
- **Skip-and-log** only when there is no safe guess AND it is not a design question
  worth a human (e.g. blocked on missing external info).

A separate skill (skillet#6, "write well-scoped GitHub issues") reduces how often
tasks hit design questions in the first place — prevention complementing this
handling.

## Queue sources (both kept)

- `--label <name>` → `gh issue list --label` in the current repo. Full machinery:
  assignment, decomposition, `needs-input` GitHub comments.
- `--file <path>` → parse unchecked `- [ ]` items as tasks. These skip the
  GitHub-issue-specific steps (no assignment/decomposition/issue-comment); a
  raised question for a file task is recorded in the run-report and inbox rather
  than posted as an issue comment.

## Safety rails (unchanged, enforced in code where consequential)

- No merge, no push to base; draft PRs only (opened inside sessions).
- Never `git restore`/`checkout`/`clean`/`reset`.
- Foreign worktrees never modified (registry boundary); `restart.sh`/`resume.sh`
  assert ownership + restart cap before spawning (defense-in-depth, not just prose).
- `needs-input` never restarted; restart cap = 2.
- Autonomous issue creation bounded: ≤6 per split, `epic` idempotency,
  `loop-generated` provenance.
- Atomic registry writes; survey fails closed (`{"error":...}` → STOP).

## Reuse of existing skillet skills

- **`review-fix`** — the per-issue pipeline calls it for the review/auto-fix loop
  (replaces direct `/code-review` calls in the original build).
- **`create-worktree`** patterns / **`open-pr`** — align with skillet's existing
  worktree + PR skills where practical (the supervisor's `dispatch.sh` may call
  `open-pr` heritage rather than a bespoke PR step).

## Migration / porting notes

- Source of truth for the engine: the proven build (tested `supervisorlib` + four
  scripts + two SKILL.md), ported into skillet's `plugins/skillet/skills/` layout.
- De-hard-code: replace the baked repo slug and `main`/`make agent-ci` with the
  repo-agnostic detection above.
- Rewire the review step from `/code-review` to **`review-fix`**.
- Add `queue_source.py` (markdown-checklist parser) + thread `--file` through.
- Add the run-report writer (`docs/superpowers/runs/`).
- Retire/abandon `feat/drain-queue`; preserve its README/issue history by noting
  the supersession in the v2 PR.
- Known deployment note: detached sessions need permission to write the worktree's
  `.claude/` (task.md/question.md) — document in the skill README.

## Integration with sibling skillet skills (added 2026-06-23, post-rebase)

After rebasing onto skillet `main` (v0.8.0), three sibling skills exist and are
wired in:

- **`explore-issue` routing.** An issue labeled `explore` is an investigation, not
  an implementation. `dispatch.sh` writes the issue's labels into `task.md` as a
  `**Labels:**` line; the per-issue pipeline (`spawn.PIPELINE`) gains a step-0
  routing preamble: if `task.md` is labeled `explore`, run the `explore-issue`
  skill (it produces its own findings spec → draft PR → issue comment), mark
  `done`, and STOP — skip the implement pipeline. `explore` issues are still
  fully *eligible* (not filtered); only the in-session behavior differs. The
  supervisor's triage gate never decomposes an `explore` issue (exploration is one
  focused investigation). `gh.is_explore(issue)` is the pure predicate. This
  fulfills the "pending queue routing" contract documented in `explore-issue`'s
  SKILL.md.
- **`/sync-repo-labels` at bootstrap.** Instead of hand-creating `auto`, bootstrap
  calls `/sync-repo-labels` to seed the canonical taxonomy (which already includes
  `auto` and `explore`), then creates only the three supervisor-internal lifecycle
  labels not in that set: `epic`, `loop-generated`, `needs-input`.
- **`worktree-status` report enrichment.** The cycle report (step 5) invokes
  `worktree-status` for the human-readable narrative + staleness, especially for
  the foreign-worktree FYI. This is **additive only** — the automated
  classification that drives restart/dispatch stays ground-truth based
  (`survey.sh`); the supervisor never couples control decisions to the
  hook-written `STATUS.md`.

## Out of scope (YAGNI)

- Workflow-script (crash-resume via `Workflow()`) reimplementation — a possible v3.
- Non-GitHub, non-markdown queue sources (Linear, etc.).
- `ultra` cloud review inside the loop (billed, user-triggered).
- Auto-answering design questions or auto-merging PRs (always human-gated).

## Open questions

None. Design approved; proceed to implementation plan.
