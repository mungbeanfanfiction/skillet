---
name: log
description: Distill a Claude Code session into a note in the Obsidian vault's `10 Sessions/`, with exact stats read from the transcript and a project hub kept up to date. Judges whether the session is worth keeping and writes nothing when it isn't. Use at the end of a session worth remembering, when asked to log/capture/save/distill a session, or when the vault Stop hook says a session has enough material.
argument-hint: "[session-id|transcript-path] [--force]"
model: sonnet
---

# Log

Turn a session into a note someone can read in a minute, months later, and know
what happened and what it changed.

Read `../_shared/vault-schema.md` first — it locates the vault, defines the
frontmatter, and names the state files. Then read the vault's own
`90 Meta/Vault Conventions.md`.

## When invoked

- **no argument** — the current session. Its transcript is the newest `.jsonl`
  under `~/.claude/projects/<encoded-cwd>/`.
- **`[session-id|transcript-path]`** — that session instead.
- **`--force`** — write the note even if step 2 judges it not worth keeping.

## 1. Get the facts

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/session-stats.sh" "$TRANSCRIPT"
```

If `ok` is false, stop and report the error. Do not estimate from memory — the
numbers in the note are the part a dashboard can trust.

Then read the transcript itself. The stats say how much happened; only the
transcript says what.

## 2. Decide whether it's worth a note

This is the actual work, and the reason a hook can't do it. Ask:

- Was a **decision** made, with an alternative rejected?
- Was something **learned** that changes how the next session goes?
- Was there a **dead end** worth not repeating?
- Did something **surprise** you — a bug whose cause wasn't what it looked like?

One clear yes is enough. A five-minute session that found why a build broke earns
a note; ninety minutes of mechanical refactoring usually doesn't.

Signals live in the conversation, not the counters: the user saying "oh,
interesting", a decision getting reversed, a plan abandoned mid-way, a
correction. Weigh those above turn count.

**If the answer is no, write nothing.** Say so in one line and stop. A vault that
records everything is one you stop reading. `--force` overrides this.

## 3. Resolve the project

The project is the repo name from `cwd`, or the vault's existing hub if one
matches. Scratch workspaces have no meaningful repo — use the topic instead.

If `20 Projects/<project>.md` doesn't exist, create it from
`90 Meta/Templates/Project.md`. Don't hand-maintain its session list; a Base
query builds that.

## 4. Write the note

`10 Sessions/YYYY-MM-DD <slug>.md`, from `90 Meta/Templates/Session.md`. The slug
is what the session was about, in a few lowercase words.

Frontmatter comes from the stats, verbatim. Prose sections:

- **What I set out to do** — one or two sentences, from the first prompt and how
  it changed.
- **What actually happened** — the real path, including what failed. A note that
  only records the successful route is a lie by omission and useless when the
  same wall comes up again.
- **Decisions made** — each with the alternative rejected and why. Skip if none.
- **Insights extracted** — wikilinks, filled in by `/vault:insights`. Leave empty.
- **Loose ends** — unchecked boxes for what's genuinely unfinished.

Set `status: distilled`. Link the project hub.

Apply `/deslop` before saving. Specifically: no `## Context` scaffolding, no bold
on non-terms, no closing paragraph restating the note.

## 5. Record it

```bash
STATE="${VAULT_STATE_DIR:-$HOME/.local/state/claude-vault}"
mkdir -p "$STATE/logged" && : > "$STATE/logged/$SESSION_ID"
rm -f "$STATE/queue/$SESSION_ID.json"
```

Without this, `/vault:backfill` logs the session again.

## 6. Report

The note path, the judgment call in one line, and whether a project hub was
created. Then offer `/vault:insights` if the session produced anything
generalizable — but don't run it unasked.
