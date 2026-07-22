---
name: create-epic
description: Create a GitHub epic from the conversation context — an epic issue plus its child issues, all filed under a new GitHub Project. Fully autonomous, no confirmation prompt. Use when asked to file/create/plan an epic, a project, or a set of related issues that should be tracked together.
argument-hint: "[topic or hint]"
---

# Create Epic Skill

Create a GitHub epic from the current conversation context, fully
autonomously (no confirmation gate): one parent epic issue, N child issues,
and a new GitHub Project that tracks all of them together.

## When Invoked

Optional argument: a short topic/hint. If omitted, synthesize the epic from
the conversation so far.

## Canonical labels

The label taxonomy is defined in the shared data file, relative to this
plugin's skills root:

```
../_shared/labels.json
```

Read it before labeling. It already includes `epic` (parent issue — not
directly dispatched) and `loop-generated` (auto-created sub-issue), alongside
the queue/type/area/priority dimensions documented in `create-issue`'s SKILL.md.

## Workflow

### 1. Preflight

```bash
gh auth status                                            # must succeed
gh repo view --json nameWithOwner --jq '.nameWithOwner'   # resolves target repo
```

If `gh` is not authenticated or no repo is detectable, stop and tell the
user — don't guess a repo.

The `project` scope is required to create and populate a Project. Check for
it and self-heal:

```bash
gh auth status 2>&1 | grep -q "'project'" || gh auth refresh -s project
```

If `gh auth refresh` fails (e.g. non-interactive session with no way to
complete the browser flow), stop and tell the user to run
`gh auth refresh -s project` themselves.

### 2. Draft the epic breakdown

From the conversation (and the argument hint), derive:

- **Epic title:** short, imperative, describing the overall outcome (e.g.
  "Support multi-region deploys"). Under ~70 chars.
- **Epic body:** structured Markdown:

  ```markdown
  ## Context

  <why this matters / where it came from>

  ## Goal

  <the overall outcome this epic delivers>

  ## Child issues

  <a checklist, filled in after child issues are created in step 4 — placeholder for now>
  ```

- **Child issues:** break the epic into concrete, independently-shippable
  issues. Each gets its own title + body using the same Context / What needs
  to happen / Acceptance criteria structure as `create-issue`. Do **not**
  invent scope the conversation doesn't support — if the breakdown is
  genuinely unclear, create fewer, larger child issues rather than padding
  the count.

### 3. Infer labels

Same rules as `create-issue` (queue/type/area/priority), applied
per-issue:

- **Epic issue:** always `auto` + `epic`. No type/area/priority — it's a
  tracking parent, not dispatched work.
- **Child issues:** `auto` + `loop-generated` + inferred type/area/priority,
  exactly as `create-issue` step 3 does.

### 4. Ensure the needed labels exist

Fetch the repo's existing labels once, same as `create-issue` step 4:

```bash
gh label list --limit 200 --json name --jq '.[].name'
```

Create any missing labels from `labels.json` (name/color/description). Do
**not** recolor or edit labels that already exist.

### 5. Create the GitHub Project

```bash
gh project create --owner "<owner>" --title "<epic title>" --format json --jq '.number'
```

`<owner>` is the org or user from `nameWithOwner` in step 1. Capture the
returned project number — needed to link the repo and add items.

Link the project to the repo (so it shows up in the repo's Projects tab):

```bash
gh project link <project-number> --owner "<owner>" --repo "<repo>"
```

### 6. Create the epic issue

```bash
BODY_FILE=$(mktemp)
# write the drafted epic body to $BODY_FILE (with placeholder child checklist)
gh issue create --title "<epic title>" --body-file "$BODY_FILE" \
  --label "auto" --label "epic"
rm "$BODY_FILE"
```

Capture the epic issue number and URL.

### 7. Create each child issue

For each child issue drafted in step 2:

```bash
BODY_FILE=$(mktemp)
# write the child body to $BODY_FILE, including a back-reference line:
#   "Part of epic #<epic-number>"
gh issue create --title "<child title>" --body-file "$BODY_FILE" \
  --label "auto" --label "loop-generated" --label "<type>" \
  [--label "<area>" ...] --label "<priority>"
rm "$BODY_FILE"
```

Capture each child issue number and URL as it's created.

### 8. Add every issue to the project

Add the epic and all child issues to the project created in step 5:

```bash
gh project item-add <project-number> --owner "<owner>" --url "<issue-url>"
```

Repeat for the epic issue and each child issue.

### 9. Back-fill the epic's child checklist

Edit the epic issue body to replace the placeholder checklist with real
links to the child issues:

```markdown
## Child issues

- [ ] #<child-1>
- [ ] #<child-2>
```

```bash
gh issue edit <epic-number> --body-file "$BODY_FILE"
```

### 10. Return a summary

Return to the user: the epic issue URL, the project URL
(`gh project view <project-number> --owner "<owner>" --format json --jq '.url'`),
and a list of the child issue URLs.

## Do not

- Do not ask for confirmation — this skill is fully autonomous.
- Do not recolor or edit labels that already exist.
- Do not set assignees.
- Do not create a worktree or branch — this skill only files issues and the
  project.
- Do not invent child issues or acceptance criteria the conversation doesn't
  support.
