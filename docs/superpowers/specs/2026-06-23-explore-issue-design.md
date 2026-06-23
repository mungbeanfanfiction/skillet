# Design: `/explore-issue` — deep-dive a GitHub issue

**Date:** 2026-06-23
**Status:** Design (pending implementation plan)
**Repo:** skillet (personal Claude Code skill marketplace)

## Problem

The autonomous task queue (`/drain-queue`, see
`2026-05-29-autonomous-queue-design.md`) auto-pulls GitHub issues and works each
one end-to-end. But not every issue is a "implement this" task. Some are
open-ended: *investigate why X happens*, *should we adopt Y*, *what would it take
to Z*. Sending those straight into the implement-it pipeline produces noise — the
agent guesses at a change instead of doing the investigation the issue actually
asks for.

What's missing is a dedicated **explore deep-dive** step: take one issue,
investigate it thoroughly against the codebase, and produce a durable findings
spec — without writing application code. The queue should be able to recognize an
"explore" issue and route it to this skill automatically, and a human should be
able to invoke the same skill interactively.

## Solution overview

One new skill in `plugins/skillet/skills/`, following the existing prose
`SKILL.md` pattern: **`/explore-issue`**.

Given an issue number, it:

1. Fetches the issue.
2. Creates an isolated worktree off **latest main** via `/create-worktree`,
   **before writing anything**.
3. Fans out parallel read-only **Explore** subagents to investigate the codebase.
4. Synthesizes their findings into one investigation narrative.
5. Writes a findings spec to `docs/superpowers/specs/`.
6. Self-reviews the spec, then commits it.
7. Opens a **draft PR** via `/open-pr`, linking the issue.
8. Posts a summary **comment** on the issue linking to the PR/spec.
9. Returns a **structured result** to its caller.

It reuses existing building blocks: `/create-worktree`, `/open-pr`, the
superpowers `dispatching-parallel-agents` skill, and `gh`.

### Routing contract (the queue integration)

`/drain-queue` distinguishes explore issues by **GitHub label**: an issue labeled
`explore` routes to `/explore-issue` instead of the normal implement-it path.

This spec **documents** that contract so both sides agree on it, but the actual
edit to `/drain-queue` is **deferred — see "Pending separate work" at the end.**

## Interface

- **Argument:** a GitHub issue number.
  - Interactive, omitted → ask which issue.
  - Queue → always passed explicitly.
- **Never stalls:** the skill **never asks the user** to resolve ambiguity, even
  interactively. Every uncertainty it cannot resolve is recorded in an **Open
  Questions** section of the spec and it proceeds. This keeps interactive and
  unattended (queue) behavior identical and guarantees the queue never idles.

## Workflow / data flow

```
/explore-issue <number>   (interactive, or auto-called by /drain-queue on an `explore`-labeled issue)
  │
  1. Fetch issue        → gh issue view <n> --json number,title,body,labels,comments,url
  │
  2. Create worktree    → /create-worktree off LATEST main, BEFORE writing anything.
  │                        Branch derived from the issue title. All subsequent
  │                        steps run inside this worktree.
  │
  3. Investigate        → fan out parallel read-only Explore subagents via
  │                        superpowers:dispatching-parallel-agents. Each gets the
  │                        full issue context plus a distinct, non-overlapping
  │                        search angle.
  │
  4. Synthesize         → merge agent findings into one narrative: relevant code,
  │                        current behavior, lay of the land / root cause, options,
  │                        recommendation, open questions.
  │
  5. Write spec         → docs/superpowers/specs/YYYY-MM-DD-<slug>-explore.md
  │
  5b. Self-review spec  → fresh-eyes pass (see "Spec self-review"). Fix inline.
  │                        Then commit on the worktree branch.
  │
  6. Open draft PR      → /open-pr (draft, links the issue).
  │
  7. Comment on issue   → gh issue comment <n> — short summary + link to the PR/spec.
  │
  8. Return report      → structured result to the caller (queue or user).
```

**Ordering constraint:** the worktree is created **first**, off latest main,
before any file is written. Exploration runs *inside* the worktree so subagents
read the freshly-branched tree (consistent with latest main), and the spec is
written and committed on the worktree branch.

## Component: parallel Explore investigation

The skill dispatches **multiple read-only Explore subagents concurrently** (via
`superpowers:dispatching-parallel-agents`). Each subagent receives the full issue
context plus a **distinct angle** so their searches don't overlap. Typical angles,
scaled to the issue:

- **Entry points** — where the feature/bug surfaces (routes, commands, UI, CLI).
- **Core logic** — the modules/functions that own the behavior in question.
- **Data & types** — models, schemas, state, config the issue touches.
- **Tests & usages** — existing coverage and call sites that constrain a change.

Each agent returns: relevant `file:line` references, a short description of what
it found, and any gotchas. The main skill **synthesizes** — it does not re-explore
inline, which keeps the main context clean and fits the queue's parallel model.

The **number of agents scales to issue scope** — a small, well-localized bug might
warrant 2; a broad "should we…" spike, 4–5. The skill describes how to pick
angles rather than hardcoding a fixed set.

If an agent returns nothing useful, synthesis proceeds with the others and notes
the gap.

## Component: spec document

Written to `docs/superpowers/specs/YYYY-MM-DD-<slug>-explore.md`, following the
house spec format:

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

The **Open Questions** section is mandatory; it is where the never-stall behavior
deposits anything ambiguous.

## Spec self-review (step 5b)

Before opening the PR, the skill re-reads the spec with fresh eyes:

1. **Placeholder scan** — any `TBD`/`TODO`/empty section? Fill it.
2. **Internal consistency** — do sections contradict each other?
3. **Unsupported claims** — every cited file / symbol / `file:line` must actually
   exist. Because the spec is synthesized from subagent reports, this guards
   against hallucinated citations *before* they are committed and posted to the
   issue.
4. **Ambiguity** — could a finding be read two ways? Make it explicit, or move
   the uncertainty to Open Questions.
5. **Scope** — is the spec focused, or sprawling beyond the issue?

Fix issues inline; no second review pass needed.

## Outputs

- **Spec file** — committed on the worktree branch.
- **Draft PR** — via `/open-pr`, links the issue.
- **Issue comment** — via `gh issue comment`, a short summary + link to the
  PR/spec.
- **Returned report** — a structured result so `/drain-queue` can consume it the
  same way it consumes its other subagent results:
  - `done` — with PR link + spec path + one-line summary, or
  - `skipped` — with a reason.

## Error handling

- **No issue / bad number** → fail clearly (interactive) or return `skipped` with
  reason (queue).
- **Worktree creation fails** → abort **before writing anything**; return
  `skipped`. (Nothing has been written yet at this point.)
- **An Explore agent returns nothing** → synthesis proceeds with the others; note
  the gap in the spec.
- **`gh` comment fails** (e.g. permissions) → the spec + PR still exist; record
  the failure in the returned report rather than erroring out.

## Testing

- **Manual end-to-end** — run `/explore-issue <n>` against a real `explore`-labeled
  issue and confirm, in order:
  - worktree created off latest main, before any write;
  - parallel Explore agents dispatched;
  - spec written with all sections populated (no placeholders);
  - self-review caught/confirmed citations;
  - draft PR opened and linked to the issue;
  - issue comment posted with PR/spec link;
  - structured `done` result returned.
- **Skip path** — invoke with a bad issue number; confirm a clean `skipped`
  result and that no worktree/spec is left behind.

## Components & dependencies

| Component        | Role                                       | Depends on |
|------------------|--------------------------------------------|------------|
| `/explore-issue` | Deep-dive one issue → findings spec + PR   | `/create-worktree`, `/open-pr`, `dispatching-parallel-agents`, `gh` |

## Out of scope (YAGNI)

- **Triage / browsing** multiple issues — this skill deep-dives **one** issue.
- **Implementation** — it investigates and recommends; it does not write
  application code.
- **Non-label routing** (title/body keyword heuristics) — routing is by the
  `explore` label only.
- **`ultra` cloud review** inside the flow — billed + user-triggered.

## Pending separate work

- **`/drain-queue` label routing** — wiring the queue to check for the `explore`
  label and dispatch `/explore-issue` is being handled **separately** and is
  **not** part of this change. This spec only documents the contract the queue
  will rely on. **Status: waiting on that separate work.**

## Open questions

None. Pending design approval.
