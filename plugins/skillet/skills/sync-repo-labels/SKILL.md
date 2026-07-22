---
name: sync-repo-labels
description: Seed and sync the canonical skillet label set (auto/type/area/priority) into a GitHub repo so issues are always labelable. Additive and drift-fixing — creates missing labels and updates ones whose color/description drifted, but never deletes or touches labels outside the canonical set. Use to set up labels on a new or existing repo.
argument-hint: "[owner/repo]"
model: haiku
---

# Sync Repo Labels Skill

Seed/sync the canonical label set into a repo. Additive and drift-fixing, never
destructive.

## When Invoked

Optional argument: a target repo as `owner/name`. If omitted, use the repo in the
current working directory.

## Canonical labels

The label taxonomy is the shared data file, relative to this plugin's skills
root:

```
../_shared/labels.json
```

Read it first. It is a JSON array of `{ name, color, description }` — the
complete set this skill manages.

## Workflow

### 1. Preflight + resolve repo

```bash
gh auth status                                            # must succeed
gh repo view "<arg or omitted>" --json nameWithOwner --jq '.nameWithOwner'
```

If `gh` isn't authenticated or the repo can't be resolved, stop and tell the
user. Capture the resolved `owner/name` as `$REPO` and pass `--repo "$REPO"` to
every `gh label` call below.

### 2. Load canonical + current labels

- Read `../_shared/labels.json` for the canonical set.
- Fetch the repo's current labels with their color and description:

```bash
gh label list --repo "$REPO" --limit 200 --json name,color,description
```

### 3. Reconcile each canonical label

For every label in `labels.json`:

- **Missing** (no current label with that name) → create it:

  ```bash
  gh label create "<name>" --repo "$REPO" --color "<hex>" --description "<desc>"
  ```

  **Exception — `feature` / `enhancement` alias.** If the canonical label is
  `feature` and the repo already has an `enhancement` label (GitHub's default),
  **do not** create `feature`. Treat the existing `enhancement` as the type
  label so you don't seed a competing duplicate. Report it as `Skipped
  (enhancement present)` rather than `Created`. This is the only canonical label
  with a recognized alias.

- **Present but drifted** (color OR description differs from canonical) → update
  it to match. Compare colors case-insensitively and ignore a leading `#`:

  ```bash
  gh label edit "<name>" --repo "$REPO" --color "<hex>" --description "<desc>"
  ```

- **Present and matching** → leave unchanged.

Labels in the repo that are **not** in `labels.json` are the repo's own — leave
them completely untouched. **Never delete a label.**

### 4. Report

Print a summary grouped as **Created**, **Updated**, **Unchanged**, and
**Skipped** (e.g. `feature` when `enhancement` is present), listing the label
names in each group, plus a one-line total.

## Extending the taxonomy

The canonical set is deliberately small. Real backlogs almost always add more,
and that is expected — sync is **additive and never deletes**, so a repo's own
labels are always safe. Two common extensions:

- **Area labels are repo-defined.** `frontend` / `backend` / `database` name the
  *stack layer*. Domain/feature areas (e.g. `Auth & Security`, `Notifications`,
  `Calendar & Scheduling`) are inherently repo-specific and therefore **not**
  canonical. Define them per repo; this skill leaves them untouched.

- **Optional type labels.** `testing`, `documentation`, `infra` / `deployment`,
  and `tooling` are common enough that many repos add them. They are **not** in
  the canonical set (so sync never forces them on a repo), but they are a
  reasonable opt-in extension. Add them to the repo directly with `gh label
  create` if you want them; sync will then leave them as the repo's own.

## Do not

- Never delete a label.
- Never touch labels outside the canonical set.
- Never change a non-canonical label's color or description.
