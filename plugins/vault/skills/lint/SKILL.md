---
name: lint
description: Check the Obsidian vault for broken wikilinks, orphan notes, sessions missing frontmatter fields, and insights with no source, so the Bases dashboards stay accurate. Use when dashboards look wrong or empty, after a bulk backfill, or when asked to check/clean/audit vault health.
argument-hint: "[--fix]"
model: sonnet
---

# Lint

Bases queries fail silently. A note with the wrong `type` or a missing field
doesn't error — it disappears from every dashboard, and you see less without
noticing. This finds those.

Read `../_shared/vault-schema.md` first, then the vault's own
`90 Meta/Vault Conventions.md`. Conventions is the source of truth for which
fields are required; don't hardcode a list here that can drift from it.

## When invoked

**`--fix`** applies only the mechanical repairs marked safe below. Everything
else is reported for a human. Without it, report only.

## Checks

**Frontmatter**

- Notes in `10 Sessions/` missing `type`, `date`, `project`, or `session-id`.
- `type` that doesn't match the folder — a `type: insight` in `10 Sessions/`.
- Malformed YAML. A note whose frontmatter doesn't parse is invisible to every
  Base and won't show as an error anywhere.
- `date` not `YYYY-MM-DD`.

**Links**

- Wikilinks pointing at notes that don't exist.
- Insights whose `source` names a missing session note.
- Session notes whose `project` has no hub in `20 Projects/`.
- Orphans: notes nothing links to and that link nowhere. Insights are the ones
  that matter — an unreachable insight will never be recalled.

**Duplicates**

- Two insights making the same claim in different words. Report as candidates for
  merging; never merge automatically.
- Two session notes sharing a `session-id`.

**Consistency**

- Session notes still at `status: captured` that have prose written — they should
  be `distilled`.
- Tags outside the taxonomy in Conventions.

## Safe to `--fix`

Only these:

- Add a missing `type` where the folder makes it unambiguous.
- Normalize a `date` that parses but is formatted wrong.
- Create a missing project hub from the template.
- Flip `captured` to `distilled` where the prose sections are filled.

Never auto-fix: broken wikilinks (the target may be misnamed rather than
missing), duplicate insights, orphans, or anything touching stats frontmatter.

## Report

Group by severity. Lead with anything hiding notes from dashboards, since that's
the silent failure. Then links, then hygiene. Give a count per category and the
file list for anything actionable — no walls of paths for orphan chatter.

If the vault is clean, say so in one line.
