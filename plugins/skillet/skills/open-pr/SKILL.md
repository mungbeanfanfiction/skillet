---
name: open-pr
description: Open a draft pull request on GitHub. Discovers and uses the repo's PR template, fills the overview from the linked issue (if any) or from the conversation context plus git log, and creates the PR in DRAFT mode. Use when ready to open a PR for the current branch.
argument-hint: "[issue-or-ticket-number] [--noninteractive]"
---

# Open Draft PR Skill

Open a draft PR for the current branch, using the repo's PR template and the most relevant context available (linked issue → conversation → git log).

The PR is **always** created in draft mode.

## When Invoked

Optional argument: an issue/ticket number to link explicitly. If omitted, the skill tries to infer one from the branch name or commits.

## Non-interactive mode

When invoked with a `--noninteractive` flag (e.g. by another skill or the autonomous queue),
**skip the confirmation prompts** and proceed: do not ask before opening the PR
(open it directly with the prepared title/body), and if there are uncommitted
changes, proceed with only the committed work rather than asking. The PR is still
always created as a **draft**. In non-interactive mode the skill must never block
on input.

## Workflow

### 0. Verbosity gate (run before anything else)

Before opening the PR, run the `check-verbosity` skill against the current
branch to catch verbosity that should be trimmed first — redundant comments,
leftover debug logs, dead scaffolding, and wordy prose. It is report-only here;
it never opens, pushes, or commits.

- **Interactive:** run it, show the findings, and ask whether to trim before
  continuing (offer to apply its safe fixes by re-running `check-verbosity` with
  its `--fix` argument, or to proceed as-is). It is a gate, not a hard block —
  the user may proceed.
- **Non-interactive:** run it once and include its summary in the output, but do
  **not** block on it and do **not** auto-apply `--fix` (no silent rewrites in
  an unattended flow). Continue to step 1.

If `check-verbosity` reports clean (or the skill is unavailable), continue
silently.

### 0a. Formatting gate (Prettier)

Before opening the PR, make sure the branch's changed files are Prettier-clean
so the PR doesn't land a formatting-only CI failure. Unlike the verbosity gate,
this one **auto-applies** in both interactive and non-interactive mode —
running Prettier is deterministic and safe, so there's no judgment call to gate
on.

**Detect whether the repo uses Prettier.** Check, in order:

```bash
# Prettier as a dependency (root package.json; adjust path if the branch's
# changes live under a subpackage with its own package.json)
node -e "const p=require('./package.json'); process.exit((p.dependencies&&p.dependencies.prettier)||(p.devDependencies&&p.devDependencies.prettier)?0:1)" 2>/dev/null

# Or a Prettier config file at the repo root
ls .prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml .prettierrc.js \
   .prettierrc.cjs .prettierrc.mjs prettier.config.js prettier.config.cjs \
   prettier.config.mjs 2>/dev/null
```

If neither a dependency nor a config file is found, **skip this gate silently**
— do not mention it, do not run Prettier. Continue to step 1.

**Scope to the branch's changed files.** Diff against the same base branch
used elsewhere in this skill (resolve it the same way step 2 does, or reuse the
value if already computed):

```bash
BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
CHANGED_FILES=$(git diff --name-only --diff-filter=ACMR "origin/$BASE"...HEAD)
```

Only files that still exist in the working tree and match extensions Prettier
handles (`.js .jsx .ts .tsx .json .css .scss .md .yml .yaml` etc. — whatever
the repo's own Prettier config/ignore rules cover) are in scope. Don't
second-guess the repo's ignore rules; let Prettier/the format script apply
them.

**Check formatting.** Prefer the repo's own script over a bare binary, so
repo-specific config and ignore rules are respected:

- If `package.json` has a `scripts.format:check` (or similarly-named check
  script), run it scoped to the changed files if the script accepts a file-list
  argument; otherwise run it as-is and treat any failure as "needs formatting"
  only if it actually flags files in `$CHANGED_FILES` (a repo-wide check script
  may legitimately fail on pre-existing unrelated files — don't treat those as
  this branch's problem).
- Otherwise run Prettier directly, scoped to the changed files:

  ```bash
  npx prettier --check $CHANGED_FILES
  ```

If the check passes (exit 0, or no changed files overlap with reported
violations), the gate is a no-op — continue silently to step 1.

**Fix and commit if violations are found.** Prefer the repo's own write script:

- If `package.json` has a `scripts.format` script, run `npm run format` (it
  typically covers the whole repo, which is fine — Prettier only rewrites files
  that are actually misformatted, so this stays a no-op for files outside the
  branch's changes).
- Otherwise run Prettier directly, scoped to the changed files:

  ```bash
  npx prettier --write $CHANGED_FILES
  ```

Then stage and commit only the files this branch actually touches (avoid
sweeping in unrelated repo-wide reformatting if a repo-level `format` script
touched more than `$CHANGED_FILES`):

```bash
git add -- $CHANGED_FILES
git commit -m "style: apply prettier formatting"
```

If, after running the write step, nothing is actually staged (the "violations"
were all outside `$CHANGED_FILES`), skip the commit.

- **Interactive:** auto-apply as above, then surface a one-line summary of what
  was reformatted (e.g. `Prettier formatted 3 files (src/a.ts, src/b.ts,
  src/c.tsx) — committed as "style: apply prettier formatting"`).
- **Non-interactive:** apply and commit the same way, silently, and include the
  summary in the output log alongside the verbosity-gate summary. Do not block.

If Prettier itself errors (e.g. a syntax error in a changed file it can't
parse), report the error and continue — do not hard-block PR creation on a
Prettier failure; surface it so the user/CI catches it downstream.

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

### 2a. Enforce the 400-line PR size limit

PRs over ~400 changed lines are hard to review and hide bugs. Before pushing or
opening anything, count the lines this branch changes vs the base branch and
**hard-block** if the total exceeds **400**.

"Lines changed" = added + deleted lines (the same metric GitHub shows as a PR's
size), summed across all non-excluded files. Sum the last two columns of
`git diff --numstat` against the **merge base** (`...`, so changes that landed on
base after this branch forked don't inflate the count), skipping binary files
(which report `-`). Exclude generated/lockfiles that legitimately balloon a diff
but aren't hand-reviewed — this is the authoritative count, and it matches the
`oversize_diff` flag the `issue-supervisor` survey computes the same way:

```bash
CHANGED=$(git diff --numstat origin/$BASE...HEAD \
  -- . ':(exclude)**/*.lock' ':(exclude)**/*.freezed.dart' ':(exclude)**/*.g.dart' \
  | awk '$1 != "-" && $2 != "-" { sum += $1 + $2 } END { print sum + 0 }')
echo "$CHANGED lines changed vs origin/$BASE"
```

(Drop the `:(exclude)...` pathspecs if you want the raw, all-files count, but
compare the **excluded** number against the 400 limit so a regenerated lockfile
or `*.g.dart` doesn't block an otherwise-small PR.)

If `CHANGED > 400`, **stop — do not push, do not open a PR.** Tell the user (or,
in non-interactive mode, write the reason to the session's progress log and exit
cleanly) that the change is too large and must be split. Give concrete split
guidance:

- Identify logical chunks from `git diff --stat origin/$BASE..HEAD` — group by
  directory, feature, or layer (e.g. data model vs API vs UI; refactor vs new
  behavior).
- Land each chunk as its own branch + PR, smallest/most-foundational first, so
  later PRs stack on merged work.
- Pure mechanical churn (renames, formatting, generated files) belongs in its own
  PR separate from behavioral changes, so reviewers can skim it.
- If the work genuinely cannot be decomposed (e.g. one large generated file or an
  atomic migration), say so explicitly and let the user decide to override —
  never silently open an oversized PR.

This limit is intentionally hard: do not open the PR and then warn. Block first.

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
  - Do not rely on this section alone to close the issue — step 6a appends a
    guaranteed closing-keyword line outside this freeform text, so the Overview
    prose can mention the issue naturally without needing to carry the closing
    keyword itself.
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

### 6a. Guarantee the closing keyword

**Only if an issue was found in step 5.** This step is independent of the
Overview text produced in step 6 — it exists precisely so a reworded,
trimmed, or missing Overview can never cause the closing keyword to
disappear.

Append a dedicated line to the very end of the filled body, on its own line
outside any freeform prose or template section:

```
Closes #<n>
```

Do this unconditionally whenever an issue was found, even if step 6 already
wrote a `Closes #<n>` / `Fixes #<n>` line inside the Overview — a duplicate
closing keyword is harmless to GitHub, but a missing one silently breaks
auto-close on merge. Do not phrase this line any other way (no "Relates to",
no "See issue") and do not let `check-verbosity` (step 0) or any later
trimming remove it — it is not part of the freeform content those checks
target.

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

### 10. Update the linked issue

**Only if an issue was linked in step 5.** If no issue was found, skip this step
silently.

Post a comment on that issue announcing the draft PR. The wording must say the
draft PR was **created** — never "opened" or "ready for review", because the PR
is always a draft at this point.

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
BODY_FILE=$(mktemp)
printf '🔧 Draft PR created: %s\n' "<pr-url>" > "$BODY_FILE"
gh issue comment <num> --repo "$REPO" --body-file "$BODY_FILE"
rm "$BODY_FILE"
```

Post this **automatically** — do not ask the user first. They already confirmed
opening the PR in step 8, and a comment is non-destructive. (In non-interactive
mode this is unchanged — it already posts without prompting.)

Report both the PR URL and the issue-comment URL to the user.

> For a standalone issue update outside the PR flow (mid-work status, blocked,
> etc.), use the `/update-issue` skill.

### 11. Do not

- Do not mark the PR ready-for-review — always `--draft`.
- Do not add reviewers, labels, milestones, or assignees automatically. The user does that.
- Do not push with `--force` for any reason.
- Do not invent test results, screenshots, or claims of "tested locally".
- Do not delete or skip sections of the template — preserve structure, fill what you can, leave the rest as `TODO`.
