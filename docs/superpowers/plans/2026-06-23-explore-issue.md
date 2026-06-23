# `/explore-issue` Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a prose `SKILL.md` skill, `/explore-issue`, that deep-dives a single GitHub issue — creating a worktree off latest main, fanning out parallel read-only Explore agents, synthesizing a findings spec, self-reviewing it, opening a draft PR, and commenting on the issue.

**Architecture:** This is a **documented procedure skill**, exactly like the other skillet skills (`create-worktree`, `open-pr`, `review-fix`). It is a single Markdown file with YAML frontmatter plus a prose workflow that Claude executes. It is **not** code — there are no functions to unit-test. It **composes** existing skills (`/create-worktree`, `/open-pr`) and the superpowers `dispatching-parallel-agents` skill, and shells out to `gh`. Verification is the manual end-to-end run defined in the spec, plus structural checks on the file itself.

**Tech Stack:** Markdown + YAML frontmatter (the skill); `gh` CLI; git worktrees; superpowers `dispatching-parallel-agents`. Repo conventions: skills live at `plugins/skillet/skills/<name>/SKILL.md`; the `no-co-authored-by` rule forbids `Co-Authored-By` commit trailers.

**Source spec:** `docs/superpowers/specs/2026-06-23-explore-issue-design.md`

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `plugins/skillet/skills/explore-issue/SKILL.md` | The entire skill: frontmatter (name, description, argument-hint) + the prose workflow. | **Create** |
| `README.md` | Repo skill index table — add a `/explore-issue` row. | **Modify** |

No code files, no test files (this repo only tests `scripts/*.mjs`; skills are prose). The "tests" are the manual verification in Task 4.

---

## Task 1: Create the skill file with frontmatter and the workflow skeleton

**Files:**
- Create: `plugins/skillet/skills/explore-issue/SKILL.md`

- [ ] **Step 1: Create the skill file with frontmatter**

The frontmatter must match the style of the other skillet skills (see `plugins/skillet/skills/review-fix/SKILL.md:1-5`): a `name`, a `description` that begins with what it does and ends with a "Use when…" trigger, and an `argument-hint`.

Create `plugins/skillet/skills/explore-issue/SKILL.md` with exactly this content as the start of the file:

```markdown
---
name: explore-issue
description: Deep-dive a single GitHub issue — create a worktree off latest main, fan out parallel read-only Explore agents, synthesize findings into a committed spec, open a draft PR, and comment on the issue. Use when an issue needs investigation (a spike, an open question, a "why does X" / "should we Y") rather than a direct implementation, or when the autonomous queue routes an `explore`-labeled issue here.
argument-hint: "<issue-number>"
---

# Explore Issue Skill

Deep-dive **one** GitHub issue: investigate it thoroughly against the codebase
and produce a durable findings spec — without writing application code.

This skill is built to run **both interactively and unattended**. `/drain-queue`
routes any issue carrying the `explore` label here instead of its normal
implement-it path. Because it must work in that unattended pipeline, it
**never asks the user to resolve ambiguity** — every uncertainty it cannot
resolve is recorded in an **Open Questions** section of the spec, and it proceeds.

## When Invoked

The argument is a GitHub issue number.

- Interactive, omitted → ask which issue to explore.
- Queue → the number is always passed explicitly.
```

- [ ] **Step 2: Verify the file parses as a skill**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
head -5 plugins/skillet/skills/explore-issue/SKILL.md
```
Expected: the YAML frontmatter block (`---` … `name: explore-issue` … `---`) prints intact, matching the shape of `plugins/skillet/skills/review-fix/SKILL.md`.

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/explore-issue/SKILL.md
git commit -m "feat(skillet): scaffold explore-issue skill frontmatter"
```
(Do **not** add a `Co-Authored-By` trailer — the repo's `.claude/rules/no-co-authored-by.md` rule blocks it.)

---

## Task 2: Write the workflow body — fetch, worktree, investigate, synthesize

**Files:**
- Modify: `plugins/skillet/skills/explore-issue/SKILL.md` (append after the "When Invoked" section)

- [ ] **Step 1: Append the Workflow steps 1–4**

Append exactly this content to the end of `plugins/skillet/skills/explore-issue/SKILL.md`:

````markdown

## Workflow

### 1. Fetch the issue

Resolve the repo and fetch the issue, including its comments and labels:

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
gh issue view <number> --repo "$REPO" --json number,title,body,labels,comments,url
```

If the issue number is missing or invalid:
- **Interactive** → stop and tell the user, ask for a valid number.
- **Queue (unattended)** → return a `skipped` result with the reason. Do not
  proceed.

Read the title, body, and comments — this is the full statement of the ask.

### 2. Create the worktree (off latest main) — BEFORE writing anything

This is a hard ordering rule: **create the worktree before any file is written.**
Invoke `/create-worktree` with the issue number so it derives a branch from the
issue title and branches off the latest default branch:

```
/create-worktree <number>
```

`/create-worktree` fetches the latest default branch and branches off it, so the
worktree starts from up-to-date code. **All subsequent steps run inside this
worktree.**

If worktree creation fails, abort here. Nothing has been written yet, so there is
nothing to clean up — return a `skipped` result with the reason.

### 3. Investigate with parallel Explore agents

Use the **superpowers:dispatching-parallel-agents** skill to fan out **multiple
read-only Explore subagents concurrently**. Each subagent gets the full issue
context (title + body + relevant comments) plus **one distinct, non-overlapping
search angle** so their work does not overlap.

Pick angles scaled to the issue. Typical angles:

- **Entry points** — where the feature/bug surfaces (routes, commands, UI, CLI).
- **Core logic** — the modules/functions that own the behavior in question.
- **Data & types** — models, schemas, state, config the issue touches.
- **Tests & usages** — existing coverage and call sites that constrain a change.

Scale the **number** of agents to scope: a small, well-localized bug might warrant
2; a broad "should we…" spike, 4–5. Do not hardcode a fixed count — choose based
on the issue.

Each agent should return: relevant `file:line` references, a short description of
what it found, and any gotchas. Agents are **read-only** — they investigate, they
do not edit.

### 4. Synthesize

Merge the agents' findings into one investigation narrative. Do **not** re-explore
inline — synthesize from the returned reports (this keeps the main context clean).

If an agent returned nothing useful, proceed with the others and note the gap.

The synthesis must cover: relevant code, current behavior, the lay of the land /
root cause, options (if a decision is called for), a recommendation, and any open
questions.
````

- [ ] **Step 2: Verify the appended content is well-formed**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
grep -n '^### [1-4]\.' plugins/skillet/skills/explore-issue/SKILL.md
```
Expected: four lines — `### 1. Fetch the issue`, `### 2. Create the worktree...`, `### 3. Investigate...`, `### 4. Synthesize`.

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/explore-issue/SKILL.md
git commit -m "feat(skillet): add fetch/worktree/investigate/synthesize steps to explore-issue"
```

---

## Task 3: Write the workflow body — spec, self-review, PR, comment, return

**Files:**
- Modify: `plugins/skillet/skills/explore-issue/SKILL.md` (append after Task 2's content)

- [ ] **Step 1: Append the Workflow steps 5–8 plus the closing sections**

Append exactly this content to the end of `plugins/skillet/skills/explore-issue/SKILL.md`:

````markdown

### 5. Write the findings spec

Write the synthesized findings to:

```
docs/superpowers/specs/YYYY-MM-DD-<slug>-explore.md
```

`<slug>` is derived from the issue title (lowercase, hyphens, no special chars).
Use today's date. Follow this structure:

```markdown
# Explore: <issue title> (#<n>) — Findings

**Date:** YYYY-MM-DD
**Issue:** <url>
**Branch / PR:** <link>

## The ask
<the issue, restated — what's actually being asked or investigated>

## What we found
<synthesized narrative of current behavior / lay of the land, with file:line cites>

## Relevant code
| Area | Location | Role |
|---|---|---|
| ... | path:line | ... |

## Options
<2–3 approaches with trade-offs, if the issue calls for a decision>

## Recommendation
<the recommended direction with reasoning — or "investigation only, no change recommended">

## Open questions
<every uncertainty the skill could not resolve — since it never asks, these land here>
```

The **Open questions** section is mandatory. Since the skill never asks the user,
this is where every unresolved ambiguity goes — even in interactive mode.

### 5b. Self-review the spec, then commit

Before opening the PR, re-read the spec with fresh eyes and fix issues inline:

1. **Placeholder scan** — no `TBD`/`TODO`/empty section (the `<...>` markers in
   the template above are placeholders to fill, not to leave).
2. **Internal consistency** — sections must not contradict each other.
3. **Unsupported claims** — every cited file / symbol / `file:line` must actually
   exist. The spec was synthesized from subagent reports; verify the citations
   with a quick `Read`/`grep` before committing, so no hallucinated reference is
   committed or posted to the issue.
4. **Ambiguity** — if a finding reads two ways, make it explicit or move the
   uncertainty to Open Questions.
5. **Scope** — keep it focused on the issue.

Then commit on the worktree branch (no `Co-Authored-By` trailer):

```bash
git add docs/superpowers/specs/YYYY-MM-DD-<slug>-explore.md
git commit -m "docs: explore findings for issue #<n>"
```

### 6. Open a draft PR

Invoke `/open-pr` to push the branch and open a **draft** PR linking the issue:

```
/open-pr <number>
```

`/open-pr` always creates the PR in draft mode and adds a `Closes #<n>` line when
an issue is linked. Capture the returned PR URL — it goes in the issue comment and
the returned report.

### 7. Comment on the issue

Post a short summary plus a link to the PR/spec on the issue:

```bash
gh issue comment <number> --repo "$REPO" --body "<summary + PR link + spec path>"
```

If the comment fails (e.g. permissions), do **not** error out — the spec and PR
still exist. Record the failure in the returned report.

### 8. Return a structured result

Return a structured result so `/drain-queue` can consume it the same way as its
other subagent results:

- `done` — include the PR URL, the spec path, and a one-line summary.
- `skipped` — include the reason (used for the bad-issue and worktree-failure
  paths above).

## Routing contract (queue integration)

`/drain-queue` distinguishes explore issues by **GitHub label**: an issue labeled
`explore` is routed to this skill instead of the normal implement-it path.

> **Pending separate work:** the actual `/drain-queue` edit that performs this
> routing is handled separately and is **not** part of this skill. This section
> documents the contract the queue relies on.

## Never stall

This skill never asks the user to resolve ambiguity — interactive or unattended.
Every uncertainty is recorded in the spec's **Open Questions** section and the
skill proceeds. This keeps interactive and queue behavior identical and guarantees
the autonomous queue never idles.

## Notes

- This skill deep-dives **one** issue. It does not triage or browse multiple
  issues.
- It **investigates and recommends**; it does not write application code.
- Explore subagents are **read-only**.
- Never add a `Co-Authored-By` trailer to commits (repo rule).
````

- [ ] **Step 2: Verify all workflow sections are present and ordered**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
grep -nE '^(### [0-9]|## )' plugins/skillet/skills/explore-issue/SKILL.md
```
Expected (in order): `## Explore Issue Skill`-area headings, then `## Workflow`, `### 1.`–`### 8.` (with `### 5b.` between 5 and 6), then `## Routing contract`, `## Never stall`, `## Notes`.

- [ ] **Step 3: Verify the never-stall and worktree-first rules are stated**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
grep -in "never asks" plugins/skillet/skills/explore-issue/SKILL.md
grep -in "BEFORE writing anything" plugins/skillet/skills/explore-issue/SKILL.md
```
Expected: at least one hit each — confirms the two load-bearing guarantees from the spec are documented.

- [ ] **Step 4: Commit**

```bash
git add plugins/skillet/skills/explore-issue/SKILL.md
git commit -m "feat(skillet): add spec/self-review/PR/comment/return steps to explore-issue"
```

---

## Task 4: Update the README index and verify end-to-end

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the skill to the README index table**

Open `README.md`. In the `## Skills` table (the rows beginning `| \`/open-pr\` |` …), add this row immediately after the `/review-fix` row:

```markdown
| `/explore-issue` | Deep-dive one GitHub issue: worktree off main, parallel Explore agents, findings spec, draft PR, and an issue comment. Routed by the `explore` label. |
```

Also add the new skill to the `## Layout` tree block — under `skills/`, add a line after `review-fix/SKILL.md`:

```
    ├── review-fix/SKILL.md
    └── explore-issue/SKILL.md
```
(Adjust the box-drawing characters so the last entry uses `└──` and the entry above it uses `├──`.)

- [ ] **Step 2: Verify the README references the new skill**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
grep -n "explore-issue" README.md
```
Expected: at least two hits — the index table row and the layout tree entry.

- [ ] **Step 3: Run the repo's existing test suite (sanity — must still pass)**

Run:
```bash
cd "$(git rev-parse --show-toplevel)"
npm test
```
Expected: PASS. (These tests cover `scripts/*.mjs`, not the skill, but confirm the change broke nothing.)

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add explore-issue to the skill index"
```

- [ ] **Step 5: Manual end-to-end verification**

This is the real test of the skill (it is a prose procedure, not unit-testable). On a real `explore`-labeled issue, run `/explore-issue <n>` and confirm, in order:

1. The worktree is created off latest main **before any file is written**.
2. Parallel read-only Explore agents are dispatched.
3. The findings spec is written with **all** sections populated (no placeholders).
4. The self-review verifies citations (every `file:line` exists).
5. A **draft** PR is opened and linked to the issue.
6. An issue comment is posted with the PR/spec link.
7. A structured `done` result is returned (PR URL + spec path + summary).

Then run the **skip path**: invoke with a bad issue number and confirm a clean
`skipped` result with no leftover worktree or spec.

Record the outcome. If anything diverges, file follow-up before marking done.

---

## Self-Review

**Spec coverage** — every spec section maps to a task:

| Spec section | Covered by |
|---|---|
| Interface (issue-number arg; interactive vs queue) | Task 1 Step 1 ("When Invoked") |
| Worktree off latest main, before any write | Task 2 Step 1 (Workflow §2) |
| Parallel Explore agents, scaled, distinct angles | Task 2 Step 1 (Workflow §3) |
| Synthesize (not inline), note gaps | Task 2 Step 1 (Workflow §4) |
| Spec document + structure | Task 3 Step 1 (Workflow §5) |
| Spec self-review (incl. unsupported-citation check) | Task 3 Step 1 (Workflow §5b) |
| Draft PR via /open-pr | Task 3 Step 1 (Workflow §6) |
| Issue comment; tolerate comment failure | Task 3 Step 1 (Workflow §7) |
| Structured return (done/skipped) | Task 3 Step 1 (Workflow §8) |
| Routing by `explore` label (documented, deferred wiring) | Task 3 Step 1 (Routing contract) |
| Never-stall → Open Questions | Task 1 + Task 3 (intro + Never stall + §5) |
| Error handling (bad issue, worktree fail, agent empty, comment fail) | Task 2 §1/§2, Task 3 §4/§7/§8 |
| Testing (manual e2e + skip path) | Task 4 Step 5 |
| README discoverability | Task 4 Steps 1–2 |

No gaps.

**Placeholder scan** — the only `<...>`/`YYYY-MM-DD`/`TODO`-looking tokens are
**inside the skill's own template content** (the spec template the skill writes,
and `<number>`/`<n>` argument placeholders in shell snippets), which are
intentional literal content of the skill file — not unfilled plan placeholders.
No plan step is left as "TBD" or "implement later".

**Type/name consistency** — the skill file path
(`plugins/skillet/skills/explore-issue/SKILL.md`) and the skill name
(`explore-issue`), the `explore` label, the `done`/`skipped` result shape, the
spec path pattern (`docs/superpowers/specs/YYYY-MM-DD-<slug>-explore.md`), and the
section numbering (`### 1.`–`### 8.` + `### 5b.`) are used identically across all
tasks and the verification greps.
