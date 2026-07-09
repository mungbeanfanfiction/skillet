---
name: triage-issue
description: First-pass triage of an existing GitHub issue — assess it, enrich a thin body non-destructively, apply canonical labels (always including `auto`), set a milestone where derivable, and post a triage-summary comment. The inverse of `/create-issue`. Fully autonomous; does NOT do deep codebase investigation (that's `/explore-issue`). Use when an existing issue needs to be made actionable so `/issue-supervisor` can pick it up, or when running triage by hand on an un-triaged issue.
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

- **Queue (unattended)** → `/issue-supervisor` passes the number explicitly.
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
  line and carrying its own canonical labels (incl. `auto`) — the children are
  what `/issue-supervisor` dispatches.
- The epic itself carries `epic` and **drops `auto`** — a decomposed parent is
  tracking-only and must not be dispatched directly. Its own type/area/priority
  reflect the overall effort.

### 6. Apply canonical labels

Label taxonomy lives in `../_shared/labels.json` (read before labeling):

- **Queue:** include `auto` — except a decomposed **epic** parent, which carries
  `epic` and **omits `auto`** (it is tracking-only; its children carry `auto`).
- **Type:** exactly one (`explore` / `feature` / `bug` / `chore` / `refactor`),
  plus `epic` when the issue was decomposed. **Alias:** if the repo already has
  an `enhancement` label, apply it in place of `feature` — don't create a
  competing type label.
- **Area:** zero or more of `frontend` / `backend` / `database` it clearly
  touches.
- **Priority:** exactly one; `p0` only for urgent/blocking, `p1` high, default
  `p2` — except a `bug`, which defaults to `p1`, since it means something is
  already broken. A bug the issue clearly describes as minor or cosmetic may
  still be set to `p2`.

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
