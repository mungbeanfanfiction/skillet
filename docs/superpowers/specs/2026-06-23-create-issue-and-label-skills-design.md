# Create-Issue & Sync-Repo-Labels Skills — Design

## Summary

Two new skills for the `skillet` plugin, sharing one canonical label table:

- **`/create-issue`** — create a well-formed GitHub issue from conversation
  context, auto-labeled across four dimensions, fully autonomously.
- **`/sync-repo-labels`** — seed/sync the full canonical label set into a repo
  so issues are always labelable.

A third skill, **`/init-repo`** (broader repo setup that calls
`/sync-repo-labels` internally), is **out of scope** — it will be filed as a
GitHub issue via `/create-issue` once that skill exists.

## Canonical label set

The single source of truth is a shared data file:

```
plugins/skillet/skills/_shared/labels.json
```

It is a JSON array of `{ name, color, description }` objects. Both skills read
it at runtime. Colors are 6-hex without the leading `#`.

| Dimension | Labels |
|---|---|
| Queue | `auto` |
| Type | `explore`, `feature`, `bug`, `chore`, `refactor` |
| Area | `frontend`, `backend`, `database` |
| Priority | `p0`, `p1`, `p2` |

The `auto` label is what an autonomous queue (`/drain-queue`, per the
`2026-05-29-autonomous-queue` design) lists against to pick up work. It was
previously named `ready-for-claude`; the canonical name is now `auto`.

Proposed colors/descriptions (final values live in `labels.json`):

| Label | Color | Description |
|---|---|---|
| `auto` | `5319e7` | Ready for autonomous agent to work |
| `explore` | `a371f7` | Spike / investigation, not direct implementation |
| `feature` | `0e8a16` | New functionality |
| `bug` | `d73a4a` | Something is broken |
| `chore` | `bfbfbf` | Maintenance, tooling, deps |
| `refactor` | `fbca04` | Restructuring without behavior change |
| `frontend` | `1d76db` | Touches the frontend |
| `backend` | `0052cc` | Touches the backend |
| `database` | `006b75` | Touches the database / schema |
| `p0` | `b60205` | Urgent / blocking |
| `p1` | `d93f0b` | High priority |
| `p2` | `fef2c0` | Normal / later |

## Skill 1: `/create-issue`

Create a GitHub issue from conversation context, fully autonomously (no
confirmation gate).

**Argument (optional):** a topic/hint string. If omitted, synthesize from the
conversation.

**Workflow:**

1. **Preflight.** Verify `gh auth status` succeeds and a repo is detectable
   (`gh repo view --json nameWithOwner`). Stop with a clear message if not.
2. **Draft the issue.**
   - Title: short, imperative.
   - Body (structured Markdown): `## Context`, `## What needs to happen`,
     `## Acceptance criteria`. Do not invent acceptance criteria the
     conversation doesn't support — leave a `TODO` bullet if genuinely unknown.
3. **Infer labels** (no confirmation):
   - **Queue:** `auto` — *always applied*.
   - **Type:** exactly one of `explore` / `feature` / `bug` / `chore` /
     `refactor`.
   - **Area:** one or more of `frontend` / `backend` / `database` (omit if the
     issue genuinely touches none, e.g. a pure docs/tooling chore).
   - **Priority:** exactly one of `p0` / `p1` / `p2`. Default `p2` when unclear.
4. **Ensure labels exist.** Read `labels.json`. Fetch the repo's labels once
   (`gh label list --json name`). For each *needed* label that is missing,
   create it from the canonical table
   (`gh label create <name> --color <hex> --description "<desc>"`). Do **not**
   recolor or edit labels that already exist.
5. **Create the issue.** Write the body to a temp file (preserve newlines), then
   `gh issue create --title "<title>" --body-file "<tmp>" --label <l1> --label <l2> …`.
   Return the issue URL.

**Do-nots:**
- No confirmation prompt — fully autonomous.
- Don't recolor/edit existing labels.
- Don't add assignees, milestones, or projects.
- Don't create a worktree or branch at runtime — issue creation only.

## Skill 2: `/sync-repo-labels`

Seed/sync the canonical label set into a repo. Additive + drift-fixing, never
destructive.

**Argument (optional):** a target repo (`owner/name`). Defaults to the repo in
the current working directory.

**Workflow:**

1. **Preflight.** Verify `gh auth status` and resolve the target repo.
2. **Load canonical + current.** Read `labels.json`. Fetch the repo's labels
   (`gh label list --json name,color,description`).
3. **Reconcile** each canonical label:
   - Missing → create
     (`gh label create <name> --color <hex> --description "<desc>"`).
   - Exists but color or description differs → update to match
     (`gh label edit <name> --color <hex> --description "<desc>"`).
   - Exists and matches → leave unchanged.
   - Non-canonical labels (the repo's own) → leave untouched. **Never delete.**
4. **Report** a summary: created / updated / unchanged counts and names.

**Do-nots:**
- Never delete a label.
- Never touch labels outside the canonical set.

## Deferred: `/init-repo` (out of scope)

Broader repo bootstrap (e.g. PR template, branch protection, default labels)
that **calls `/sync-repo-labels` internally** for the label portion. Not built
now. After `/create-issue` lands, use it to file a GitHub issue capturing this
so the work is queued (and dogfoods `/create-issue`).

## Files touched

- `plugins/skillet/skills/_shared/labels.json` — new (shared data).
- `plugins/skillet/skills/create-issue/SKILL.md` — new.
- `plugins/skillet/skills/sync-repo-labels/SKILL.md` — new.
- `README.md` — add both skills to the skills table and the layout tree.

## Testing / verification

These are prose skills (no compiled code), so verification is manual:

- Lint the JSON: `node -e "JSON.parse(require('fs').readFileSync('plugins/skillet/skills/_shared/labels.json','utf8'))"`.
- Dry-run `/create-issue` against a scratch repo: confirm it creates missing
  labels and opens a correctly-labeled issue.
- Dry-run `/sync-repo-labels` against a repo with partial/no labels and against
  one with drifted labels: confirm create + update, and that non-canonical
  labels survive.
