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
