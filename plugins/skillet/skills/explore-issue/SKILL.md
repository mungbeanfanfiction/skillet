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
