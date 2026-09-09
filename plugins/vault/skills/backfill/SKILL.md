---
name: backfill
description: Sweep `~/.claude/projects/` for Claude Code sessions not yet in the Obsidian vault, drain the SessionEnd queue, and distill the ones worth keeping. Use to populate a new vault with past history, to catch up after closing sessions without logging, or when asked to backfill/import/catch up on old sessions.
argument-hint: "[--since YYYY-MM-DD] [--limit N] [--dry-run]"
model: sonnet
---

# Backfill

Find sessions that never got logged and deal with them. Makes a new vault useful
on day one instead of day thirty, and is the recovery path for every terminal you
closed without thinking.

Read `../_shared/vault-schema.md` first.

## When invoked

- **`--since YYYY-MM-DD`** — only sessions after this date. Default: everything.
- **`--limit N`** — stop after N sessions. Default 20; a first run over months of
  history is otherwise very long.
- **`--dry-run`** — list candidates and their verdicts, write nothing.

## 1. Build the candidate list

Two sources:

```bash
STATE="${VAULT_STATE_DIR:-$HOME/.claude/vault}"
ls "$STATE/queue/"*.json 2>/dev/null                        # ended unlogged
find ~/.claude/projects -name '*.jsonl' -newermt "$SINCE"    # everything on disk
```

Drop any session with `$STATE/logged/<session-id>`, and any whose `session-id`
already appears in a `10 Sessions/` note's frontmatter. Check both — the state
dir can be cleared, the vault is the real record.

Queued sessions come first; they ended recently and are most likely to matter.

## 2. Triage cheaply before reading

Run `session-stats.sh` on each. Skip without reading anything with fewer than 5
turns and no files touched — those are one-off questions, not work.

Report how many you skipped as a count. Don't list them.

## 3. Distill the rest

For each survivor, apply `/vault:log` steps 2 through 5: judge whether it's worth
keeping, and write the note only if it is. **The bar is the same as live
logging.** Backfill is not a licence to bulk-import; a vault filled with
mechanical sessions is worse than an empty one.

Working from an old transcript, you have less than you would live — no memory of
what you were thinking. Write what the transcript supports and no more. If it
isn't clear what a session was for, say so in the note rather than inventing a
narrative.

Batch by project so hubs get created once.

## 4. Clean the queue

Delete the `queue/` entry for every session handled, including ones judged not
worth a note — otherwise they resurface on every run. Write `logged/<id>` only
where a note was actually written.

## 5. Report

Sessions scanned, skipped as trivial, judged not worth keeping, and notes
written. Then the two or three most interesting things the history surfaced —
that's the reason to backfill at all.
