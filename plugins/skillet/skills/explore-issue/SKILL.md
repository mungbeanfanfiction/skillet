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

- **Queue** → the number is always passed explicitly.
- **Interactive, omitted** → infer the issue from the current branch name
  (e.g. a leading number, or an `issue-<n>` / `<n>-...` pattern) the way
  `review-fix` infers a PR. If no issue can be inferred, that is the one
  permitted exception to the no-prompting rule: ask the user which issue to
  explore.

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
/create-worktree <number> --yes
```

`/create-worktree` fetches the latest default branch and branches off it, so the
worktree starts from up-to-date code. The `--yes` flag runs it non-interactively
(no confirmation prompts), which is required for unattended queue runs. **All
subsequent steps run inside this worktree.**

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

### 5. Write the findings spec

Write the synthesized findings to:

```
docs/superpowers/specs/YYYY-MM-DD-<slug>-explore.md
```

`<slug>` is derived from the issue title (lowercase, hyphens, no special chars).
Use today's date. Create the `docs/superpowers/specs/` directory first if it does
not already exist. Follow this structure:

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
/open-pr <number> --yes
```

`/open-pr` always creates the PR in draft mode and adds a `Closes #<n>` line when
an issue is linked. The `--yes` flag runs it non-interactively (no confirmation
prompt). Capture the returned PR URL — it goes in the issue comment and the
returned report.

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
