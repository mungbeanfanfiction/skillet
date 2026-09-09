---
name: insights
description: Extract generalizable lessons from a session into atomic notes in the Obsidian vault's `30 Insights/`, deduped against what's already there and backlinked to their source session. Use after /vault:log, or when asked to pull out insights, lessons, takeaways, or things learned from a session.
argument-hint: "[session-note-path|session-id]"
model: sonnet
---

# Insights

Pull the reusable part out of a session. Most sessions yield zero insights, and
that is the normal outcome.

Read `../_shared/vault-schema.md` first.

## When invoked

- **no argument** — the most recent note in `10 Sessions/`.
- **`[session-note-path|session-id]`** — that session instead.

## 1. What counts

An insight is a claim that would change how you approach a *different* problem
later. Test it: could this be true on a project you haven't started yet?

Keep:

- A cause that wasn't what the symptom suggested.
- A constraint of a tool or API that isn't in its docs.
- A rule of thumb earned by getting it wrong.
- A tradeoff you resolved and would resolve the same way again.

Don't keep:

- What happened in this session. That's the session note.
- Anything true only of this codebase — that belongs in its README or CLAUDE.md.
- Restatements of documentation.
- "Remember to be careful with X."

If nothing qualifies, say so and stop. Zero is a real answer.

## 2. Dedupe before writing

Search `30 Insights/` for the claim, not the wording — same idea, different
phrasing. Without this you accumulate forty notes saying one thing.

On a match: strengthen the existing note instead. Add the new evidence, append
the new session to its sources, raise `confidence` if this is independent
confirmation. Say which note you strengthened.

## 3. Write

One file per claim, `30 Insights/<the claim>.md`, from
`90 Meta/Templates/Insight.md`. The **title is the claim itself** in sentence
case — "Bases queries need explicit frontmatter types", not "Notes on Bases".
A title you have to open the note to understand defeats the folder.

Body: the claim in a sentence or two, then **Why it matters**, **How to apply
it**, **Evidence** (what actually happened, concretely).

Set `source` to a wikilink to the session note. Set `confidence` honestly —
`speculative` for one observation, `high` for something you've now hit twice.

## 4. Backlink

Add each new insight as a wikilink under the session note's **Insights
extracted** and to its `insights:` frontmatter list. A one-way link means the
session note never shows what it produced.

## 5. Report

Each insight written or strengthened, one line each, with its confidence. If
nothing qualified, say that plainly rather than padding the vault.
