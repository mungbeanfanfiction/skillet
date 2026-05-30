---
name: drain-queue
description: Work a queue of tasks autonomously — from a GitHub label or a markdown checklist — dispatching capped-parallel subagents that each create a worktree, do the work, run the repo's own checks, open a draft PR, and auto-improve it via review-fix. Never asks the human anything; writes a run-report at the end. Use to leave the machine and return to finished, improved work.
argument-hint: "--label <label> | --file <path> [--cap N]"
---

# Drain-Queue Skill

Drain a queue of tasks with no human input required. Each task is worked in
isolation, verified, turned into a draft PR, and auto-improved via the
`review-fix` skill. When done, write a run-report so the user can triage on
return.

## When Invoked

Parse the arguments:

- **Queue source (exactly one required):**
  - `--label <label>` → list GitHub issues carrying that label.
  - `--file <path>` → parse unchecked (`- [ ]`) items from a markdown file as
    tasks.
- `--cap N` → maximum concurrent tasks. Default **3**.

If neither queue source is given, stop and ask which to use (this is setup, not
mid-run — asking here is fine).

## Workflow

### 1. Gather the queue

For a label:
```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
gh issue list --repo "$REPO" --label "<label>" --state open \
  --json number,title,url
```

For a file: read it and extract every line matching `- [ ]` as a task (keep the
text after the checkbox as the task description).

Build an ordered task list. If the queue is empty, report that and stop.

### 2. Dispatch subagents, capped at N concurrent

Use the **superpowers:dispatching-parallel-agents** skill to run up to `--cap`
tasks at once. Give every subagent this exact charter:

> You are working ONE task autonomously. You must NEVER ask the human anything.
>
> 1. Create an isolated worktree for this task using the `create-worktree`
>    skill (pass the issue number, or a derived branch name for file tasks).
> 2. Do the work for the task in that worktree.
> 3. Verify using the repo's OWN check command. Detect it in this order and run
>    the first that exists: `make ci`, then `npm test` / `npm run test`, then
>    `pytest`, then any check documented in the repo's CLAUDE.md/README. If none
>    exists, note "no check command found" in your result. Only proceed to the
>    PR if the check passes (or there is none).
> 4. Open a **draft PR** using the `open-pr` skill (pass the issue number if
>    this task came from an issue).
> 5. Run the `review-fix` skill on that PR to auto-improve it.
> 6. On genuine ambiguity (missing info, unclear spec): attempt a **documented
>    best guess** and note the assumption in the PR body. If no safe guess is
>    possible, **skip the task** — do not open a PR — and explain why.
> 7. Return a STRUCTURED result with these fields: `task` (id/title),
>    `status` (`done` | `skipped`), `pr_url` (if done), `review_summary` (from
>    review-fix), `skip_reason` (if skipped), `flagged_for_human` (any unsafe
>    findings review-fix left as PR comments).

### 3. Never stall

The pipeline must never idle waiting for the user. This is guaranteed by three
things, all already in the charter above:

1. **Isolation** — each task in its own worktree, so parallel tasks never block
   on shared state or merge conflicts.
2. **No-questions rule** — the subagent best-guesses-and-documents or
   skips-and-logs; it never asks.
3. **Unambiguous done** — verification uses the repo's existing check command.

### 4. Loop until drained

Continue dispatching until every task in the queue has a result, respecting the
concurrency cap.

### 5. Write the run-report

Write `docs/superpowers/runs/YYYY-MM-DD-drain-queue.md` (create the directory if
needed). Use today's date. Include three sections:

- **Shipped** — for each `done` task: title → PR link → one-line review summary.
- **Skipped** — for each `skipped` task: title → reason.
- **Needs your attention** — every `flagged_for_human` item across all tasks
  (the unsafe findings review-fix posted as PR comments).

Then output the report path and a one-line tally (e.g. "7 shipped, 2 skipped,
3 flagged").
