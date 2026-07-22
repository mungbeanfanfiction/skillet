---
name: init-repo
description: Bootstrap a GitHub repo with the standard skillet setup — seed the canonical label set (via /sync-repo-labels), add a PR template if one is missing, and optionally enable default-branch protection. Additive and idempotent: safe to re-run against an already-initialized repo. Use to set up a new repo or bring an existing one up to standard.
argument-hint: "[owner/repo] [--protect-branch]"
model: haiku
---

# Init Repo Skill

Bootstrap a GitHub repo with the standard setup: canonical labels, a PR template,
and (optionally) default-branch protection.

Every step is **additive and idempotent** — re-running against an
already-initialized repo makes no destructive changes and only fills in what is
missing or has drifted.

## When Invoked

Optional arguments:

- A target repo as `owner/name`. If omitted, use the repo in the current working
  directory.
- `--protect-branch` — opt in to configuring default-branch protection (off by
  default; see step 4 for why).

## Workflow

### 1. Preflight + resolve repo

```bash
gh auth status                                            # must succeed
gh repo view "<arg or omitted>" --json nameWithOwner,defaultBranchRef \
  --jq '{repo: .nameWithOwner, branch: .defaultBranchRef.name}'
```

If `gh` isn't authenticated or the repo can't be resolved, stop and tell the
user. Capture the resolved `owner/name` as `$REPO` and the default branch as
`$BRANCH`. Pass `--repo "$REPO"` to every `gh` call below.

### 2. Seed the canonical labels

Run the `/sync-repo-labels` skill against `$REPO`. **Do not** reimplement label
logic here — that skill owns the canonical taxonomy (`_shared/labels.json`) and
is already additive + drift-fixing. Invoke it with the resolved repo:

```
/sync-repo-labels <owner/repo>
```

Fold its Created / Updated / Unchanged summary into this skill's final report.

### 3. Add a PR template if missing

Check whether the repo already has a PR template, in the same order
`/open-pr` looks for one (first hit wins):

```bash
for p in \
  .github/pull_request_template.md \
  .github/PULL_REQUEST_TEMPLATE.md \
  .github/PULL_REQUEST_TEMPLATE/*.md \
  docs/pull_request_template.md \
  pull_request_template.md \
  PULL_REQUEST_TEMPLATE.md; do
  [ -f "$p" ] && echo "found: $p" && break
done
```

- **If a template already exists** → leave it completely untouched. Report it as
  "present, unchanged".
- **If none exists** → create `.github/pull_request_template.md` with this
  default. Create the `.github/` directory if it does not exist. **Never
  overwrite** an existing template.

  ```markdown
  ## Overview

  <!-- What changes and why. Link the issue: Closes #<n>. -->

  ## Test plan

  - [ ] TODO

  ## Checklist

  - [ ] Docs updated if behavior changed
  ```

> This skill writes the template into the working tree; it does not commit or
> push. Stage and commit it as part of the bootstrapping change (or let the
> caller's pipeline do so).

### 4. Optionally configure default-branch protection

**Skip this step entirely unless `--protect-branch` was passed.** Branch
protection requires repo-admin permission and can lock a solo maintainer out of
their own default-branch workflow, so it is opt-in rather than automatic.

When opted in, apply a conservative, idempotent ruleset to `$BRANCH` — requiring
a PR before merging and dismissing stale approvals. Setting protection via the
API is itself idempotent (it replaces the protection config wholesale, so
re-running converges to the same state):

```bash
gh api -X PUT "repos/$REPO/branches/$BRANCH/protection" \
  --input - <<'JSON'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "required_approving_review_count": 0
  },
  "restrictions": null
}
JSON
```

If the call fails with a permissions error (not an admin, or a private repo on a
plan without protected branches), **do not stop the whole skill** — report
branch protection as "skipped (insufficient permissions)" and continue to the
report. Branch protection is the only best-effort step; the rest must succeed.

### 5. Report

Print a summary covering each step:

- **Labels** — the Created / Updated / Unchanged counts from `/sync-repo-labels`.
- **PR template** — `created .github/pull_request_template.md` or
  `present, unchanged`.
- **Branch protection** — `configured on <branch>`, `skipped (not requested)`, or
  `skipped (insufficient permissions)`.

End with a one-line "repo `$REPO` is initialized" confirmation.

## Do not

- Never overwrite or delete an existing PR template.
- Never reimplement label logic — always delegate to `/sync-repo-labels`.
- Never enable branch protection unless `--protect-branch` was explicitly passed.
- Never commit or push on the user's behalf — only write the template into the
  working tree.
- Never treat a re-run as an error: idempotent no-ops are the expected outcome on
  an already-initialized repo.
