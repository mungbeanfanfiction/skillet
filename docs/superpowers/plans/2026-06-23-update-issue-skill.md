# update-issue Skill + open-pr Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a standalone `/update-issue` skill that posts a status comment to a GitHub issue, and make `/open-pr` automatically comment on the linked issue when a draft PR is created.

**Architecture:** Two SKILL.md documents in the skillet plugin. `update-issue` is a new single-purpose skill (resolve issue → compose comment → confirm → `gh issue comment`). `open-pr` gets one new step that inlines the same `gh issue comment` mechanism (it does **not** call `/update-issue` — skillet skills point users to slash commands, they don't invoke each other). Both describe a `--noninteractive` mode so the autonomous queue never blocks.

**Tech Stack:** Markdown SKILL.md files (YAML frontmatter + prose), `gh` CLI, bash snippets. No application code, no test runner — these are skill specifications executed by an agent.

## Global Constraints

- Skill files live at `plugins/skillet/skills/<name>/SKILL.md`; skills are auto-discovered (no manifest edit needed).
- Frontmatter requires `name`, `description`, and (for argument-taking skills) `argument-hint`, matching the format of sibling skills (`open-pr`, `create-issue`).
- **Wording:** the draft-PR case must say a draft PR was **"created"** — never "opened" or "ready for review".
- **Non-destructive:** `update-issue` posts a comment only — never changes labels, milestones, assignees, or issue state, and never closes an issue.
- **Honesty:** never invent test results, screenshots, or "tested locally" claims in any composed comment (matches `open-pr`'s existing "Do not" rule).
- **`--noninteractive` convention:** matches `open-pr` — when the flag is passed, skip every confirmation prompt and proceed with the documented default; the skill must never block on input.
- **Commits:** skillet's commit hook rejects the `Co-Authored-By: Claude` trailer — do **not** add it.
- Use `gh ... --body-file <tmpfile>` (then `rm`) for any multi-line body, to preserve newlines/quoting — same pattern `open-pr` uses for the PR body.

---

### Task 1: Create the `update-issue` skill

**Files:**
- Create: `plugins/skillet/skills/update-issue/SKILL.md`

**Interfaces:**
- Consumes: nothing (standalone skill).
- Produces: the documented `/update-issue [issue-number] [status message] [--noninteractive]` contract and the reusable "post a comment to an issue" `gh` recipe that Task 2 mirrors. Title: `Update Issue Skill`.

- [ ] **Step 1: Write the SKILL.md file**

Create `plugins/skillet/skills/update-issue/SKILL.md` with exactly this content:

````markdown
---
name: update-issue
description: Post a status update comment to a GitHub issue. Resolves the issue from an explicit number or infers it from the branch/commits, composes a concise status comment (or uses one you pass in), and posts it with the gh CLI. Comment-only and non-destructive — never changes labels, state, or assignees. Use to leave a status update, link a PR, or note progress on an issue.
argument-hint: "[issue-number] [status message] [--noninteractive]"
---

# Update Issue Skill

Post a status comment to a GitHub issue. This is comment-only: it never changes
labels, milestones, assignees, or issue state, and never closes an issue.

## When Invoked

Parse the arguments:

- **Issue number** — the first bare integer argument, if present.
- **Status message** — the remaining free text, if present.
- **`--noninteractive`** — if present, skip the confirmation prompt (see below).

Both the issue number and the status message are optional and inferred when
omitted.

## Non-interactive mode

When invoked with `--noninteractive` (e.g. by another skill or the autonomous
queue), **skip the confirmation prompt** in step 4 and post directly. The skill
must never block on input in this mode. A status message must be resolvable
(passed in or inferable) — if the target issue cannot be resolved, do not post;
report the problem and stop.

## Workflow

### 1. Resolve the repo

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
```

### 2. Resolve the issue number

In priority order:

1. The explicit issue-number argument, if provided.
2. The current branch name, matching any of: `^(\d+)-`, `issue-(\d+)`, `/(\d+)-`, `#(\d+)`.
3. Recent commit messages on the branch:

   ```bash
   BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
   git log "origin/$BASE..HEAD" --pretty=%B | grep -oiE '(closes|fixes|resolves)[[:space:]]+#[0-9]+'
   ```

If no issue number can be resolved, stop and tell the user — there is nothing to
comment on.

### 3. Validate the issue

```bash
gh issue view <num> --repo "$REPO" --json number,title,url,state
```

If the issue does not exist, surface the error and stop. If its `state` is
`CLOSED`, tell the user and ask whether to comment anyway (in non-interactive
mode, skip the comment on a closed issue and report that it was skipped).

### 4. Compose and confirm the comment

Build the comment body:

- If a status message was passed in, use it verbatim.
- Otherwise synthesize a short status line from the conversation context plus
  recent git log (`git log "origin/$BASE..HEAD" --pretty='- %s'`). Keep it to a
  sentence or two. **Never** invent test results, screenshots, or "tested
  locally" claims.

Show the user the target issue (number + title) and the proposed comment body,
then ask: **"Post this comment to issue #<num>? (y/n, or paste edits)"**

If the user pastes edits, apply them and re-confirm. (In non-interactive mode,
skip this prompt and post directly.)

### 5. Post the comment

Write the body to a temp file to preserve newlines and quoting, then post:

```bash
BODY_FILE=$(mktemp)
# write body to $BODY_FILE
gh issue comment <num> --repo "$REPO" --body-file "$BODY_FILE"
rm "$BODY_FILE"
```

Return the comment URL (printed by `gh issue comment`) to the user.

## Do not

- Do not change labels, milestones, assignees, or issue state.
- Do not close the issue.
- Do not edit the issue body — only add a comment.
- Do not invent test results, screenshots, or claims of "tested locally".
````

- [ ] **Step 2: Verify the frontmatter and structure**

Run:

```bash
cd plugins/skillet/skills/update-issue
head -5 SKILL.md
grep -nE '^(name|description|argument-hint):' SKILL.md | head
grep -c '^## ' SKILL.md
```

Expected: the first line is `---`; `name: update-issue`, a `description:` line, and an `argument-hint:` line are all present; at least the `When Invoked`, `Non-interactive mode`, `Workflow`, and `Do not` H2 sections exist (`grep -c '^## '` ≥ 4).

- [ ] **Step 3: Verify the issue-number regexes match real branch names**

Run (sanity-checks the four documented patterns against representative branch names):

```bash
for b in "42-add-thing" "issue-17-fix" "feature/99-do-it" "wip-#7-thing" "no-number-here"; do
  printf '%s -> ' "$b"
  echo "$b" | grep -oE '^([0-9]+)-|issue-([0-9]+)|/([0-9]+)-|#([0-9]+)' | grep -oE '[0-9]+' | head -1 || echo "(none)"
done
```

Expected: `42`, `17`, `99`, `7`, then `(none)` for the last. If any case is wrong, fix the regex list in the SKILL.md to match the same patterns `open-pr` uses.

- [ ] **Step 4: Commit**

```bash
git add plugins/skillet/skills/update-issue/SKILL.md
git commit -m "feat(skillet): add update-issue skill"
```

---

### Task 2: Integrate automatic issue update into `open-pr`

**Files:**
- Modify: `plugins/skillet/skills/open-pr/SKILL.md` (renumber current step 10 → 11; insert new step 10; add note pointing at `/update-issue`)

**Interfaces:**
- Consumes: the linked-issue resolution already done in `open-pr` step 5, the PR URL produced by step 9, and the `gh issue comment ... --body-file` recipe documented in Task 1.
- Produces: nothing downstream (terminal change).

- [ ] **Step 1: Insert the new "Update the linked issue" step after step 9**

In `plugins/skillet/skills/open-pr/SKILL.md`, the current step 9 ends with:

```
gh pr create --draft --title "<title>" --body-file "$BODY_FILE" --base "$BASE"
rm "$BODY_FILE"
```

Return the PR URL to the user.

Immediately **after** the `Return the PR URL to the user.` line and **before** the `### 10. Do not` heading, insert:

````markdown
### 10. Update the linked issue

**Only if an issue was linked in step 5.** If no issue was found, skip this step
silently.

Post a comment on that issue announcing the draft PR. The wording must say the
draft PR was **created** — never "opened" or "ready for review", because the PR
is always a draft at this point.

```bash
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
````

- [ ] **Step 2: Renumber the old step 10 to step 11**

Change the heading `### 10. Do not` to `### 11. Do not`. Its body is unchanged:

```markdown
### 11. Do not

- Do not mark the PR ready-for-review — always `--draft`.
- Do not add reviewers, labels, milestones, or assignees automatically. The user does that.
- Do not push with `--force` for any reason.
- Do not invent test results, screenshots, or claims of "tested locally".
- Do not delete or skip sections of the template — preserve structure, fill what you can, leave the rest as `TODO`.
```

- [ ] **Step 3: Verify the edit applied correctly**

Run:

```bash
cd plugins/skillet/skills/open-pr
grep -nE '^### (9|10|11)\.' SKILL.md
grep -n 'Draft PR created' SKILL.md
grep -n '/update-issue' SKILL.md
```

Expected: headings appear in order `### 9. Create the PR`, `### 10. Update the linked issue`, `### 11. Do not` (no duplicate `### 10.`); exactly one `Draft PR created` line; one `/update-issue` reference. If `### 10. Do not` still appears, the renumber in Step 2 was missed — fix it.

- [ ] **Step 4: Confirm `REPO` is available where the new snippet uses it**

The new step 10 snippet references `$REPO`. Confirm `open-pr` resolves it, or make the snippet self-contained.

Run:

```bash
grep -n 'gh repo view --json nameWithOwner' SKILL.md || echo "REPO-NOT-RESOLVED"
```

Expected: a match (then `$REPO` is in scope). If it prints `REPO-NOT-RESOLVED`, prepend this line inside the step 10 bash block, before the `BODY_FILE` line:

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
```

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/open-pr/SKILL.md
git commit -m "feat(skillet): open-pr comments on linked issue when draft PR is created"
```

---

### Task 3: Update the design spec with the non-interactive addendum

**Files:**
- Modify: `docs/superpowers/specs/2026-06-23-update-issue-skill-design.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing — documentation alignment only.

The spec was written before the `--noninteractive` mode of the real `open-pr` was discovered. Record it so the spec matches what was built.

- [ ] **Step 1: Add a non-interactive note to the spec**

In `docs/superpowers/specs/2026-06-23-update-issue-skill-design.md`, under the
`### 1. New skill: update-issue` section, after the `**Does not:**` paragraph,
add:

```markdown
**Non-interactive mode:** mirrors `open-pr` — a `--noninteractive` flag skips the
confirm gate and posts directly; the skill never blocks on input. On a closed or
unresolvable issue in this mode, it skips and reports rather than prompting.
```

And in the `### 2. open-pr integration` section, append a bullet:

```markdown
- In `open-pr`'s existing non-interactive mode, the new step is unchanged — it
  already posts the comment without prompting.
```

- [ ] **Step 2: Verify and commit**

Run:

```bash
grep -n 'Non-interactive mode' docs/superpowers/specs/2026-06-23-update-issue-skill-design.md
git add docs/superpowers/specs/2026-06-23-update-issue-skill-design.md
git commit -m "docs: note non-interactive mode in update-issue spec"
```

Expected: the grep matches the new heading.

---

## Notes on verification

These are skill specification documents, not executable code, so there is no
unit-test suite. Verification per task is: (1) the file exists with valid
frontmatter and the documented sections, (2) the embedded `gh`/regex snippets are
checked against representative inputs where feasible (Task 1 Step 3), and (3) the
`open-pr` edit produces correctly-ordered, non-duplicated step headings. A final
end-to-end check (run `/open-pr` against a real linked issue and confirm the
comment lands) is left to the user, since it mutates a live GitHub issue.
