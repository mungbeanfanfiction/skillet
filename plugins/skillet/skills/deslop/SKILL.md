---
name: deslop
description: Strip AI tells out of prose and rewrite it in Leah's voice — concise, concrete, no scaffolding. Targets issue bodies, PR descriptions, SKILL.md and docs, vault notes, and commit messages. Reports by default; `--fix` rewrites in place. Also the shared writing standard other skills follow before they write any prose. Use when asked to deslop, de-AI, tighten, or humanize writing, and before publishing anything an agent drafted.
argument-hint: "[path|--staged|--diff] [--fix]"
model: sonnet
---

# Deslop

Agent-written prose has a texture. It scaffolds a three-line thought into three
headings, bolds words at random, and reaches for the same dozen constructions
every time. This skill removes that texture and rewrites toward the voice in
`voice.md` — which is built from real samples and is the actual spec. Read it
before rewriting anything.

Two ways this runs:

- **As a command** — `/deslop <path>` reviews prose and, with `--fix`, rewrites it.
- **As a standard** — other skills apply the rules below before writing prose of
  their own. That's the common case; most slop is cheaper to not write than to
  remove.

## When invoked

- **`[path]`** — a file or directory. Markdown and prose only.
- **`--staged`** — prose in staged changes.
- **`--diff`** — prose added on this branch vs. its base.
- **`--fix`** — rewrite in place. Without it, report findings and stop.

With no argument, deslop the prose in the current conversation's pending output
(a draft PR body, an issue, a note about to be written).

## The tells

Each of these is checkable — you can point at the span. Flag what you find, cut
it, and don't replace it with a different flavor of the same thing.

**Structural**

- Section scaffolding on short content: `## Context` / `## What needs to happen`
  / `## Acceptance criteria` over three sentences. If a heading owns one
  paragraph or one bullet, delete the heading.
- Numbered markers (`01 / 02 / 03`) on things that aren't a sequence.
- A closing paragraph that restates what the reader just read.
- An opening sentence that restates the title or the question.

**Sentence-level**

- Rule-of-three lists where two items or four would be truthful. Agents pad to
  three by reflex.
- Contrast frames as the default rhythm: "not X, but Y", "rather than X, Y",
  "X isn't just Y — it's Z". One in a document is fine. Three is a tic.
- Em-dash asides used as the connector for every other sentence. Leah writes
  `--`, and sparingly.
- Bold scattered across phrases that aren't terms. Bold a term being defined;
  otherwise let sentence order carry the emphasis.
- Hedges that carry nothing: "it's worth noting", "importantly", "essentially",
  "in practice", "simply", "just", "actually".
- Adjective stacks: "robust, comprehensive, seamless".
- The vocabulary: delve, leverage (verb), utilize, facilitate, streamline,
  robust, seamless, comprehensive, holistic, elevate, unlock, harness, tapestry,
  landscape, realm, testament, crucial, pivotal, vital.
- Narrative framing on a bug report: "This surfaced when…", "In practice it…".

**Content**

- Explaining back to the reader something they wrote or already know.
- Restating the same point in a second sentence with different words.
- Describing what a change *is* when the reader needs to know what it *does*.
- Praise, apology, or self-assessment inside a deliverable.

## Concision

Three passes, in order:

1. **Cut whole sentences.** Any sentence that restates the previous one, or that
   the reader could not act on differently for having read it. This removes more
   than word-level editing ever will.
2. **Cut the scaffolding.** Headings owning one item, bullets that are really one
   sentence split in two, tables with one row.
3. **Cut words.** Adverbs that don't change meaning. "in order to" → "to". "is
   able to" → "can". Nominalizations back to verbs: "make a determination" →
   "decide".

Stop when the next cut would remove information. Concision is not compression —
a note nobody can act on isn't short, it's useless.

## What not to strip

The failure mode is over-trimming into vagueness. Protect:

- File paths, commands, flags, error strings, version numbers, line references.
- Numbers and their units. "1.5-second budget" survives; "a short budget" doesn't.
- Caveats that change what someone would do. A hedge that carries a real
  condition is not a hedge.
- Technical qualifiers that narrow scope: "on macOS", "only in linked worktrees",
  "when jq is missing".
- Anything Leah wrote herself. Fix typos, leave the phrasing.

If a cut would make the text more comfortable but less true, don't make it.

## Reporting

Without `--fix`, print findings as `path:line — tell — the span`, grouped by file,
worst first. Then a one-line verdict: how much of the prose is slop, roughly.

With `--fix`, rewrite and show a diff of prose changes only. Never touch code,
config, or frontmatter fields other than prose values. Never commit or push.

## For skills that call this

Before writing any prose — issue body, PR description, vault note, doc — apply
the tells and concision passes above. The check is one question:

> Would Leah have written this sentence, or does it read like it was generated?

If a draft has a Context heading over two sentences, three bolded phrases, and a
closing summary of itself, it fails. Rewrite before it lands, not after.
