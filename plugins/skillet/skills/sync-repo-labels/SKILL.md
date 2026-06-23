---
name: sync-repo-labels
description: Seed and sync the canonical skillet label set (auto/type/area/priority) into a GitHub repo so issues are always labelable. Additive and drift-fixing — creates missing labels and updates ones whose color/description drifted, but never deletes or touches labels outside the canonical set. Use to set up labels on a new or existing repo.
argument-hint: "[owner/repo]"
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

- **Present but drifted** (color OR description differs from canonical) → update
  it to match. Compare colors case-insensitively and ignore a leading `#`:

  ```bash
  gh label edit "<name>" --repo "$REPO" --color "<hex>" --description "<desc>"
  ```

- **Present and matching** → leave unchanged.

Labels in the repo that are **not** in `labels.json` are the repo's own — leave
them completely untouched. **Never delete a label.**

### 4. Report

Print a summary grouped as **Created**, **Updated**, **Unchanged**, listing the
label names in each group, plus a one-line total.

## Do not

- Never delete a label.
- Never touch labels outside the canonical set.
- Never change a non-canonical label's color or description.
