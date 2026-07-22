---
name: audit-permissions
description: Audit an RBAC system for drift between its backend source-of-truth permission keys, the frontend mirror, the role-management UI, and enforcement call sites — then fix the drift on a dedicated worktree and open a draft PR. Detects five drift classes (missing-from-mirror, orphaned/unenforced, missing-from-role-UI, value mismatch, incomplete dotted pairs like member_list.view without member_list.edit). Use when permission keys may have fallen out of sync, or to periodically check an RBAC layer.
argument-hint: "[--report-only]"
model: opus
---

# Audit Permissions Skill

Scan a role-based access control (RBAC) system for **drift** between the layers
that a permission key has to be threaded through, then **fix the drift on a
dedicated worktree and open a draft PR**.

Permission keys are typically duplicated across a backend source of truth and a
frontend mirror, and each key has to appear in enforcement checks and a
role-management UI. When those layers fall out of sync the result is a silent
security or UX bug: a permission that's defined but never enforced, a key the
backend knows about but the frontend can't display, or two sides whose string
literals disagree so the check never matches.

This skill is **generic** — it teaches the audit as a pattern and discovers the
relevant files in an arbitrary repo. The **PDA repo**
(`ProteinDeficientsAnonymous/pda`) is the canonical worked example and its files
are cited throughout, but nothing here is hardcoded to PDA paths.

## When Invoked

No required argument. Optional flag:

- `--report-only` — run the read-only detection phase and print the drift report,
  but **do not** create a worktree, write any fix, or open a PR. Use this to see
  what's drifted without committing to a change.

Without the flag, the skill runs the full pipeline: detect → worktree → fix →
verify → draft PR.

## Permission key naming conventions

Permission keys may be flat (`manage_users`) or use the **`resource.action`
dotted pattern** (`member_list.view`, `member_list.edit`). Both shapes are valid;
the dotted pattern is preferred for new permissions because it groups related
capabilities and makes privilege escalation visible (granting `.edit` without
`.view` is an obvious mistake).

When you encounter dotted keys, treat the `resource` prefix as a grouping —
`member_list.view` and `member_list.edit` are siblings. The audit should
detect **orphaned half-pairs**: a `.view` key with no corresponding `.edit`, or
vice versa, when the resource is the kind of thing that should have both. Flag
these as a fifth drift class (see below). Don't enforce this mechanically for
every resource — some resources are legitimately read-only or write-only —
surface it for human judgment.

## The five drift classes

The audit detects these, between the backend source of truth and the
frontend mirror / role UI / enforcement sites:

1. **Missing from mirror** — a key in the backend source-of-truth enum that has no
   matching entry in the frontend mirror (or, symmetrically, a key in the frontend
   mirror with no backend definition).
2. **Orphaned / unenforced** — a key that is *defined* (backend and/or frontend)
   but never *referenced* by any enforcement check anywhere in the codebase. A
   dead permission.
3. **Missing from role UI** — a defined key that has no entry in the
   role-management UI's label map, so an admin editing a role can never grant or
   revoke it.
4. **Value mismatch** — a key that exists on both sides but whose underlying
   **string literal value** differs between backend and frontend, so an
   enforcement check on one side will never match a grant from the other.
5. **Incomplete dotted pair** — for dotted `resource.action` keys, a resource that
   has a `.view` but no `.edit` (or vice versa), suggesting one half was added and
   the other forgotten. Surface for human judgment; do not auto-add the missing
   half.

## Workflow

### 1. Discover the RBAC layers (don't hardcode paths)

Before detecting anything, locate the four layers in *this* repo. Use the PDA
shape as the reference for what each layer looks like, and grep to find its
equivalent here.

**Backend source of truth** — the enum / constant set that defines every key.
- *PDA:* `backend/users/permissions.py` — a `PermissionKey(models.TextChoices)`
  enum of `key, "Human Label"` pairs.
- *Discover generically:* grep for an enum or choices class whose name contains
  `Permission` / `Perm` / `Capability`, e.g.
  `grep -rniE 'class\s+\w*(Permission|Perm|Capabilit)\w*\b' --include='*.py' --include='*.rb' --include='*.go' --include='*.java' --include='*.ts'`.
  The source of truth is the one enforcement reads from.

**Frontend mirror** — the client-side copy of the same keys.
- *PDA:* `frontend/src/models/permissions.ts` — a `Permission` const + a
  `PermissionKey` type + `hasPermission()`. Its header comment explicitly says
  "mirror backend ... Keep in sync."
- *Discover generically:* the mirror usually announces itself. Grep the frontend
  for that intent, e.g.
  `grep -rniE 'mirror|keep in sync|source of truth' frontend/ src/ --include='*.ts' --include='*.tsx' --include='*.js'`
  and for a `Permission` const/object alongside it.

**Role-management UI** — where an admin assigns keys to roles, including a
human-readable label map.
- *PDA:* `frontend/src/screens/admin/RoleFormDialog.tsx` — a label map that must
  include every key.
- *Discover generically:* grep for a component referencing roles + permissions,
  e.g. `grep -rniE 'role.*(form|editor|dialog|manage)|permission.*label' src/ frontend/`.

**Enforcement call sites** — where a key is actually checked at a boundary.
- *PDA:* `user.has_permission(PermissionKey.X)` (`backend/users/models.py:99`),
  used across `backend/community/*.py` and `backend/users/api.py`; role validation
  in `backend/users/schemas.py`.
- *Discover generically:* once you know the source-of-truth symbol, grep for its
  use, e.g. `grep -rn 'has_permission\|hasPermission\|PermissionKey\.' backend/ frontend/ src/`.

If a repo's RBAC layout genuinely doesn't match this shape (no mirror, no role
UI), audit only the layers that exist and **note in the report which layers were
absent** — don't invent drift against a layer that isn't there.

### 2. Detect drift (read-only)

With the four layers located, extract the key sets and compare. This phase writes
nothing — it only reads and reasons.

1. Parse the **backend** enum into a set of `(key, value)` pairs (for
   `TextChoices`, the value is the first element; the human label is the second).
2. Parse the **frontend mirror** into its `(key, value)` pairs.
3. Collect every **enforcement reference** to a key across the codebase.
4. Collect every key present in the **role-UI label map**.

Then compute each drift class:

- **Missing from mirror:** `backend_keys − frontend_keys` (and report the reverse,
  `frontend_keys − backend_keys`, separately as frontend-only keys).
- **Orphaned / unenforced:** `defined_keys − referenced_keys`.
- **Missing from role UI:** `defined_keys − role_ui_keys`.
- **Value mismatch:** for keys in both sets, where `backend_value ≠ frontend_value`.
- **Incomplete dotted pair:** for all dotted keys, group by `resource` prefix.
  For each resource prefix, check whether both `.view` and `.edit` exist. If only
  one exists, flag it. Also check for other common action suffixes (`.create`,
  `.delete`) — flag any resource that has `.edit` but no `.view`, since that's
  almost always an oversight.

Be careful to distinguish **enum-name references** (e.g. `PermissionKey.EDIT_X`)
from **string-literal values** (`"edit_x"`) — the value-mismatch check compares the
literals, not the symbol names.

### 3. Produce the drift report

Build a structured report — one section per drift class, each listing the specific
keys and the `file:line` evidence. Example shape:

```markdown
## Permission drift report

### Missing from mirror (backend → frontend)
- `archive_events` — defined at backend/users/permissions.py:14, absent from frontend/src/models/permissions.ts

### Orphaned / unenforced
- `legacy_export` — defined backend + frontend, zero enforcement references

### Missing from role UI
- `archive_events` — not in RoleFormDialog.tsx label map

### Value mismatch
- `manage_members` — backend "manage_members" vs frontend "manageMembers"

### Incomplete dotted pairs (needs human judgment)
- `member_list` — has `member_list.view` but no `member_list.edit`
- `event_photos` — has `event_photos.edit` but no `event_photos.view` ⚠️ (edit without view is almost certainly an oversight)

### Layers audited
- backend source of truth: backend/users/permissions.py ✓
- frontend mirror: frontend/src/models/permissions.ts ✓
- role UI: frontend/src/screens/admin/RoleFormDialog.tsx ✓
- enforcement: 23 call sites across backend/ + frontend/
```

If **no drift** is found, report that clearly and stop — there's nothing to fix,
no worktree, no PR.

**If `--report-only`:** print this report and stop here. Do not proceed.

### 4. Create the worktree (off latest main) — BEFORE writing any fix

Hard ordering rule: **create the worktree before any file is written.** Invoke
`/create-worktree` so it branches off the latest default branch:

```
/create-worktree audit-permissions "fix RBAC drift" --noninteractive
```

`/create-worktree` fetches the latest default branch and branches off it, so the
worktree starts from up-to-date code. The `--noninteractive` flag skips its
confirmation prompts, which is required for unattended runs. **All subsequent fix
steps run inside this worktree.**

If worktree creation fails, abort here. Nothing has been written yet, so there is
nothing to clean up — report the failure and stop.

### 5. Apply the corrective fixes

For each drift class, apply the **minimal, safe** correction inside the worktree:

- **Missing from mirror** — add the matching entry to the frontend mirror with the
  **same string value** as the backend (or, for a frontend-only key, the matching
  backend entry — but flag this, since a frontend key with no backend definition
  usually means the backend is authoritative and the frontend entry is stale).
- **Missing from role UI** — add the key + its human-readable label to the role-UI
  label map.
- **Value mismatch** — align the frontend value to the **backend source of truth**
  (the backend is authoritative). Changing the backend value would require a data
  migration on stored role records, so prefer fixing the mirror unless the backend
  value is itself clearly wrong.
- **Orphaned / unenforced** — this one is **judgment-dependent, not mechanical**.
  An unenforced key may be (a) genuinely dead and removable, or (b) a key whose
  enforcement was simply never wired up. **Do not auto-delete keys.** Add the
  orphaned keys to the PR description as findings the human must adjudicate, and
  only mechanically fix them if the request explicitly authorizes removal. When in
  doubt, surface, don't delete.
- **Incomplete dotted pair** — **do not auto-add the missing half.** Adding
  `member_list.edit` when only `member_list.view` exists is a product decision, not
  a mechanical fix. Surface the finding in the PR description for human judgment.

Keep edits surgical — touch only the lines needed to close the drift. Do not
reformat or reorder unrelated entries.

### 6. Run the verification gate

Before claiming the fix is done, run the **target repo's** type-check / lint /
test gate and make it pass. Detect the gate from the repo rather than assuming:

- A documented command in `CLAUDE.md` / `README` (e.g. `make ci`, `make check`).
- Otherwise the language-standard gate — e.g. `npx tsc --noEmit` + `npx eslint .`
  for the frontend, `pytest` / `ruff` / `mypy` for a Python backend, and the
  RBAC-specific tests where they exist (*PDA:*
  `backend/tests/test_role_management.py`, `frontend/src/models/permissions.test.ts`).

If the gate fails, fix the fallout and re-run. If it can't be made green, **do not
open the PR** — stop and report the failure with the output.

### 7. Commit and open a draft PR

First check that step 5 actually wrote something. If the only drift found was
orphaned/unenforced keys — which are surfaced for human judgment, not
mechanically fixed — there may be **no file changes to commit**. In that case do
**not** create an empty commit or a PR: report the orphaned-key findings directly
(as `--report-only` would) and stop. There's nothing to open a PR for.

```bash
git status --porcelain   # if empty, there is nothing to commit — stop and report findings
```

Otherwise commit the fix on the worktree branch (no `Co-Authored-By` trailer —
repo rule):

```bash
git add -A
git commit -m "fix: resolve RBAC permission drift"
```

Then invoke `/open-pr` to push the branch and open a **draft** PR:

```
/open-pr --noninteractive
```

`/open-pr` always creates the PR in draft mode. Use the drift report from step 3
as the basis for the PR overview — summarize **what drift was found and what was
fixed**, and call out any orphaned-key findings left for the human to adjudicate.
Capture the returned PR URL for the final report.

### 8. Report

Report back:

- The drift report (the four classes + which layers were audited).
- What was fixed vs. what was left for human judgment (orphaned keys).
- The worktree path and the draft PR URL.

If there was no drift, the report is simply "no drift found" — no worktree, no PR.

## Notes

- The detection phase (steps 1–3) is **read-only and reusable** — `--report-only`
  exposes it on its own. Only step 5 writes.
- The **backend source of truth is authoritative.** When two layers disagree, the
  fix conforms the other layers to the backend, not the reverse.
- **Never auto-delete a permission key.** Orphaned keys are surfaced for human
  judgment, not removed mechanically.
- Always run the target repo's verification gate before opening the PR; never claim
  success without it passing.
- This skill composes `/create-worktree` and `/open-pr`. It never merges, never
  pushes to the base branch, and always opens the PR as a **draft**.
- Prefer the **`resource.action` dotted pattern** for new permission keys
  (e.g. `member_list.view`, `member_list.edit`). It groups related capabilities,
  makes the privilege escalation relationship visible, and enables the
  incomplete-pair check. Flat keys (`manage_users`) are still valid for
  coarse-grained permissions with no obvious read/write split.
- This skill *reconciles* drift between existing keys. *Adding* a brand-new
  permission across all layers (define → migrate → enforce → mirror → role UI →
  test) is a separate, complementary concern handled by the companion
  `/add-permission` skill where it is available.
