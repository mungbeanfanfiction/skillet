# Design: `/triage-issue` — first-pass triage of an existing GitHub issue

**Date:** 2026-06-23
**Status:** Design (pending implementation plan)
**Repo:** skillet (personal Claude Code skill marketplace)

## Problem

`/create-issue` files well-formed, fully-labeled issues from conversation
context. But issues also arrive from elsewhere — filed by hand, by other people,
or by tools — and those are often thin: a one-line title, no labels, no priority,
no structure. The autonomous queue (`/drain-queue`) can only pick up an issue
once it carries the `auto` label and enough structure to act on; an un-triaged
issue just sits there.

What's missing is the **inverse of `create-issue`**: take an issue that already
exists and bring it up to the same bar — assess it, enrich a thin body, apply the
canonical labels, set a milestone where derivable, and (rarely) break a too-big
issue into an epic plus sub-issues. This is a **first-pass** triage: it makes an
issue actionable and routable, but it does **not** do deep codebase
investigation — that is `/explore-issue`'s job.

## Solution overview

One new skill in `plugins/skillet/skills/`, following the existing prose
`SKILL.md` pattern: **`/triage-issue`**. Plus two small supporting changes
(milestone support in `/create-issue`, and an `epic` label in the shared label
set).

Given an issue number, `/triage-issue`:

1. Fetches the issue (title, body, comments, labels, milestone).
2. Creates an isolated worktree off **latest main** via `/create-worktree`,
   **before writing any files**.
3. **Routes explore-type issues** straight to labeling and stops (hands the deep
   work to `/explore-issue`).
4. For everything else: assesses robustness, enriches a thin body
   (non-destructively), and — only when clearly warranted — decomposes into an
   epic + sub-issues.
5. Applies canonical labels (always including `auto`), creating any missing ones.
6. Sets a milestone where derivable. **Never sets an assignee.**
7. Posts a triage-summary comment on the issue.

It is **fully autonomous** — like `/create-issue`, it never asks for
confirmation. Uncertainties it cannot resolve are recorded in an
`## Open Questions` section of the enriched body rather than blocking on a prompt.

## Autonomy & dual invocation

Mirrors the `/create-issue` + `/explore-issue` conventions:

- **Argument:** a GitHub issue number.
- **Queue (unattended):** the number is passed explicitly.
- **Interactive, omitted:** infer the issue number from the current branch name
  (leading number, or `issue-<n>` / `<n>-...` pattern), the way `review-fix` and
  `explore-issue` do. If none can be inferred, that is the one permitted
  exception to the no-prompting rule: ask which issue to triage.
- **Invalid / missing number:** interactive → stop and ask; queue → return a
  `skipped` result with the reason, write nothing.

No confirmation gate anywhere else. The skill edits the issue destructively
(labels, body, milestone, comments, child issues) without review — accepted
tradeoff for queue compatibility, mitigated by the non-destructive body rule
below.

## Workflow

### 1. Preflight

```bash
gh auth status                                            # must succeed
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
gh issue view <number> --repo "$REPO" \
  --json number,title,body,labels,comments,milestone,url
```

If `gh` is unauthenticated or no repo resolves, stop (interactive) / skip
(queue). Read title + body + comments — that's the full statement of the ask.

### 2. Create the worktree (off latest main) — BEFORE writing anything

Hard ordering rule, matching `explore-issue`: create the worktree before any file
is written.

```
/create-worktree <number> --noninteractive
```

All subsequent file writes happen inside this worktree. If worktree creation
fails, abort — nothing has been written, so there is nothing to clean up; return
a `skipped` result with the reason.

> Note: in practice most of `/triage-issue`'s effects are GitHub-side (labels,
> body, comments, child issues) rather than repo files. The worktree exists to
> satisfy the "isolate any file writes" convention and to give the run a clean,
> up-to-date branch context; it will usually end empty.

### 3. Assess

A **first-pass** judgment only — no codebase investigation, no Explore agents:

- **Work type:** which canonical type best fits (`explore` / `feature` / `bug` /
  `chore` / `refactor`).
- **Robustness:** is the body already structured and actionable, or thin?
- **Size:** does it clearly span multiple independent units of work?

### 4. Route explore-type issues, then stop

If the assessed type is `explore`:

- Apply labels `explore` + `auto` + any clear area + a priority.
- Create any missing labels (step 7 rules).
- Set a milestone if derivable (step 8).
- Post the triage comment (step 9) noting it is routed to `/explore-issue`.
- **Stop.** Do **not** enrich the body or decompose — that is `/explore-issue`'s
  responsibility.

### 5. Enrich the body (non-destructive) — non-explore only

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

### 6. Decompose into epic + sub-issues — only when clearly warranted

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

### 7. Apply canonical labels

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

### 8. Set a milestone — no assignee

If a milestone is clearly derivable (e.g. the issue references a release/target,
or there is an obvious current/open milestone it belongs to), set it:

```bash
gh issue edit <number> --repo "$REPO" --milestone "<title>"
```

If no milestone clearly applies, omit it — do not guess. **Never set an
assignee.**

### 9. Post a triage summary comment

Comment on the issue summarizing the triage decision so there's an audit trail:

- Assessed type + the labels applied (and why, briefly).
- Whether the body was enriched.
- Decomposition result, with links to any child issues (or "not decomposed").
- Milestone set (or "none").
- For explore issues: note routing to `/explore-issue`.

```bash
gh issue comment <number> --repo "$REPO" --body-file <file>
```

### 10. Return a structured result

For queue compatibility, return a structured result describing the outcome:
`triaged` / `routed-explore` / `decomposed` / `skipped` (+ reason), the labels
applied, milestone, and child-issue numbers.

## Supporting changes

### `create-issue` — add milestone support

Add a milestone step to `/create-issue` mirroring step 8 above: set a milestone
when clearly derivable from the conversation, otherwise omit. Update its existing
"do not add assignees, milestones, or projects" rule to "do not add assignees or
projects" (milestones now allowed). No other behavior change.

### `labels.json` — add the `epic` label

Add one entry, with a color distinct from all existing entries:

```json
{ "name": "epic", "color": "c2e0c6", "description": "Parent issue tracking sub-issues" }
```

`sync-repo-labels`, `create-issue`, and `triage-issue` all read this file, so the
new label propagates automatically — no other edits to those skills needed for
the label itself.

## Files touched

| File | Change |
|------|--------|
| `plugins/skillet/skills/triage-issue/SKILL.md` | New skill (prose `SKILL.md`). |
| `plugins/skillet/skills/_shared/labels.json` | Add the `epic` label. |
| `plugins/skillet/skills/create-issue/SKILL.md` | Add milestone step; relax the "do not" rule. |
| `README.md` | Add `/triage-issue` to the skills list (match existing format). |

The marketplace manifest auto-discovers skills from the directory, so no manifest
edit is required.

## Non-goals

- **Deep codebase investigation** — owned by `/explore-issue`.
- **Setting assignees** — explicitly excluded.
- **Closing, reopening, or otherwise changing issue state** — triage only
  enriches and labels.
- **Touching labels outside the canonical set.**
- **Aggressive decomposition** — splitting is the rare exception, not the norm.

## Open questions

- None outstanding; resolved during brainstorming (autonomy = fully autonomous;
  body = preserve+append; decomposition = epic + child issues, only when
  warranted; explore = label-only routing; milestones yes, assignees no).
