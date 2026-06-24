# /triage-issue Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `/triage-issue` skill that performs fully-autonomous first-pass triage of an existing GitHub issue — assess, enrich a thin body, apply canonical labels, set a milestone, and post a triage comment — without deep codebase investigation.

**Architecture:** One new prose `SKILL.md` under `plugins/skillet/skills/triage-issue/`, following the existing `create-issue` / `explore-issue` patterns (frontmatter + Markdown workflow, auto-discovered — no manifest edit). Plus three small supporting edits: add an `epic` label to the shared `labels.json`, add milestone support to `create-issue`, and list the new skill in the README (table + file tree).

**Tech Stack:** Markdown skills with YAML frontmatter; `gh` CLI for all GitHub effects; the skillet repo's semantic-release flow and `make ci` gate.

## Global Constraints

- **No `Co-Authored-By` trailer in any commit** — the skillet repo hook rejects it.
- **Commit message types drive releases** — use `feat:` for the new skill (minor bump), `docs:`/`chore:` for no-release changes. Match Conventional Commits.
- **Skills are auto-discovered** — a new `SKILL.md` needs no manifest/registry edit.
- **No test framework for skills** — these are prose files. "Verification" means: valid YAML frontmatter, valid JSON where applicable, internal consistency, and `make ci` passing. There is no `pytest`/`tsc`.
- **Fully autonomous** — `/triage-issue` never asks for confirmation, with exactly one permitted exception: interactive mode with no inferable issue number may ask which issue to triage.
- **Never set an assignee** anywhere in `/triage-issue`.
- Label colors/descriptions are the single source of truth in `plugins/skillet/skills/_shared/labels.json` — never recolor or edit existing labels at runtime.
- Spec of record: `docs/superpowers/specs/2026-06-23-triage-issue-design.md`.

---

### Task 1: Add the `epic` label to the shared label set

This is the foundation for the decomposition feature — the skill labels an epic with `epic`, so the label must exist in the canonical set first. Self-contained: one JSON entry, independently reviewable.

**Files:**
- Modify: `plugins/skillet/skills/_shared/labels.json`

**Interfaces:**
- Consumes: nothing.
- Produces: a canonical label `{ name: "epic", color: "c2e0c6", description: "Parent issue tracking sub-issues" }` that `sync-repo-labels`, `create-issue`, and `triage-issue` all read at runtime via `../_shared/labels.json`.

- [ ] **Step 1: Verify current contents and that `epic` is absent**

Run:
```bash
cd /Users/leahpeker/development/skillet/.claude/worktrees/feat-triage-issue-skill
jq -e 'any(.[]; .name == "epic")' plugins/skillet/skills/_shared/labels.json
```
Expected: prints `false` and exits non-zero (the label does not yet exist).

- [ ] **Step 2: Add the `epic` entry**

Append a new object to the array. The file is a flat JSON array of `{ name, color, description }`. Add `epic` as the last entry (after `p2`). The `c2e0c6` color is distinct from every existing entry. Resulting file:

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
  { "name": "p2",       "color": "fef2c0", "description": "Normal / later" },
  { "name": "epic",     "color": "c2e0c6", "description": "Parent issue tracking sub-issues" }
]
```

- [ ] **Step 3: Verify the JSON is valid and `epic` is present with the right color**

Run:
```bash
jq -e '.[] | select(.name == "epic") | .color == "c2e0c6" and .description == "Parent issue tracking sub-issues"' \
  plugins/skillet/skills/_shared/labels.json
```
Expected: prints `true` and exits 0. (If `jq` errors, the JSON is malformed — fix the trailing comma / brackets.)

- [ ] **Step 4: Confirm no duplicate names and color uniqueness**

Run:
```bash
jq -e '([.[].name] | length) == ([.[].name] | unique | length)' plugins/skillet/skills/_shared/labels.json && \
jq -e '([.[].color] | length) == ([.[].color] | unique | length)' plugins/skillet/skills/_shared/labels.json
```
Expected: both print `true` and exit 0 (no duplicate label names, no duplicate colors).

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/_shared/labels.json
git commit -m "feat(labels): add epic label for issue decomposition"
```

---

### Task 2: Add milestone support to `/create-issue`

`/triage-issue`'s milestone step is described in the spec as "mirroring step 7" of `create-issue`. For that mirror to exist, `create-issue` must first gain a milestone step and relax its "do not" rule. Independently reviewable: a reviewer can accept this `create-issue` change on its own.

**Files:**
- Modify: `plugins/skillet/skills/create-issue/SKILL.md`

**Interfaces:**
- Consumes: the canonical label set from Task 1 indirectly (no direct dependency; this task is about milestones, not labels).
- Produces: a documented milestone convention in `create-issue` that `triage-issue` (Task 3) refers to as the mirror for its own milestone step.

- [ ] **Step 1: Add a milestone step after the "Create the issue" step**

In `plugins/skillet/skills/create-issue/SKILL.md`, the workflow currently ends step 5 ("Create the issue") with "Return the issue URL to the user." Insert a new step 6 immediately after step 5's code block and before the `## Do not` section. Add this exactly:

```markdown
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
```

- [ ] **Step 2: Relax the "do not" rule to allow milestones**

In the `## Do not` list, change the milestone line. Replace:

```markdown
- Do not add assignees, milestones, or projects.
```

with:

```markdown
- Do not add assignees or projects. (Milestones are allowed — see step 6.)
```

- [ ] **Step 3: Verify the edits landed and frontmatter is intact**

Run:
```bash
grep -n "### 6. Set a milestone" plugins/skillet/skills/create-issue/SKILL.md && \
grep -n "Do not add assignees or projects" plugins/skillet/skills/create-issue/SKILL.md && \
grep -c "Do not add assignees, milestones, or projects" plugins/skillet/skills/create-issue/SKILL.md
```
Expected: the first two greps print matching lines; the third prints `0` (old rule fully removed).

- [ ] **Step 4: Verify frontmatter still parses (name/description/argument-hint present)**

Run:
```bash
awk '/^---$/{c++; next} c==1{print}' plugins/skillet/skills/create-issue/SKILL.md | grep -E "^(name|description|argument-hint):"
```
Expected: prints the three frontmatter keys — confirms the edits didn't corrupt the YAML block.

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/create-issue/SKILL.md
git commit -m "feat(create-issue): support setting a milestone"
```

---

### Task 3: Create the `/triage-issue` skill

The core deliverable. A single prose `SKILL.md` implementing the full triage workflow from the spec. Self-contained and independently reviewable as the skill's whole behavior.

**Files:**
- Create: `plugins/skillet/skills/triage-issue/SKILL.md`

**Interfaces:**
- Consumes: the `epic` label (Task 1) and the `create-issue` milestone convention (Task 2), both referenced by the skill prose.
- Produces: the `/triage-issue` skill, auto-discovered by name. Returns a structured result with status `triaged` / `routed-explore` / `decomposed` / `skipped` (+ reason) for queue consumption.

- [ ] **Step 1: Create the skill file with frontmatter and full workflow**

Create `plugins/skillet/skills/triage-issue/SKILL.md` with exactly this content (the `description` mirrors the spec's framing; the workflow steps follow the spec's renumbered 1–9):

````markdown
---
name: triage-issue
description: First-pass triage of an existing GitHub issue — assess it, enrich a thin body non-destructively, apply canonical labels (always including `auto`), set a milestone where derivable, and post a triage-summary comment. The inverse of `/create-issue`. Fully autonomous; does NOT do deep codebase investigation (that's `/explore-issue`). Use when an existing issue needs to be made actionable and queue-routable, or when the autonomous queue routes an un-triaged issue here.
argument-hint: "<issue-number>"
---

# Triage Issue Skill

Take an issue that **already exists** and bring it up to the same bar as
`/create-issue`: assess it, enrich a thin body, apply the canonical labels, set a
milestone where derivable, and — only when clearly warranted — break a too-big
issue into an epic plus sub-issues. This is a **first-pass** triage. It makes an
issue actionable and routable; it does **not** do deep codebase investigation —
that is `/explore-issue`'s job.

This skill runs **both interactively and unattended**. Like `/create-issue`, it
is **fully autonomous** and never asks for confirmation. Every uncertainty it
cannot resolve is recorded in an `## Open Questions` section of the enriched body
rather than blocking on a prompt.

**No worktree.** `/triage-issue` writes **no repo files** — every effect is
GitHub-side (labels, body, comments, milestone, child issues). It does not create
a worktree or branch; it operates directly against the repo it is invoked in.

## When Invoked

The argument is a GitHub issue number.

- **Queue (unattended)** → the number is always passed explicitly.
- **Interactive, omitted** → infer the issue from the current branch name (a
  leading number, or an `issue-<n>` / `<n>-...` pattern) the way `review-fix` and
  `explore-issue` do. If no issue can be inferred, that is the one permitted
  exception to the no-prompting rule: ask the user which issue to triage.
- **Invalid / missing number** → interactive: stop and ask for a valid number;
  queue: return a `skipped` result with the reason and write nothing.

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
- **Epic:** `epic` — added only when an issue is decomposed (see step 5).

## Workflow

### 1. Preflight

```bash
gh auth status                                            # must succeed
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
gh issue view <number> --repo "$REPO" \
  --json number,title,body,labels,comments,milestone,url
```

If `gh` is unauthenticated or no repo resolves, stop (interactive) / return
`skipped` (queue). Read title + body + comments — that is the full statement of
the ask.

### 2. Assess

A **first-pass** judgment only — no codebase investigation, no Explore agents:

- **Work type:** which canonical type best fits (`explore` / `feature` / `bug` /
  `chore` / `refactor`).
- **Robustness:** is the body already structured and actionable, or thin?
- **Size:** does it clearly span multiple independent units of work?

### 3. Route explore-type issues, then stop

If the assessed type is `explore`:

- Apply labels `explore` + `auto` + any clear area + a priority.
- Create any missing labels (step 6 rules).
- Set a milestone if derivable (step 7).
- Post the triage comment (step 8) noting it is routed to `/explore-issue`.
- **Stop.** Do **not** enrich the body or decompose — that is `/explore-issue`'s
  responsibility.

### 4. Enrich the body (non-destructive) — non-explore only

If the body is already robust, leave it untouched. Otherwise **preserve and
append**: never discard what the author wrote.

New body shape:

```markdown
## Context

<why this matters / where it came from>

## What needs to happen

<the concrete change>

## Acceptance criteria

- [ ] <observable outcome>

## Open Questions

- <uncertainty the skill could not resolve; omit the section if none>

---

## Original

<the author's original body, verbatim>
```

Derive everything from the issue itself (title, body, comments). Do **not**
invent acceptance criteria the issue doesn't support — if genuinely unknown,
leave a single `- [ ] TODO`. Update via `gh issue edit <number> --body-file`.

### 5. Decompose into epic + sub-issues — only when clearly warranted

Default is **not** to split. Only decompose when the issue clearly spans multiple
independent work units. When it does:

- Relabel the original issue as the **epic**: add the `epic` label and an
  `## Epic` checklist section linking children:

  ```markdown
  ## Epic

  - [ ] #<child-1>
  - [ ] #<child-2>
  ```

- File each sub-issue as its own GitHub issue (via the same drafting + labeling
  rules as `/create-issue`), each cross-linked back with a `Part of #<epic>`
  line and carrying its own canonical labels (incl. `auto`).
- The epic itself keeps `auto` plus `epic`; its own type/area/priority reflect
  the overall effort.

### 6. Apply canonical labels

Label taxonomy lives in `../_shared/labels.json` (read before labeling):

- **Queue:** always include `auto`.
- **Type:** exactly one (`explore` / `feature` / `bug` / `chore` / `refactor`),
  plus `epic` when the issue was decomposed.
- **Area:** zero or more of `frontend` / `backend` / `database` it clearly
  touches.
- **Priority:** exactly one; `p0` only for urgent/blocking, `p1` high, default
  `p2`.

Ensure needed labels exist before applying. Fetch existing once:

```bash
gh label list --limit 200 --json name --jq '.[].name'
```

For each planned label not present, create it from `labels.json` (look up its
`color` + `description`). **Never recolor or edit labels that already exist.**

```bash
gh label create "<name>" --color "<hex>" --description "<desc>"
```

Apply all chosen labels to the issue:

```bash
gh issue edit <number> --repo "$REPO" --add-label "auto" --add-label "<type>" [--add-label "<area>" ...] --add-label "<priority>"
```

### 7. Set a milestone — no assignee

If a milestone is clearly derivable (the issue references a release/target, or
there is an obvious current/open milestone it belongs to), set it:

```bash
gh issue edit <number> --repo "$REPO" --milestone "<title>"
```

If no milestone clearly applies, omit it — do not guess. **Never set an
assignee.**

### 8. Post a triage summary comment

Comment on the issue summarizing the triage decision so there's an audit trail:

- Assessed type + the labels applied (and why, briefly).
- Whether the body was enriched.
- Decomposition result, with links to any child issues (or "not decomposed").
- Milestone set (or "none").
- For explore issues: note routing to `/explore-issue`.

```bash
gh issue comment <number> --repo "$REPO" --body-file <file>
```

If the comment fails (e.g. permissions), do **not** error out — the labels, body,
and milestone still stand. Record the failure in the returned report.

### 9. Return a structured result

For queue compatibility, return a structured result describing the outcome:

- `triaged` — normal path: labels (+ body enrichment + milestone) applied.
- `routed-explore` — explore-type: labeled and handed to `/explore-issue`.
- `decomposed` — split into an epic + child issues (include child numbers).
- `skipped` — bad/missing issue or preflight failure (include the reason).

Include the labels applied, the milestone (or none), and any child-issue numbers.

## Do not

- Do not ask for confirmation — this skill is fully autonomous (the only
  exception: interactive mode with no inferable issue number).
- Do not discard the author's original body — always preserve it under
  `## Original`.
- Do not do deep codebase investigation — route `explore` issues to
  `/explore-issue` instead.
- Do not recolor or edit labels that already exist.
- Do not set an assignee.
- Do not create a worktree or branch — every effect is GitHub-side.
- Do not invent acceptance criteria the issue doesn't support.

## Never stall

This skill never asks the user to resolve ambiguity (except the single
no-inferable-number case above). Every uncertainty goes into the body's
`## Open Questions` section and the skill proceeds — keeping interactive and
queue behavior identical so the autonomous queue never idles.

## Notes

- This skill triages **one** issue. It does not browse or batch-triage.
- It is the **inverse of `/create-issue`**: that one files a new well-formed
  issue; this one brings an existing one up to the same bar.
- Never add a `Co-Authored-By` trailer to commits (repo rule).
````

- [ ] **Step 2: Verify the file exists and frontmatter parses**

Run:
```bash
cd /Users/leahpeker/development/skillet/.claude/worktrees/feat-triage-issue-skill
test -f plugins/skillet/skills/triage-issue/SKILL.md && echo "file exists"
awk '/^---$/{c++; next} c==1{print}' plugins/skillet/skills/triage-issue/SKILL.md | grep -E "^(name|description|argument-hint):"
```
Expected: prints `file exists` and the three frontmatter keys (`name: triage-issue`, a `description:`, and `argument-hint:`).

- [ ] **Step 3: Verify workflow steps are sequential 1–9 and key sections present**

Run:
```bash
grep -nE "^### [0-9]+\." plugins/skillet/skills/triage-issue/SKILL.md
grep -cE "^## (Do not|Never stall|Notes|Canonical labels|When Invoked|Workflow)" plugins/skillet/skills/triage-issue/SKILL.md
```
Expected: the first prints nine `### N.` headers numbered 1 through 9 in order; the second prints `6` (all six top-level sections present).

- [ ] **Step 4: Verify no stale references and the embedded fence didn't break the file**

Run:
```bash
grep -n "Co-Authored-By" plugins/skillet/skills/triage-issue/SKILL.md
grep -c '^```' plugins/skillet/skills/triage-issue/SKILL.md
```
Expected: the first prints the single line in the Notes section (the repo-rule reminder — that's correct). The second prints an **even** number (all code fences balanced; an odd count means the nested ` ```markdown ` block broke fence matching — fix before continuing).

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/triage-issue/SKILL.md
git commit -m "feat(skillet): add /triage-issue first-pass triage skill"
```

---

### Task 4: List `/triage-issue` in the README

Documentation so the skill appears in the marketplace's skill table and file tree. Small, independently reviewable.

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the `triage-issue` skill from Task 3 (the README row describes it).
- Produces: nothing downstream.

- [ ] **Step 1: Add a row to the skills table**

In `README.md`, the skills table has a row for `/create-issue` (currently around line 22). Immediately **after** the `/create-issue` row and **before** the `/sync-repo-labels` row, insert:

```markdown
| `/triage-issue` | First-pass triage of an existing GitHub issue: assess, enrich a thin body, apply canonical labels (incl. `auto`), set a milestone, and post a triage comment. The inverse of `/create-issue`. |
```

- [ ] **Step 2: Add the skill to the file-tree block**

In the file-tree block (around lines 46–48), the entries read `explore-issue/SKILL.md`, `create-issue/SKILL.md`, `sync-repo-labels/SKILL.md`. Insert a `triage-issue/SKILL.md` entry after `create-issue/SKILL.md`, matching the existing indentation and `├──` / `└──` connector style of the surrounding lines (use `├──` since it is not the last entry):

```
    ├── triage-issue/SKILL.md
```

- [ ] **Step 3: Verify both insertions landed**

Run:
```bash
cd /Users/leahpeker/development/skillet/.claude/worktrees/feat-triage-issue-skill
grep -c "triage-issue" README.md
```
Expected: prints `2` (one table row + one file-tree entry).

- [ ] **Step 4: Verify table ordering (triage-issue sits between create-issue and sync-repo-labels)**

Run:
```bash
grep -nE "create-issue|triage-issue|sync-repo-labels" README.md
```
Expected: within the table region, line numbers appear in the order `create-issue` < `triage-issue` < `sync-repo-labels`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(readme): list /triage-issue in skills table and file tree"
```

---

### Task 5: Final repo-level verification

A single gate that the whole change is consistent and the repo's CI passes. Folded into its own task because it spans all prior deliverables and is the reviewer's final accept gate.

**Files:**
- None (verification only).

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a clean `make ci` (or documented absence) and a consistency confirmation.

- [ ] **Step 1: Confirm `make ci` target exists, then run it (or note its absence)**

Run:
```bash
cd /Users/leahpeker/development/skillet/.claude/worktrees/feat-triage-issue-skill
if [ -f Makefile ] && grep -qE "^ci:" Makefile; then make ci; else echo "NO make ci target — skillet has no CI gate; skipping"; fi
```
Expected: either `make ci` passes clean, or the explicit "NO make ci target" message. (Per memory, skillet has no Makefile — the else branch is the expected outcome. State which branch ran.)

- [ ] **Step 2: Validate all JSON and confirm every referenced skill path exists**

Run:
```bash
jq empty plugins/skillet/skills/_shared/labels.json && echo "labels.json valid"
for d in triage-issue create-issue explore-issue sync-repo-labels; do
  test -f "plugins/skillet/skills/$d/SKILL.md" && echo "$d OK" || echo "$d MISSING";
done
```
Expected: `labels.json valid` and `OK` for all four skills.

- [ ] **Step 3: Confirm the working tree is clean and review the commit series**

Run:
```bash
git status --short
git log --oneline -5
```
Expected: `git status --short` prints nothing (all work committed); the log shows the four commits from Tasks 1–4 (labels, create-issue milestone, triage-issue skill, README) atop the spec commit. No `Co-Authored-By` trailers.

- [ ] **Step 4: Final cross-check against the spec's "Files touched" table**

Read `docs/superpowers/specs/2026-06-23-triage-issue-design.md` "Files touched" table and confirm each listed file was changed:
- `plugins/skillet/skills/triage-issue/SKILL.md` — created (Task 3)
- `plugins/skillet/skills/_shared/labels.json` — `epic` added (Task 1)
- `plugins/skillet/skills/create-issue/SKILL.md` — milestone step + relaxed rule (Task 2)
- `README.md` — skills list (Task 4)

Run:
```bash
git diff --name-only HEAD~4 HEAD
```
Expected: lists exactly those four files (plus nothing else). If a file is missing or an extra appears, reconcile before declaring done.
