---
name: create-issue
description: Create a well-formed GitHub issue from the conversation context, auto-labeled across queue/type/area/priority. Always applies the `auto` label so an autonomous queue can pick it up, infers the rest, and auto-creates any missing labels in the repo. Fully autonomous — no confirmation prompt. Use when asked to file/open/create a GitHub issue.
argument-hint: "[topic or hint]"
---

# Create Issue Skill

Create a GitHub issue from the current conversation context, fully autonomously
(no confirmation gate). Always applies the `auto` queue label, infers
type/area/priority, and creates any missing labels in the repo before opening
the issue.

## When Invoked

Optional argument: a short topic/hint. If omitted, synthesize the issue from the
conversation so far.

## Canonical labels

The label taxonomy is defined in the shared data file, relative to this plugin's
skills root:

```
../_shared/labels.json
```

Read it before labeling. It is a JSON array of `{ name, color, description }`.
The dimensions:

- **Queue:** `auto` — always applied.
- **Type:** one of `explore`, `feature`, `bug`, `chore`, `refactor`.
- **Area:** zero or more of `frontend`, `backend`, `database`.
- **Priority:** one of `p0`, `p1`, `p2`.

## Workflow

### 1. Preflight

```bash
gh auth status                                   # must succeed
gh repo view --json nameWithOwner --jq '.nameWithOwner'   # resolves target repo
```

If `gh` is not authenticated or no repo is detectable from the working
directory, stop and tell the user — don't guess a repo.

### 2. Draft the issue

- **Title:** short, imperative (e.g. "Add dark-mode toggle to settings"). No
  trailing period. Under ~70 chars.
- **Body:** structured Markdown with these sections:

  ```markdown
  ## Context

  <why this matters / where it came from>

  ## What needs to happen

  <the concrete change>

  ## Acceptance criteria

  - [ ] <observable outcome>
  ```

  Derive everything from the conversation (and the argument hint). Do **not**
  invent acceptance criteria the conversation doesn't support — if genuinely
  unknown, leave a single `- [ ] TODO` bullet.

### 3. Infer labels

Pick labels from the canonical set (no confirmation):

- **Queue:** always include `auto`.
- **Type:** exactly one. `explore` for spikes/investigations; `bug` for
  something broken; `refactor` for restructuring with no behavior change;
  `chore` for maintenance/tooling/deps; otherwise `feature`. **Alias:** `feature`
  and `enhancement` are equivalent — once step 4 shows the repo already has an
  `enhancement` label, apply `enhancement` instead of `feature` so you don't
  seed a competing type label.
- **Area:** include each of `frontend` / `backend` / `database` the issue
  clearly touches. If it touches none (e.g. a pure docs/tooling chore), include
  no area label.
- **Priority:** exactly one. Use `p0` only for urgent/blocking; `p1` for high;
  default to `p2` when unclear — except a `bug`, which defaults to `p1`, since it
  means something is already broken. A bug the conversation clearly describes as
  minor or cosmetic may still be set to `p2`.

### 4. Ensure the needed labels exist

Fetch the repo's existing labels once:

```bash
gh label list --limit 200 --json name --jq '.[].name'
```

Note whether the repo already has an `enhancement` label — it changes the type
choice above (apply the existing `enhancement` rather than creating `feature`).

For each label you plan to apply that is **not** already present, create it from
the canonical table (look up its `color` and `description` in `labels.json`):

```bash
gh label create "<name>" --color "<hex>" --description "<desc>"
```

Do **not** recolor or edit labels that already exist — leave them as-is.

### 5. Create the issue

Write the body to a temp file to preserve newlines, then create with all chosen
labels:

```bash
BODY_FILE=$(mktemp)
# write the drafted body to $BODY_FILE
gh issue create \
  --title "<title>" \
  --body-file "$BODY_FILE" \
  --label "auto" --label "<type>" [--label "<area>" ...] --label "<priority>"
rm "$BODY_FILE"
```

Return the issue URL to the user.

### 6. Set a milestone (optional)

If a milestone is clearly derivable — the conversation references a release or
target, or there is an obvious current/open milestone the issue belongs to — set
it when creating the issue by adding `--milestone "<title>"` to the
`gh issue create` call above, or afterward:

```bash
gh issue edit <number> --milestone "<title>"
```

If no milestone clearly applies, omit it — do not guess. **Never set an
assignee.**

## Do not

- Do not ask for confirmation — this skill is fully autonomous.
- Do not recolor or edit labels that already exist.
- Do not add assignees or projects. (Milestones are allowed — see step 6.)
- Do not create a worktree or branch — this skill only files the issue.
- Do not invent acceptance criteria the conversation doesn't support.
