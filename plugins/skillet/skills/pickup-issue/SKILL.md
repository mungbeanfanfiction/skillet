---
name: pickup-issue
description: Pick up one or more GitHub issues right now — create an isolated worktree per issue (via /create-worktree), implement the change, and leave it ready for /open-pr. The lightweight, single-shot cousin of /issue-supervisor for manually working a specific issue or your assigned backlog. Use when asked to "pick up issue #N", "work on my assigned issues", or similar.
argument-hint: "[issue-number...] [--noninteractive]"
model: sonnet
---

# Pickup Issue Skill

Implement one or more GitHub issues, each in its own worktree, right now — no
supervisor loop, no polling. This is a simple numbered workflow: resolve
issues → for each, create a worktree → implement → report/hand off.

## When Invoked

Parse the arguments:

- One or more issue numbers given → use them directly.
- None given → infer "issues assigned to me":

  ```bash
  REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
  gh issue list --repo "$REPO" --assignee @me --label auto --json number,title
  ```

  If that returns nothing, tell the user there's nothing assigned and stop.

- `--noninteractive` → skip confirmations throughout (see below).

If multiple issues are found/given, confirm the list with the user before
starting (unless `--noninteractive`): "Picking up #12, #34, #56 — proceed?"

## Workflow (per issue)

Run these steps for **each** issue in turn — one worktree and one
implementation per issue, never interleaved or shared between issues.

### 1. Create the worktree

Delegate entirely to `/create-worktree` — do not reimplement branch naming,
worktree placement, or dotfile symlinking here:

```
/create-worktree <issue-number> --noninteractive
```

This derives the branch name from the issue title, places the worktree at
`.claude/worktrees/<branch-name>`, symlinks untracked dotfiles from the main
repo, and branches off latest `origin/<default-branch>`. If it fails, skip
this issue, report the failure, and continue to the next one.

### 2. Implement the issue

All work from here happens inside the new worktree.

- Fetch the full issue (title, body, comments, labels) if not already in
  context: `gh issue view <number> --repo "$REPO" --json title,body,labels,comments,url`.
- Read the issue body as the spec. If it links a design doc or references
  other files/issues, follow those too.
- Look at the surrounding code the issue points to and infer this repo's
  existing conventions — test framework, style, file layout — from what's
  already there rather than guessing generically.
- Implement the change following this repo's normal TDD/verification
  practice: write/adjust tests first where the repo does that, make the
  change, then run the repo's actual verification (test suite, typecheck,
  lint — whatever `package.json`/`Makefile`/CI config shows) before treating
  it as done.
- Keep the change scoped to the issue. If it's clearly too large for one PR
  (see `open-pr`'s 400-line guidance), say so in the report rather than
  quietly ballooning the diff.
- Commit with a message following this repo's convention (check recent `git
  log`), e.g. `type(scope): <n> - <description>`, and include `Closes #<n>`
  in the body. Never add a `Co-Authored-By` trailer (repo rule).

### 3. Hand off

Do not open the PR yourself. Once the implementation is committed and
verified:

- **Interactive:** tell the user the worktree is ready and ask whether to run
  `/open-pr <number> --noninteractive` now, or leave it for them to review
  first.
- **`--noninteractive`:** invoke `/open-pr <number> --noninteractive`
  directly so the issue lands as a draft PR without waiting on input.

Either way, report the worktree path and (once opened) the PR URL.

## Multiple issues

Process issues one at a time, fully finishing (or explicitly skipping) one
before starting the next — each gets its own worktree and its own commit
history; nothing is shared or batched across issues. After all issues are
processed, print a short summary:

```
#12 — done, worktree .claude/worktrees/<branch>, PR <url or "not opened">
#34 — skipped, worktree creation failed: <reason>
#56 — done, worktree .claude/worktrees/<branch>, PR <url or "not opened">
```

## Non-interactive mode

With `--noninteractive`, never block on a prompt: skip the issue-list
confirmation, pass `--noninteractive` through to `/create-worktree` and
`/open-pr`, and open the PR automatically once verification passes instead of
asking.

## Notes

- This is not `/issue-supervisor` — no polling, no restart budget, no
  concurrency slots. It runs the requested issues once and stops.
- Never commit to `main`/`master` — always inside the worktree's branch.
- Never add a `Co-Authored-By` trailer to commits (repo rule).
- To clean up a worktree once its PR merges, use `/delete-worktree` or
  `/cleanup-worktrees`.
