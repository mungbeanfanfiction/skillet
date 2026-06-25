---
name: add-permission
description: Add a new RBAC permission across the full touch-list — backend enum, data migration, server enforcement, frontend mirror, role-management UI, and tests — autonomously, no confirmation prompts. Infers key/label/role from the request and records anything it can't resolve as open questions rather than blocking. Use when asked to add/wire up/introduce a new permission or capability flag to a role-based access system.
argument-hint: "[permission name or description]"
---

# Add Permission Skill

Add a new RBAC permission end-to-end across every layer that has to know about
it, fully autonomously (no confirmation gate). A permission key is typically
**duplicated** across a backend source of truth and a frontend mirror, and a new
key must be threaded through several layers:

> **define key → migrate data → enforce → mirror to client → expose in role UI → test**

Missing any one layer is a silent security or UX bug (an enforced-but-invisible
permission, or a visible-but-unenforced one). This skill walks all of them.

It runs the way `/create-issue` does: **no confirmation prompts**. It infers the
key name, human label, and default role assignment from the request, and records
anything it cannot resolve as **Open Questions** in its final report rather than
stopping to ask.

## When Invoked

Optional argument: the permission to add — a name, a human label, or a sentence
describing the capability (e.g. `"let editors pin announcements"`). If omitted,
synthesize it from the conversation so far.

From whatever you're given, infer three things and write them into the report:

- **Key** — the machine string, in the repo's existing convention (snake_case
  like `pin_announcements`, dotted like `announcements.pin`, etc. — match what
  the existing keys look like, don't impose a new style).
- **Human label** — the display string (`"Pin announcements"`).
- **Default role assignment** — which existing roles, if any, should get the new
  permission by default. If the request doesn't say and it isn't obvious, assign
  it to nothing and record the question — do **not** guess a security-sensitive
  default like granting it to everyone.

## The generic RBAC touch-list

These are the layers a permission lives in. **Discover** each one in the target
repo before editing — the discovery recipes below make this work in an arbitrary
codebase, not just the worked example. Not every repo has every layer (a
backend-only service has no frontend mirror); skip a layer only after you've
confirmed it genuinely doesn't exist, and note that you skipped it.

### Worked example: the PDA repo

`ProteinDeficientsAnonymous/pda` is the canonical reference. Its RBAC shape, by
layer:

| Layer | PDA location | What lives there |
|---|---|---|
| Backend source of truth | `backend/users/permissions.py` | `PermissionKey(models.TextChoices)` enum — `key, "Human Label"` pairs |
| Enforcement | `user.has_permission(PermissionKey.X)` at `backend/users/models.py:99`, called across `backend/community/*.py` and `backend/users/api.py`; role validation in `backend/users/schemas.py` |
| Data migration | `users/migrations/` — e.g. `0010_rename_manage_guidelines.py`, `0021_drop_edit_welcome_message_perm.py` (rename/drop keys held in `Role.permissions` JSONField) |
| Frontend mirror | `frontend/src/models/permissions.ts` | `Permission` const + `PermissionKey` type + `hasPermission()`; header comment says "mirror backend … Keep in sync." |
| Role UI | `frontend/src/screens/admin/RoleFormDialog.tsx` | a label map that must include every key |
| Guards / usage | `frontend/src/auth/guards.tsx`, `useAuth.ts`, various screens |
| Tests | `backend/tests/test_role_management.py`, `frontend/src/models/permissions.test.ts` |

Treat these paths as **the example, not the contract**. The steps below tell you
how to find the equivalents in whatever repo you're actually in.

## Workflow

### 0. Preflight — locate the layers

Before writing anything, find each touch-point. Run these discovery recipes and
record what you find (you'll edit exactly these locations). Adapt the grep
patterns to the repo's language.

1. **Backend source of truth (the enum).** Grep for an existing permission key
   you already know exists, or for the enum type name:
   ```bash
   # by a known existing key value
   grep -rn "manage_guidelines\|has_permission" backend/ --include='*.py'
   # by the enum type
   grep -rn "PermissionKey\|class .*Permission.*Choices\|enum .*Permission" .
   ```
   The file that **defines** the enum (not just references it) is the source of
   truth. Read the existing entries to learn the key convention and the
   label-pairing format.

2. **Frontend mirror.** It is conventionally marked by a "keep in sync" comment.
   Grep for that, then for the mirror type:
   ```bash
   grep -rni "keep in sync\|mirror.*backend\|source of truth" frontend/ src/
   grep -rn "PermissionKey\|hasPermission\|Permission =" --include='*.ts' --include='*.tsx' .
   ```
   The file holding the client-side `Permission` const / `PermissionKey` type is
   the mirror. If there is no frontend (or no mirror), confirm and skip — note it.

3. **Role-management UI.** Find the editor that lists permissions for a role —
   usually a dialog/form with a label map. Grep for the mirror's symbol used in a
   UI file, or for "role" + "form/dialog":
   ```bash
   grep -rln "RoleForm\|RoleDialog\|role.*permission\|permission.*label" --include='*.tsx' --include='*.jsx' .
   ```
   The map that pairs every key with a display label is what you extend.

4. **Enforcement call sites.** Find where permissions are actually checked, so you
   know where the new key should gate behavior:
   ```bash
   grep -rn "has_permission\|hasPermission\|requirePermission\|@permission" .
   ```
   These show the enforcement primitive and where API/server boundaries gate on
   permissions.

5. **Tests.** Find existing permission/role tests to extend:
   ```bash
   grep -rln "permission\|has_permission\|Role" --include='*test*' --include='*spec*' .
   ```

If any layer can't be found, **don't block** — record it as an open question and
proceed with the layers you did find.

### 1. Add the key to the backend source-of-truth enum

Add the new `key, "Human Label"` entry to the enum found in step 0.1, matching
the existing format and key convention exactly. This is the canonical definition
every other layer mirrors.

PDA example: a new line in `PermissionKey(models.TextChoices)` in
`backend/users/permissions.py`.

### 2. Add a data migration if existing role records need it

If roles store their granted permissions as data (e.g. a JSONField list of key
strings) and the request implies existing roles should receive the new key — or
you're renaming/removing a key — generate a data migration to backfill or
rewrite those records. A brand-new key that no existing role needs requires **no**
migration; don't create an empty one.

PDA example: the migrations under `users/migrations/` that rewrite
`Role.permissions` (e.g. `0010_rename_manage_guidelines.py`). Use the project's
migration generator (`python manage.py makemigrations --empty …` then fill in the
data operation) rather than hand-writing the migration file.

If you can't tell whether existing roles should get the key, record it as an open
question and skip the migration — adding a key without granting it to anyone is
the safe default.

### 3. Wire enforcement at the relevant boundary

Add the `has_permission(NewKey)` check (using the enforcement primitive found in
step 0.4) at the API/server boundary the new permission is meant to gate. If the
request names a specific endpoint or action, gate that. If it's ambiguous which
boundary to protect, add the key and its label but record the enforcement
location as an open question — a defined-but-unenforced key is visible drift the
companion `audit-permissions` flow will catch, so flag it loudly rather than
guessing wrong.

### 4. Add the matching entry to the frontend mirror

Add the new key to the client mirror found in step 0.2 — **the same string
value** as the backend key. The mirror exists precisely so the frontend can
reason about permissions; a backend key with no mirror entry is drift. Keep the
mirror's own conventions (const entry + type union member + whatever its
`hasPermission` expects).

PDA example: extend `Permission` / `PermissionKey` in
`frontend/src/models/permissions.ts`.

### 5. Add the human-readable label to the role-management UI

Add the key→label entry to the role editor's label map (step 0.3) so admins can
see and toggle the new permission when editing a role. A key missing from this
map is invisible in the UI even though it's enforced.

PDA example: the label map in
`frontend/src/screens/admin/RoleFormDialog.tsx`.

### 6. Add / extend tests on both sides

Extend the existing permission tests (step 0.5) to cover the new key:

- **Backend** — the new key is a valid permission, enforcement gates the intended
  action, and any migration backfills correctly.
- **Frontend** — the mirror includes the key and `hasPermission` resolves it; if
  there's a backend↔frontend parity test, it now passes with the new key present.

Mirror the style of the existing tests rather than inventing a new harness.

### 7. Run the verification gate before claiming done

Detect and run the target repo's type-check / lint / test gate, and make it pass,
before reporting success. Try, in order, what the repo documents:

- a project command — `make ci`, `make test`, `make agent-ci`;
- otherwise the per-stack gate for each side you touched:
  - backend (PDA-style Django): `python manage.py makemigrations --check`,
    `python -m pytest`, and any configured linter/type-checker (`ruff`, `mypy`);
  - frontend (TS): `npx tsc --noEmit`, `npx eslint .`, and the test runner
    (`npm test` / `vitest` / `jest`).

If a check fails, fix it and re-run. Do **not** report success on a red gate. If
the gate is genuinely un-greenable for a reason outside this change, say so
explicitly with the failing output rather than claiming success.

### 8. Report

Summarize what was changed, file by file (one line per layer touched), the
inferred key / label / role assignment, and an **Open Questions** section listing
everything you couldn't resolve (ambiguous enforcement boundary, default role
grant, a layer you couldn't locate). The Open Questions section is mandatory even
when empty — say "none" so the reader knows you checked.

## Do not

- Do not ask for confirmation — this skill is fully autonomous. Unresolved
  decisions go into Open Questions, not a prompt.
- Do not grant a new permission to all roles (or any role) by default unless the
  request explicitly says so — under-granting is recoverable, over-granting is a
  security bug.
- Do not hardcode the PDA paths. They are the worked example; discover the actual
  touch-points in the repo you're in (step 0).
- Do not skip the frontend mirror or role UI just because the backend change
  "works" — a key present on only one side is exactly the drift this pattern
  exists to prevent.
- Do not report success without running the repo's verification gate.
- Do not add a `Co-Authored-By` trailer to commits (repo rule).
