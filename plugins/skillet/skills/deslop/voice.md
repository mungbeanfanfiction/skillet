# Voice profile

Derived from Leah's own writing in this repo — hand-typed issues and chat, not
anything an agent produced. Edit this file when it stops matching; the skill
reads it as the target, so this file *is* the spec.

## Samples

Issue #100, verbatim:

> when there are still more issues ready to go it think its slots are filled if
> there are PRs that need my review or other items it was working on that have
> hit their restart cap. it is holding onto the items that it owns as slot
> fillers rather than filling its slots with implementation

Issue #59, verbatim:

> instead of within functions -- if there are like circular dependencies that's
> a sign we need to breka things out into utils files

Issue titles, verbatim:

> issue supervisor getting stuck
> issue-supervisor should never ask for confirmation
> Add a skill to clean up dead/orphaned claude processes
> cleanup-worktrees: remove worktrees dirty only with untracked/ignored files

## What's actually there

- **Starts at the problem.** No setup, no context paragraph, no restating the
  title. The first sentence is the broken behavior.
- **Concrete subjects.** "it is holding onto the items that it owns" — names the
  actual thing doing the actual wrong action. Not "resource allocation is
  suboptimal".
- **Blunt where blunt is correct.** "should never ask for confirmation." No
  hedging toward "should generally avoid".
- **`--` as the aside connector**, not `—`.
- **Lowercase in informal contexts** (issue bodies, notes). Sentence case in
  titles and docs. Don't force either direction.
- **No bold.** Emphasis comes from sentence order, not typography.
- **No section scaffolding** unless the thing is genuinely long enough to need
  navigation.
- **Present tense** for describing behavior.

## What is not the voice

Typos (`breka`, `it think`) are artifacts of typing fast, not style. Fix them
silently. Same for missing apostrophes. The register is casual; the spelling
isn't part of it.

Chat shorthand (`pls`, `def`, `rn`, `super duper`) belongs in chat. Don't carry
it into notes, issues, or docs.

## Register by destination

| Destination | Case | Length |
|---|---|---|
| Vault notes (`10 Sessions`, `30 Insights`) | sentence case, informal | as short as the content allows |
| Issue bodies | lowercase fine | one paragraph unless it needs more |
| PR descriptions | sentence case | what changed, why, what to check |
| `SKILL.md` / docs | sentence case | terse; these get read under load |
| Commit subjects | `type(scope): imperative` | one line, existing convention |
