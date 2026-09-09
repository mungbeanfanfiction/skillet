---
name: recall
description: Search the Obsidian vault for past sessions and insights relevant to what you're about to work on, and pull them into context. Use before starting a task that feels familiar, or when asked "have I done this before", "what do I know about X", "did I hit this already", or to look something up in the vault.
argument-hint: "<topic or question>"
model: sonnet
---

# Recall

Check what you already know before solving it again. This is the skill that makes
the vault worth keeping; everything else is deposits.

Read `../_shared/vault-schema.md` first.

## When invoked

**`<topic or question>`** is what you're about to work on. With no argument,
infer it from the conversation.

## 1. Search, then read

Search terms should include the error text, tool and library names, file paths,
and the underlying concepts, not just the user's phrasing. Past-you wrote it down
in different words than present-you is searching with.

```bash
grep -ril "<term>" "$VAULT/30 Insights" "$VAULT/10 Sessions" "$VAULT/40 Reference"
```

Search `30 Insights` first. Those are already distilled and generalized, so a hit
there is worth more than a session hit. Then `10 Sessions`, newest first, then
`20 Projects` for context on a project you're returning to.

Open every hit. Never report on filenames alone: a title can look relevant and
the note say something else entirely.

## 2. Report what's actually useful

Lead with the answer, not the search.

- **What you already know**: the claim, with a wikilink, and whether it applies
  cleanly or only partly.
- **When you hit this before**: the session, its date, what worked.
- **What's different now**: if the past note assumes something no longer true,
  say so. A stale note applied confidently is worse than no note.

If nothing relevant exists, say so in one line. Don't stretch a weak match into a
false connection. "Nothing in the vault on this" is a useful answer, and it tells
you the current session is worth logging.

Recall reports; it doesn't implement. Hand back what the vault knows and let the
conversation continue.
