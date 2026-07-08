# Explore: Add a /cleanup-issues skill to close/de-queue stale GitHub issues (#65) — Findings

**Date:** 2026-07-08
**Issue:** https://github.com/mungbeanfanfiction/skillet/issues/65
**Branch / PR:** `auto-65-cleanup-issues-skill` — draft PR opened by this exploration (see issue comment for link).

## The ask

There is a `/cleanup-worktrees` skill for tidying stale git worktrees, but no
equivalent for tidying stale GitHub **issues**. Issues linger in states the
autonomous queue no longer needs to see:

1. An issue whose linked PR is **merged** but which wasn't auto-closed (the PR
   didn't use a `Fixes #N` / `Closes #N` keyword, so GitHub never closed it) →
   candidate to **close** (with a comment linking the PR).
2. An **open** issue still carrying the `auto` label after its work shipped, so
   `/issue-supervisor` keeps considering it → candidate to **de-queue** (drop the
   `auto` label) rather than close.
3. A **closed** issue still labeled `auto` (the label just never got removed) →
   candidate to drop `auto` for tidiness.

The ask is to **design and add** a `/cleanup-issues` skill under
`plugins/skillet/skills/` that surveys open (and, for signal 3, closed) issues,
classifies them into the same 🟢/🟡/🟠/🔴 safety buckets `/cleanup-worktrees`
uses, and — interactive by default, `--noninteractive` for unattended callers
acting only on the 🟢 bucket — closes or de-queues the safe ones. It must be
additive and non-destructive: never delete issues, never touch issues outside the
detected signals. The issue also asks us to **decide during exploration whether
close-on-merged-PR and de-queue-stale-`auto` should be one skill or two.**

## What we found

### This is greenfield: no skill closes issues today

Across `plugins/skillet/skills/`, **no skill runs `gh issue close`**, and **no
skill reads issue→PR linkage** (`closingIssuesReferences` /
`closedByPullRequestsReferences`). `/cleanup-issues` would be the first. Every
building block it needs, however, already has prior art to copy verbatim, so it is
an assembly job, not novel infrastructure:

- **Repo resolve** — `REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')`
  is used identically in `update-issue`, `triage-issue`, `explore-issue`,
  `cleanup-worktrees` (`plugins/skillet/skills/cleanup-worktrees/SKILL.md:40`).
- **Survey open issues** — `issue-supervisor/scripts/survey.sh:13` runs
  `gh issue list --repo "$REPO" --state open --limit 100 --json number,labels`.
- **De-queue (drop a label without closing)** — `question-sweeper/SKILL.md:33`
  runs `gh issue edit <issue> --remove-label needs-input`; the same
  `--remove-label auto` is exactly the "de-queue" primitive the issue wants. The
  supervisor itself already drops `auto` from decomposed epic parents
  (`triage-issue/SKILL.md:144-146`, `issue-supervisor/SKILL.md:117-118`).
- **Comment** — `update-issue/SKILL.md:86-89` uses `gh issue comment <n> --repo
  "$REPO" --body-file "$BODY_FILE"` for multi-line bodies.

### The `/cleanup-worktrees` skill is the structural template

`/cleanup-worktrees` is the batch-survey skill `/cleanup-issues` should mirror
almost section-for-section (`plugins/skillet/skills/cleanup-worktrees/SKILL.md`):

- **Four buckets, not three** (`cleanup-worktrees/SKILL.md:77-82`, verbatim):
  - 🟢 Safe to remove — clean, pushed, AND (branch merged OR PR merged)
  - 🟡 Likely safe — clean, pushed, PR closed (not merged)
  - 🟠 Open PR — clean, has open PR — probably keep
  - 🔴 Has work — dirty OR unpushed → never auto-suggest removal
- **`--noninteractive` acts only on 🟢** (`cleanup-worktrees/SKILL.md:14-22,107-109`):
  "removes the interactive confirmation, not the classification gate; nothing
  dirty, unpushed, or unmerged is ever removed." 🟡 is deliberately excluded even
  from noninteractive because "a closed-but-unmerged PR can still hold work worth
  a human glance."
- **Presentation** is an emoji-prefixed table (PATH / BRANCH / STATUS) with a
  human-readable STATUS reason (`cleanup-worktrees/SKILL.md:86-95`).
- **Interactive menu** (`cleanup-worktrees/SKILL.md:97-105`): Remove all 🟢 /
  Remove all 🟢+🟡 / Pick individually / Cancel.
- **Section skeleton**: `# <Name> Skill` → one-line purpose + default-safety
  sentence → `### Autonomous mode (\`--noninteractive\`)` **before** `## Workflow`
  → numbered `### N. <verb>` steps each anchored by a fenced bash block → closing
  `## Notes` list of "does NOT" guarantees + a `gh`-not-authenticated fallback.
- **Frontmatter**: `name`, `description` (verb-first, mentions the
  `--noninteractive` unattended mode, ends with a "Use when …" trigger),
  `argument-hint: "[--noninteractive]"`.

### Detecting a merged-but-open issue: use `closedByPullRequestsReferences`

The issue's premise ("via `closingIssuesReferences`") is slightly off, and the
correction is load-bearing:

- `gh issue view/list --json closingIssuesReferences` **errors** —
  `closingIssuesReferences` is a **PR-only** field. Verified: `gh issue view 65
  --json closingIssuesReferences` → `Unknown JSON field`.
- The right field **does** live on issues: **`closedByPullRequestsReferences`**,
  available on both `gh issue view` and `gh issue list`. GitHub has already
  computed the closing-keyword *and* sidebar-linked PR set — no body-parsing, no
  GraphQL needed for the common case.

**Critical gotcha (mandatory two-step check):**
`closedByPullRequestsReferences` lists linked PRs **regardless of their state**,
and each entry carries only `{id, number, repository, url}` — no merge info. So
detection is: (1) list open issues that have any linked PR, then (2) look up each
linked PR's `state` and keep only issues with a **MERGED** one. Proven on live
data: open issue **#63** has linked PR **#69**, but #69 is still `OPEN` — a naive
one-step check would wrongly flag #63 for closing. There is **no `merged` boolean**
on PRs in this `gh` version; use `state == "MERGED"` (equivalently `mergedAt != null`).

Verified detection query (drop-in), run live against this repo:

```bash
gh issue list --repo "$REPO" --state open --limit 200 \
  --json number,title,labels,closedByPullRequestsReferences \
  --jq '.[] | select(.closedByPullRequestsReferences | length > 0)
        | {number, title, labels:[.labels[].name],
           prs:[.closedByPullRequestsReferences[].number]}'
# then, per linked PR:
gh pr view <pr> --repo "$REPO" --json state --jq .state   # keep iff "MERGED"
```

A GraphQL `timelineItems` query over `CrossReferencedEvent` also works and was
verified (issue #59 → merged PR #67), and is the fallback for cross-repo links or
to batch the per-PR lookups into one call — but for a same-repo sweep the
`closedByPullRequestsReferences` + per-PR-`state` path is simpler and sufficient.
The `gh pr list --search "N in:body"` route is a text match (misses
sidebar-linked PRs, catches non-closing mentions) and should not be the primary
signal.

### Current repo state (concrete grounding, 2026-07-08)

- 10 open issues; those carrying `auto`: **#65, #64, #63, #60, #57, #37, #6**.
- Open issues with a linked PR: **#63→#69 (OPEN)**, **#57→#62**, **#37→#43**,
  **#6→#68**.
- **Zero** open issues currently have a *merged* linked PR — the merged-PR issues
  the original session worried about (#47, #48, #51, #56, #52) were already
  auto-closed via `Fixes #N`. So the immediate 🟢 population is empty today; the
  skill's value is ongoing hygiene, exactly as the issue notes.

### The `auto` label and de-queuing

`auto` is the queue gate. `issue-supervisor/lib/supervisorlib/gh.py` dispatches an
issue iff it is open, carries `auto`, lacks `epic`, and isn't already owned. The
canonical label set is the single source of truth at
`plugins/skillet/skills/_shared/labels.json` (queue `auto`; type
explore/feature/bug/chore/refactor; area frontend/backend/database; priority
p0/p1/p2; lifecycle epic/loop-generated/needs-input). Dropping `auto` via
`gh issue edit <n> --remove-label auto` removes an issue from the queue without
closing it — the established de-queue mechanism.

### Packaging: what a new skill touches

- **Required:** `plugins/skillet/skills/cleanup-issues/SKILL.md` (only mandatory
  file). Skills are **auto-discovered** — no manifest edit. `marketplace.json` and
  `plugin.json` list no skills; their `version` fields are owned by
  semantic-release (`scripts/set-version.mjs`) and must not be hand-edited.
- **Expected by convention** (every prior skill did both, though unenforced):
  add a row to the `README.md` Skills table (~`README.md:14-32`) and an entry to
  the Layout tree (~`README.md:43-78`); optionally add this spec (and a plan)
  under `docs/superpowers/`.
- **Commit** with a `feat:` conventional-commit message (a new skill is a
  feature → minor bump); **no `Co-Authored-By` trailer** (repo rule).
- **No skill-frontmatter lint / CI** exists; the only workflow is release.

## Relevant code

| Area | Location | Role |
|---|---|---|
| Structural template (buckets, modes, menu, table) | `plugins/skillet/skills/cleanup-worktrees/SKILL.md:14-140` | The skill to mirror section-for-section |
| Single-target safety-gate pattern | `plugins/skillet/skills/delete-worktree/SKILL.md:19-33` | `--noninteractive` = drop prompt, keep gate |
| Open-issue survey idiom | `plugins/skillet/skills/issue-supervisor/scripts/survey.sh:13` | `gh issue list --state open --limit 100 --json …` |
| De-queue primitive | `plugins/skillet/skills/question-sweeper/SKILL.md:33` | `gh issue edit <n> --remove-label <label>` |
| Multi-line comment idiom | `plugins/skillet/skills/update-issue/SKILL.md:86-89` | `gh issue comment --body-file "$BODY_FILE"` |
| Queue eligibility logic | `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/gh.py:19-27` | `auto` present, `epic` absent, not owned |
| Canonical labels | `plugins/skillet/skills/_shared/labels.json` | Source of truth for `auto` etc. |
| GraphQL timeline template (fallback) | `plugins/skillet/skills/pr-fleet-manager/SKILL.md:103-118` | Model for a `timelineItems` query if needed |
| Skill packaging / auto-discovery | `.claude-plugin/marketplace.json`, `plugins/skillet/plugin.json` | No per-skill registration required |

## Options

**Q from the issue: one skill or two?** (close-on-merged-PR vs de-queue-stale-`auto`)

**Option A — one `/cleanup-issues` skill (RECOMMENDED).**
A single survey pass reads `gh issue list … --json number,title,labels,
closedByPullRequestsReferences` once and derives all signals from it, classifying
each issue into a bucket with a per-issue *action* (close vs de-queue). The two
actions share the entire survey, classification, presentation, and mode-handling
scaffolding; splitting them would duplicate all of it.
- *Pros:* one survey/one table/one menu; mirrors `/cleanup-worktrees` (which also
  performs two distinct actions — remove worktree AND delete branch — inside one
  skill); one thing for `/issue-supervisor` to call; matches the issue title.
- *Cons:* the SKILL.md must clearly document that a bucket maps to different
  *actions* (🟢-close vs de-queue), which is marginally more explaining.

**Option B — two skills (`/close-shipped-issues` + `/dequeue-stale-auto`).**
- *Pros:* each has a single action; simplest per-skill mental model.
- *Cons:* duplicated survey + classification + mode plumbing; two things to wire
  into the supervisor; diverges from the issue's framing and from the
  `/cleanup-worktrees` precedent of multi-action-in-one-skill; a shipped-but-open
  `auto` issue naturally wants *both* actions (close it → the `auto` label goes
  with it), which two skills would awkwardly split.

### Proposed bucket → action mapping (Option A)

Mapping the worktree buckets onto issue signals. "Provably safe" (🟢) is the only
bucket `--noninteractive` touches.

| Bucket | Signal | Action |
|---|---|---|
| 🟢 Safe | **open** issue whose linked PR is **MERGED** | **Close** with a comment linking the PR (`--reason completed`). If it still has `auto`, closing removes it from the queue inherently. |
| 🟢 Safe | **closed** issue still labeled `auto` | **De-queue**: `--remove-label auto` (pure tidiness, no state change). |
| 🟡 Likely | **open** issue whose linked PR is **CLOSED (not merged)** | Present, don't auto-act — the work may be abandoned or superseded; needs a human glance. |
| 🟠 Keep | **open** issue with an **OPEN** linked PR, or open `auto` issue with no linked PR | Keep — work is in flight or not yet started. Never acted on. |
| 🔴 Keep | anything with signals of active/ambiguous work (recent activity, assignee, `p0`, duplicate/superseded that needs judgment) | Never auto-suggest; report only. |

Notes on edges:
- "**open `auto` issue whose work has clearly shipped**" (acceptance criterion 3):
  the *reliable* signal for "shipped" is a MERGED linked PR — which is already the
  🟢-close case above (closing de-queues it). An `auto` issue with **no** merged
  PR has no machine-provable "shipped" signal, so it stays 🟠 (never
  auto-de-queued) — this directly satisfies "without closing issues that still
  have open work."
- **Duplicate/superseded** issues (mentioned in the issue context) have no
  reliable machine signal → 🔴/report-only, surfaced for a human, never
  auto-closed.

## Recommendation

**Build one `/cleanup-issues` skill (Option A)**, structured as a near-clone of
`/cleanup-worktrees`:

1. Frontmatter: `name: cleanup-issues`; description verb-first, notes the
   `--noninteractive` unattended mode for `/issue-supervisor`, ends with a "Use
   when …" trigger; `argument-hint: "[--noninteractive]"`.
2. `### Autonomous mode (\`--noninteractive\`)` block before `## Workflow`, stating
   it acts on the 🟢 bucket only and skips/reports everything else.
3. Workflow steps: **(1)** resolve repo + preflight `gh auth status`; **(2)** survey
   `gh issue list --state open --limit 200 --json number,title,labels,
   closedByPullRequestsReferences` (plus a `--state closed --label auto` pass for
   the closed-still-`auto` signal); **(3)** classify into 🟢/🟡/🟠/🔴 using the
   **mandatory two-step** merged-PR check (per-linked-PR `gh pr view --json state`);
   **(4)** present the emoji-prefixed table (NUMBER / TITLE / SIGNAL / ACTION);
   **(5)** interactive menu (act all 🟢 / all 🟢+🟡 / pick / cancel), skipped in
   noninteractive; **(6)** act — `gh issue close <n> --comment "…links #<pr>…"
   --reason completed` for 🟢-close, `gh issue edit <n> --remove-label auto` for
   🟢-de-queue; **(7)** report (N closed, M de-queued, K skipped + why).
4. `## Notes`: never deletes issues; never touches issues outside detected
   signals; never sets/removes labels other than `auto`; `gh`-not-authenticated
   fallback; note that `close`/`edit` need repo **write** access.

This satisfies every acceptance criterion, reuses proven idioms, and matches house
style. It is well within a single small PR (one SKILL.md + two README lines).

## Open questions

1. **Staleness-by-inactivity (out of scope for now).** The issue's signals are all
   PR/label-linkage based; it does **not** ask to close issues merely for being
   old/inactive. Recommendation: **do not** add a time-since-`updatedAt` signal in
   v1 — it has no provably-safe bucket (an untouched issue may still be valid
   work) and would risk closing live issues. Flag if the user wants an
   inactivity-based 🟡 "stale, consider closing" report later.
2. **Closed-still-`auto` scope.** De-queuing closed issues (signal 3) is pure
   cosmetics — a closed issue is already out of the queue (the supervisor filters
   on `--state open`). Include it (cheap, matches "closed issue still labeled
   `auto` → drop `auto`" in the issue) or skip it as noise? Recommendation:
   include it but rank it lowest and only act in the 🟢 bucket; it never changes
   issue state.
3. **`--reason` on close.** Use `--reason completed` for merged-PR closes; is a
   `--reason "not planned"` path wanted for a future duplicate/superseded flow, or
   leave duplicates entirely to humans (🔴)? Recommendation: leave duplicates to
   humans in v1; only `completed` is machine-provable.
4. **README dual-maintenance.** The Skills table and Layout tree are
   convention-only, unenforced. Confirm they should still be updated in the same
   PR (recommendation: yes — every prior skill did, keeps docs honest).
