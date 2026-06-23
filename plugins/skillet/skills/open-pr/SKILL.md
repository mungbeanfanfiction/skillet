---
name: open-pr
description: Open a draft pull request on GitHub. Discovers and uses the repo's PR template, fills the overview from the linked issue (if any) or from the conversation context plus git log, and creates the PR in DRAFT mode. Use when ready to open a PR for the current branch.
argument-hint: "[issue-or-ticket-number] [--yes]"
---

# Open Draft PR Skill

Open a draft PR for the current branch, using the repo's PR template and the most relevant context available (linked issue → conversation → git log).

The PR is **always** created in draft mode.

## When Invoked

Optional argument: an issue/ticket number to link explicitly. If omitted, the skill tries to infer one from the branch name or commits.

## Non-interactive mode

When invoked with a `--yes` flag (e.g. by another skill or the autonomous queue),
**skip the confirmation prompts** and proceed: do not ask before opening the PR
(open it directly with the prepared title/body), and if there are uncommitted
changes, proceed with only the committed work rather than asking. The PR is still
always created as a **draft**. In non-interactive mode the skill must never block
on input.

## Workflow

### 1. Sanity checks

Run from the working tree of the branch the PR will be opened from. Verify:

```bash
git rev-parse --is-inside-work-tree   # must succeed
git symbolic-ref --short HEAD          # current branch (not main/master/HEAD)
git status --porcelain                 # warn if uncommitted changes
```

If the current branch is `main` / `master` / `trunk`, stop and tell the user — PRs aren't opened from the base branch.

If there are uncommitted changes, surface them and ask whether to proceed anyway
(the PR will only contain committed work). (In non-interactive mode, skip the
question and proceed with the committed work.)

### 2. Determine base branch

Find the repo's default branch:

```bash
gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
```

Verify the current branch is ahead of base:

```bash
BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
git rev-list --count origin/$BASE..HEAD
```

If `0`, stop — there's nothing to PR.

### 3. Push the branch if needed

```bash
git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "no-upstream"
```

If no upstream, push with `-u`:

```bash
git push -u origin HEAD
```

If upstream exists but is behind local, push (no force).

### 4. Find the PR template

Look in this order, first hit wins:

1. `.github/pull_request_template.md`
2. `.github/PULL_REQUEST_TEMPLATE.md`
3. `.github/PULL_REQUEST_TEMPLATE/*.md` (use the first one alphabetically, or ask if multiple exist)
4. `docs/pull_request_template.md`
5. `pull_request_template.md` (root)
6. `PULL_REQUEST_TEMPLATE.md` (root)

If none exists, fall back to this minimal default:

```markdown
## Overview

<!-- to be filled -->

## Test plan

- [ ] TODO
```

### 5. Find the linked issue

Try, in order:

- The explicit argument to the skill, if provided
- Branch name patterns: `^(\d+)-`, `issue-(\d+)`, `/(\d+)-`, `#(\d+)`
- Recent commit messages on the branch: `git log origin/$BASE..HEAD --pretty=%B | grep -oE '(closes|fixes|resolves)[[:space:]]+#[0-9]+'`

If an issue number is found, fetch it:

```bash
gh issue view <num> --json number,title,body,url
```

### 6. Fill the template

For each section heading in the template (lines matching `^## `), decide whether to fill it based on its name. **Do not** remove any sections from the template.

Common section conventions:

- **Overview / Summary / Description / What / Context**
  - If issue found → write a 2–4 sentence summary derived from the issue title + body. Start with what changes and why, not "this PR".
  - Else → synthesize from the conversation context (what the user and assistant discussed building/fixing) plus `git log origin/$BASE..HEAD --pretty='- %s'`.
  - Always include a `Closes #<n>` / `Fixes #<n>` line at the end of the Overview when an issue was found.
- **Test plan / Testing / How to test / Verification**
  - If the template uses checkbox syntax (`- [ ]`), preserve the checkboxes — leave them unchecked with `TODO` placeholders rather than inventing tests.
  - If freeform, write a brief bullet list of suggested manual verification steps if you can derive them from the conversation; otherwise leave as `TODO`.
- **Screenshots / Demo / Media**
  - Leave as a `TODO` placeholder. Never invent or paste images.
- **Checklist** (e.g. "I have run tests", "I have updated docs")
  - Leave all checkboxes unchecked. The user toggles these manually.
- **Breaking changes / Migration / Rollback**
  - Default to `None` unless the conversation explicitly discussed one.
- **Anything else not recognized**
  - Leave as-is, with the template's placeholder content intact.

Preserve all HTML comments in the template (`<!-- ... -->`) verbatim — many repos use them as instructions for reviewers.

### 7. Derive the PR title

Use the convention: **`type(plugin): ticket - description`**

Build each segment:

- **`type`** — a conventional-commit type inferred from the branch prefix or the latest commit subject (`feat-foo` → `feat`, `fix-bar` → `fix`, also `chore`, `docs`, `refactor`, `test`, etc.). Default to `feat` if it can't be determined.
- **`(plugin)`** — **only if** all the branch's changes fall under a single plugin directory. Detect it from the changed files:

  ```bash
  git diff --name-only origin/$BASE..HEAD | sed -n 's#^plugins/\([^/]*\)/.*#\1#p' | sort -u
  ```

  If that yields exactly one plugin name, use it as `(plugin)`. If it yields zero or more than one, **omit the parens entirely** — title becomes `type: ticket - description`.
- **`ticket`** — the linked issue/ticket number from step 5 (just the number, e.g. `42`). If no ticket was found, **drop the `ticket - ` segment** — title becomes `type(plugin): description`.
- **`description`** — a short imperative summary, sourced in priority order:
  1. The linked issue's title, lightly cleaned up (strip leading `[bug]`, `[feat]`, etc.)
  2. The most recent commit subject, if there's only one commit
  3. A summary derived from the branch name + commit subjects

Examples:

- Plugin + ticket: `feat(skillet): 42 - add worktree skill`
- Plugin, no ticket: `feat(skillet): add worktree skill`
- No plugin, ticket: `fix: 17 - correct base-branch detection`
- Neither: `docs: clarify PR template fallback`

Keep it under 70 characters. No trailing period.

### 8. Preview and confirm

Show the user, in this order:

- The detected base branch
- The detected/missing issue link
- The proposed PR title
- The proposed PR body (the filled template)

Ask: **"Open this draft PR? (y/n, or paste edits)"** (In non-interactive mode,
skip this prompt and proceed directly to step 9 to create the PR.)

If the user pastes edits, apply them and re-confirm.

### 9. Create the PR

Write the body to a temp file (to preserve newlines and quoting) and create:

```bash
BODY_FILE=$(mktemp)
# write body to $BODY_FILE
gh pr create --draft --title "<title>" --body-file "$BODY_FILE" --base "$BASE"
rm "$BODY_FILE"
```

Return the PR URL to the user.

### 10. Do not

- Do not mark the PR ready-for-review — always `--draft`.
- Do not add reviewers, labels, milestones, or assignees automatically. The user does that.
- Do not push with `--force` for any reason.
- Do not invent test results, screenshots, or claims of "tested locally".
- Do not delete or skip sections of the template — preserve structure, fill what you can, leave the rest as `TODO`.
