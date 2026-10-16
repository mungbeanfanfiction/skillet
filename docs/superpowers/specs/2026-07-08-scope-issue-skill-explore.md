# Explore: skill for writing well-scoped GitHub issues (#6) — Findings

**Date:** 2026-07-08
**Issue:** https://github.com/mungbeanfanfiction/skillet/issues/6
**Branch / PR:** `auto-6-scope-issue-skill` (draft PR linked below)

## The ask

Build a new skill (working name `scope-issue` / `write-issue`) that turns a rough
idea or a terse issue into a **well-scoped GitHub issue**, so that the autonomous
queue hits fewer mid-run design questions. A well-scoped issue means:

- A clear, single-responsibility goal.
- Explicit **acceptance criteria** (what "done" looks like).
- The intended approach / affected files where known.
- Open design decisions **resolved up front** (so the worker doesn't have to ask),
  or explicitly flagged as "decide before dispatch."
- Right-sized scope: flag issues that are too big and suggest a decomposition into
  sub-issues.

The issue frames this as the **prevention** side of a system whose **handling**
side (best-guess-or-escalate-to-`needs-input` at run time) already exists in the
queue. It also notes the decomposition logic "overlaps with the queue's
autonomous-decomposition step — this skill could share that logic."

This is an `explore`-labeled spike: the deliverable is this findings spec, not the
skill itself.

## What we found

The repo already contains **most of the raw material** this skill needs — its
value is in composing existing conventions plus adding two genuinely net-new
pieces (intended-approach/affected-files, and up-front resolution of design
decisions during authoring). Nothing here requires new infrastructure: skills are
auto-discovered markdown, and the label/decomposition/design-question machinery is
all in place.

**Issue authoring already has a canonical body shape.** `create-issue` writes a
fixed three-section body — `## Context`, `## What needs to happen`,
`## Acceptance criteria` (checkbox list) — and enforces the load-bearing rule
*"Do not invent acceptance criteria the conversation doesn't support — if
genuinely unknown, leave a single `- [ ] TODO` bullet"*
(`plugins/skillet/skills/create-issue/SKILL.md:52-70`). It is fully autonomous,
never prompts, and does no scoping or decomposition. This is the closest existing
skill to the "author a well-formed issue" half of the ask.

**`triage-issue` is the biggest overlap** and already implements three of the five
requested behaviors — just applied to an *existing* issue rather than authoring
from a rough idea. It does a **Size assessment** ("does it clearly span multiple
independent units of work?", `plugins/skillet/skills/triage-issue/SKILL.md:70-78`),
captures unresolved uncertainty in an **`## Open Questions`** body section, and
performs **decomposition into epic + sub-issues** when an issue spans multiple
independent work units (`triage-issue/SKILL.md:125-146`). The main design risk for
a new `scope-issue` skill is duplicating this triage logic rather than sharing or
delegating to it.

**Decomposition already exists as a repeated convention, but only as prose** — it
lives in two places with the same epic/`Part of #<epic>`/drop-`auto` mechanics and
no extracted, shared code:

- **Triage-time**: `triage-issue/SKILL.md:125-146` — relabel the original as
  `epic` with an `## Epic` checklist linking children; file each child via
  `create-issue`'s drafting/labeling rules, cross-linked `Part of #<epic>`, each
  carrying `auto`; the epic parent carries `epic` and **drops `auto`** so it's
  tracking-only.
- **Dispatch-time**: `issue-supervisor/SKILL.md:104-115` — the "Too big" branch
  creates **≤6 sub-issues** labeled `auto` + `loop-generated` with body
  `part of #<n>`, then relabels the parent `epic` and removes `auto`.

This is exactly the "autonomous-decomposition step" the issue says the skill could
share. Today it is duplicated LLM-instruction prose, not a callable function — so
the realistic "sharing" is convention reuse (same labels, same epic/child shape),
not code reuse.

**The design-question escape hatch this skill aims to reduce is fully wired.** A
dispatched session that hits a genuine design question writes `.claude/question.md`
and exits (`issue-supervisor/lib/supervisorlib/spawn.py:51-55`); the "minor
ambiguity → best-guess, genuine design question → escape hatch" rule is
`spawn.py:16-20`. The worktree is then classified `needs-input`
(`state.py:18-37`, checked before even an open PR), the supervisor leaves it alone,
and `question-sweeper` posts the question to GitHub and re-dispatches once
answered. A better-scoped issue reduces how often a session reaches the "genuine
DESIGN question" branch in the first place. `needs-input`, `epic`, and
`loop-generated` are all defined in the canonical taxonomy
(`plugins/skillet/skills/_shared/labels.json`).

**Sizing is only enforced as a 400-line PR-diff cap, never as an issue estimate.**
The cap is surfaced in four coordinated places — the authoritative hard-block in
`open-pr/SKILL.md:79-120`, the survey advisory flag (`survey.py` `PR_LINE_LIMIT =
400`), the per-dispatch prompt constraint (`spawn.py` pipeline stage 3), and the
digest report line. But issue-level "is this too big?" is currently a human/LLM
judgment call at dispatch time (`issue-supervisor/SKILL.md:96`), with no heuristic.
**This is the concrete gap `scope-issue` fills**: right-sizing an issue *before* it
is labeled for the queue, so the 400-line PR gate isn't discovered mid-implementation.

**Skill mechanics are simple.** Skills are auto-discovered from
`plugins/skillet/skills/<name>/SKILL.md` — no manifest edit is required
(`.claude-plugin/marketplace.json` and `plugins/skillet/plugin.json` list the
plugin, not its skills). Frontmatter is `name` / `description` / optional
`argument-hint`. There is no skill lint, no test, and no CI gate for a
markdown-only skill (the only workflow is `release.yml`; `npm test` /`pytest`
cover `scripts/` and `issue-supervisor/lib` only, and aren't wired into Actions).
Shipping requires a `feat:` commit so semantic-release cuts a minor release. The
established pattern is to add a README skills-table row and (for a non-trivial
skill) a paired design doc under `docs/superpowers/`.

## Relevant code

| Area | Location | Role |
|---|---|---|
| Canonical issue body (Context / What / Acceptance criteria) | `plugins/skillet/skills/create-issue/SKILL.md:52-70` | The body skeleton + "don't invent acceptance criteria / leave `- [ ] TODO`" rule to inherit |
| Autonomous labeling rules | `plugins/skillet/skills/create-issue/SKILL.md:73-101` | always `auto`, one type, ≥0 area, one priority; fetch-then-create-missing labels |
| Size assessment | `plugins/skillet/skills/triage-issue/SKILL.md:70-78` | "does it span multiple independent units of work?" — the right-sizing judgment |
| Open Questions section | `plugins/skillet/skills/triage-issue/SKILL.md` (enrichment body) | Existing mechanism for recording unresolved design decisions |
| Decomposition (triage-time) | `plugins/skillet/skills/triage-issue/SKILL.md:125-146` | epic + `## Epic` checklist + `Part of #<epic>` children + drop-`auto` on parent |
| Decomposition (dispatch-time) | `plugins/skillet/skills/issue-supervisor/SKILL.md:104-115` | ≤6 sub-issues, `auto`+`loop-generated`, `part of #<n>`, parent → `epic` minus `auto` |
| Design-question escape hatch | `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/spawn.py:16-20,51-55` | best-guess-vs-escalate rule + `.claude/question.md` hatch this skill reduces |
| needs-input classification | `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/state.py:18-37` | how a parked design question frees a slot |
| 400-line PR gate (authoritative) | `plugins/skillet/skills/open-pr/SKILL.md:79-120` | the only mechanical size enforcement — a PR cap, not an issue estimate |
| Survey oversize flag | `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/survey.py` (`PR_LINE_LIMIT = 400`) | advisory 400-line diff flag |
| Canonical labels | `plugins/skillet/skills/_shared/labels.json` | queue/type/area/priority + `epic`, `loop-generated`, `needs-input` |
| Spec house format | `docs/superpowers/specs/2026-06-23-triage-issue-design.md` | Problem / Solution overview / Workflow / Files touched / Non-goals / Open questions template |
| Superpowers scope patterns | `superpowers:brainstorming`, `superpowers:writing-plans` | scope check, file-structure-first, task right-sizing, no-placeholders — content to borrow |
| Skill authoring rules | `superpowers:writing-skills` | frontmatter + "match the form to the failure" (required-slot template, not prohibitions) |
| Plugin manifests (no skill list) | `.claude-plugin/marketplace.json`, `plugins/skillet/plugin.json` | confirm skills are auto-discovered, no registration edit |
| Release flow | `.releaserc.json`, `README.md` skills table | `feat:` commit → semantic-release minor bump; add a README row |

## Options

The core design tension is **how `scope-issue` relates to the existing
`create-issue` and `triage-issue` skills**, given how much already overlaps.

### Option A — New standalone `scope-issue` skill that composes existing conventions

A dedicated skill that takes a rough idea (or an existing thin issue number) and
produces a well-scoped issue: it reuses `create-issue`'s body skeleton + labeling,
adds two net-new sections (**Intended approach / affected files** and **Design
decisions — resolved**, with an escape-valve **Open Questions** for what it
genuinely can't resolve), and reuses the epic/sub-issue decomposition convention
when it judges the issue too big. It cross-references `/create-issue` and
`/triage-issue` in its description, matching the house style.

- **Pros:** Directly delivers what the issue asks; single obvious entry point
  ("help me scope this"); keeps the net-new value (approach/affected-files +
  up-front decision resolution) in one place.
- **Cons:** Real overlap with `triage-issue` (size assessment + decomposition +
  open-questions). Risk of three issue-authoring skills with fuzzy boundaries.

### Option B — Extend `triage-issue` / `create-issue` instead of a new skill

Fold "scoping" into the existing skills: add an approach/affected-files section and
an up-front design-decision-resolution pass to `create-issue`, and lean on
`triage-issue` for the existing-issue path.

- **Pros:** No new skill; consolidates issue-authoring logic; avoids duplication.
- **Cons:** Conflates two distinct intents — `create-issue` is deliberately a fast,
  no-frills "file it" path; loading it with a scoping/decomposition pass changes its
  character. The issue explicitly asks for a *new* skill. Doesn't give the
  "help me think through scope" workflow a clear home.

### Option C — Extract a shared decomposition/scoping helper, then build the skill on top

First extract the duplicated epic/sub-issue decomposition prose (and optionally the
body skeleton) into a shared reference the three skills all cite, then implement
`scope-issue` (Option A) against it — realizing the issue's "could share that logic."

- **Pros:** Removes the existing triage/supervisor prose duplication; strongest
  long-term architecture; matches the issue's stated intent most literally.
- **Cons:** Larger surface; touches `triage-issue` and `issue-supervisor` as well
  as adding the new skill — likely more than one 400-line PR, so it must be
  sequenced (extract shared convention first, then build the skill). More
  coordination risk than a self-contained new skill.

## Recommendation

**Option A, with a lightweight nod to C.** Build a new standalone `scope-issue`
skill (matching the local prose `SKILL.md` house style, not the superpowers
technique-skill template), because that is exactly what the issue asks for and it
gives the "help me scope this before it's queued" intent a clear home that neither
`create-issue` (fast filing) nor `triage-issue` (fix an existing issue) currently
serves.

Concretely, the skill should:

1. Take a rough idea from conversation **or** an existing thin issue number
   (reuse `update-issue`'s branch/commit issue-number inference for the latter).
2. Produce the `create-issue` body skeleton (`## Context` / `## What needs to
   happen` / `## Acceptance criteria`) **plus two net-new required sections**:
   `## Intended approach / affected files` (borrow `explore-issue`'s `Area |
   Location | Role` table shape) and `## Design decisions` (each decision
   **resolved up front** with the chosen answer and a one-line rationale; anything
   genuinely un-resolvable drops to an `## Open Questions` section rather than
   blocking — mirroring the never-stall contract).
3. Run a **right-sizing check** using `triage-issue`'s size heuristic
   (`triage-issue/SKILL.md:70-78`); if the issue clearly spans multiple independent
   work units, **suggest** (interactive) or **perform** (unattended) the existing
   epic + sub-issue decomposition, reusing the exact
   epic/`Part of #<epic>`/drop-`auto`/`loop-generated` convention already used by
   `triage-issue` and `issue-supervisor`.
4. Apply canonical labels via the shared `_shared/labels.json` rules and always
   include `auto`, matching `create-issue`.

To honor the issue's "could share that logic" note without ballooning scope, the
decomposition step should be written to **reference the existing epic/sub-issue
convention as the single source of truth** rather than re-deriving it — and a
follow-up refactor (Option C) can later extract that convention into a shared
`_shared/` reference cited by all three skills. Framing the net-new content as
**required template slots** (per `superpowers:writing-skills` "match the form to the
failure") is what actually forces goal + acceptance criteria + approach +
resolved-decisions to appear, rather than a list of prohibitions.

**Sequencing / PR-size note:** the standalone skill (SKILL.md + README row + this
paired design doc) fits comfortably in one sub-400-line `feat:` PR. If Option C's
shared-extraction refactor is pursued, it should be a **separate** PR (it edits
`triage-issue` and `issue-supervisor` too) landed before or after the skill, not
bundled with it.

## Open questions

- **Name.** The issue floats both `scope-issue` and `write-issue`. `scope-issue`
  reads best against the sibling verbs (`create-issue`, `triage-issue`,
  `update-issue`, `explore-issue`) and foregrounds the differentiating value
  (scoping/right-sizing). Recommend `scope-issue`, but this is the author's call.
- **Create-vs-enrich surface.** Should the skill only *author a new* issue (like
  `create-issue`), only *enrich an existing thin* issue (overlapping
  `triage-issue`), or both? This spec assumes **both** (rough idea → new issue, or
  issue number → enriched), but that is the largest single boundary decision and it
  directly determines the overlap with `triage-issue`.
- **Interactive vs unattended posture on decomposition.** `create-issue` and
  `triage-issue` are fully autonomous and never prompt. Should `scope-issue`
  likewise decompose autonomously, or — since scoping is a thinking-partner
  activity — *propose* a decomposition and let the user confirm when run
  interactively? Recommend: propose interactively, act autonomously when invoked by
  the queue (mirroring the `--noninteractive` pattern in `update-issue` /
  `open-pr`).
- **Should the "could share that logic" refactor (Option C) be in scope at all**,
  or deferred to a follow-up issue? This spec recommends deferring it to keep the
  first PR self-contained and under 400 lines.
- **Does resolving design decisions "up front" risk over-committing** the
  implementer to an approach the codebase later contradicts? The skill produces
  *authoring-time* judgments without deep code investigation (that's
  `explore-issue`'s job) — so resolved decisions should be framed as defaults the
  worker may revisit, not hard constraints. Worth an explicit line in the skill.
