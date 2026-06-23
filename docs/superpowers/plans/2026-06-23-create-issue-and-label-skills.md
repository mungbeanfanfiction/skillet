# Create-Issue & Sync-Repo-Labels Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two `skillet` skills — `/create-issue` (autonomously create a labeled GitHub issue) and `/sync-repo-labels` (seed/sync the canonical label set into a repo) — sharing one canonical label data file.

**Architecture:** These are prose skills: each is a `SKILL.md` of instructions Claude follows, not executable code. The only data artifact is `_shared/labels.json`, the single source of truth for the canonical label taxonomy. Both SKILL.md files instruct the reader to load `labels.json` (relative to the plugin root) and act on it via the `gh` CLI. Verification is manual (JSON lint + dry-runs against a scratch repo), since there is no compiled code.

**Tech Stack:** Markdown skill files, JSON data file, `gh` CLI, `node` (for JSON lint only).

---

## File Structure

- Create: `plugins/skillet/skills/_shared/labels.json` — canonical label array, single source of truth.
- Create: `plugins/skillet/skills/create-issue/SKILL.md` — the `/create-issue` skill.
- Create: `plugins/skillet/skills/sync-repo-labels/SKILL.md` — the `/sync-repo-labels` skill.
- Modify: `README.md` — add both skills to the skills table and the layout tree.

**Commit rule for this repo:** Never include a `Co-Authored-By: Claude` trailer — a hook rejects it (and un-stages files on failure). All commit commands below omit it.

---

### Task 1: Canonical label data file

**Files:**
- Create: `plugins/skillet/skills/_shared/labels.json`

- [ ] **Step 1: Write the data file**

Create `plugins/skillet/skills/_shared/labels.json` with exactly this content:

```json
[
  { "name": "auto",     "color": "5319e7", "description": "Ready for autonomous agent to work" },
  { "name": "explore",  "color": "a371f7", "description": "Spike / investigation, not direct implementation" },
  { "name": "feature",  "color": "0e8a16", "description": "New functionality" },
  { "name": "bug",      "color": "d73a4a", "description": "Something is broken" },
  { "name": "chore",    "color": "bfbfbf", "description": "Maintenance, tooling, deps" },
  { "name": "refactor", "color": "fbca04", "description": "Restructuring without behavior change" },
  { "name": "frontend", "color": "1d76db", "description": "Touches the frontend" },
  { "name": "backend",  "color": "0052cc", "description": "Touches the backend" },
  { "name": "database", "color": "006b75", "description": "Touches the database / schema" },
  { "name": "p0",       "color": "b60205", "description": "Urgent / blocking" },
  { "name": "p1",       "color": "d93f0b", "description": "High priority" },
  { "name": "p2",       "color": "fef2c0", "description": "Normal / later" }
]
```

- [ ] **Step 2: Lint the JSON**

Run: `node -e "JSON.parse(require('fs').readFileSync('plugins/skillet/skills/_shared/labels.json','utf8')); console.log('ok')"`
Expected: prints `ok` (no parse error).

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/_shared/labels.json
git commit -m "feat(skillet): add canonical label data file for issue/label skills"
```

---

### Task 2: `/create-issue` skill

**Files:**
- Create: `plugins/skillet/skills/create-issue/SKILL.md`

- [ ] **Step 1: Write the SKILL.md**

Create `plugins/skillet/skills/create-issue/SKILL.md` with exactly this content:

````markdown
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
  `chore` for maintenance/tooling/deps; otherwise `feature`.
- **Area:** include each of `frontend` / `backend` / `database` the issue
  clearly touches. If it touches none (e.g. a pure docs/tooling chore), include
  no area label.
- **Priority:** exactly one. Use `p0` only for urgent/blocking; `p1` for high;
  default to `p2` when unclear.

### 4. Ensure the needed labels exist

Fetch the repo's existing labels once:

```bash
gh label list --limit 200 --json name --jq '.[].name'
```

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

## Do not

- Do not ask for confirmation — this skill is fully autonomous.
- Do not recolor or edit labels that already exist.
- Do not add assignees, milestones, or projects.
- Do not create a worktree or branch — this skill only files the issue.
- Do not invent acceptance criteria the conversation doesn't support.
````

- [ ] **Step 2: Verify the canonical-labels path resolves**

The SKILL.md references `../_shared/labels.json`. From the skill directory, confirm that resolves to the data file:

Run: `test -f plugins/skillet/skills/create-issue/../_shared/labels.json && echo "ok"`
Expected: prints `ok`.

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/create-issue/SKILL.md
git commit -m "feat(skillet): add create-issue skill"
```

---

### Task 3: `/sync-repo-labels` skill

**Files:**
- Create: `plugins/skillet/skills/sync-repo-labels/SKILL.md`

- [ ] **Step 1: Write the SKILL.md**

Create `plugins/skillet/skills/sync-repo-labels/SKILL.md` with exactly this content:

````markdown
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
````

- [ ] **Step 2: Verify the canonical-labels path resolves**

Run: `test -f plugins/skillet/skills/sync-repo-labels/../_shared/labels.json && echo "ok"`
Expected: prints `ok`.

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/sync-repo-labels/SKILL.md
git commit -m "feat(skillet): add sync-repo-labels skill"
```

---

### Task 4: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add both skills to the skills table**

In `README.md`, find the `## Skills` table (the Markdown table whose header row is `| Skill | What it does |`). Add these two rows immediately after the existing `/review-fix` row, preserving the existing column alignment:

```markdown
| `/create-issue` | Create a GitHub issue from the conversation, auto-labeled (queue/type/area/priority); creates any missing labels first. |
| `/sync-repo-labels` | Seed/sync the canonical label set into a repo (additive + drift-fix, never deletes). |
```

- [ ] **Step 2: Add both skill dirs to the layout tree**

In the same `README.md`, find the ` ## Layout ` code block (the fenced block containing the `plugins/skillet/` tree). Inside the `skills/` listing, add these entries alongside the existing skill dirs (keep the tree's box-drawing style consistent — use `├──` for all but the last entry and `└──` for the final one):

```
    ├── create-issue/SKILL.md
    ├── sync-repo-labels/SKILL.md
    └── _shared/labels.json
```

Ensure whichever entry is now last in the block uses `└──` and all earlier entries use `├──`. (If `_shared/labels.json` is the final line, it takes `└──`; the previously-last entry becomes `├──`.)

- [ ] **Step 3: Verify the README mentions both skills**

Run: `grep -c -E '/create-issue|/sync-repo-labels' README.md`
Expected: prints a number `>= 2`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(skillet): document create-issue and sync-repo-labels skills"
```

---

### Task 5: Manual verification against a scratch repo

This task is run by the human (or with explicit human go-ahead) because it
mutates a real GitHub repo. It is the equivalent of an integration test for
prose skills.

**Files:** none (runtime verification only)

- [ ] **Step 1: Pick or create a scratch repo**

Use a throwaway repo you own, e.g. `gh repo create <you>/skillet-scratch --private --clone` (or reuse an existing scratch repo). Note its `owner/name`.

- [ ] **Step 2: Dry-run `/sync-repo-labels` against it**

Invoke `/sync-repo-labels <owner>/skillet-scratch`.
Expected: it creates the canonical labels missing from a fresh repo and reports them under **Created**; GitHub's default labels (`bug`, etc.) that overlap a canonical name get **Updated** to the canonical color/description, and any non-overlapping defaults are left **Unchanged** / untouched. Confirm with:

Run: `gh label list --repo <owner>/skillet-scratch --json name --jq '.[].name' | sort`
Expected: includes `auto`, `explore`, `feature`, `bug`, `chore`, `refactor`, `frontend`, `backend`, `database`, `p0`, `p1`, `p2`.

- [ ] **Step 3: Re-run to confirm idempotence + drift-fix**

Manually drift one label: `gh label edit p2 --repo <owner>/skillet-scratch --color 000000`.
Invoke `/sync-repo-labels <owner>/skillet-scratch` again.
Expected: `p2` reported under **Updated** (color restored to `fef2c0`); everything else **Unchanged**; nothing **Created**; no label deleted.

- [ ] **Step 4: Dry-run `/create-issue`**

From a clone of the scratch repo (so `gh repo view` resolves it), invoke `/create-issue add a settings page` (or describe something in conversation).
Expected: an issue is created and the returned URL opens an issue carrying `auto`, exactly one type label, the relevant area label(s), and exactly one priority label. Verify:

Run: `gh issue list --repo <owner>/skillet-scratch --json number,labels --jq '.[0].labels[].name' | sort`
Expected: includes `auto`, one of the type labels, and one of `p0`/`p1`/`p2`.

- [ ] **Step 5: Verify auto-create path on a label-less repo**

On a scratch repo where you have NOT run `/sync-repo-labels` (so canonical labels are absent), invoke `/create-issue …`.
Expected: `/create-issue` creates the labels it needs (e.g. `auto`, `feature`, `p2`) before opening the issue; the issue ends up correctly labeled.

---

## Post-implementation: file the `/init-repo` follow-up

After the skills land and verify, dogfood `/create-issue` by filing the deferred
`/init-repo` issue against the `skillet` repo:

- Invoke `/create-issue` describing: "Add an `/init-repo` skill that bootstraps a
  repo (PR template, branch protection, default labels) and calls
  `/sync-repo-labels` internally for the label portion." It should land as a
  `feature` + `auto` issue.
- This is intentionally done via `/create-issue` itself as the first real-world
  exercise of the skill.

---

## Self-Review Notes

- **Spec coverage:** shared `labels.json` (Task 1) ✓; `/create-issue` autonomous + always-`auto` + infer + auto-create (Task 2) ✓; `/sync-repo-labels` additive + drift-fix + never-delete (Task 3) ✓; README (Task 4) ✓; deferred `/init-repo` filed via `/create-issue` (post-impl section) ✓; manual verification standing in for tests (Task 5) ✓.
- **No code tests:** these are prose skills, so TDD's failing-test step is replaced by manual `gh` dry-runs; this is called out in Architecture.
- **Label name/color/description consistency:** the values in `labels.json` (Task 1) are the only definitions; Tasks 2/3 reference them by lookup rather than restating, so they can't drift.
