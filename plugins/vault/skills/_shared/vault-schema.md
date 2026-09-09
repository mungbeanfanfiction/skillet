# Vault contract

Shared by every `/vault:*` skill. The vault owns its own schema; this file
records where things live and the rules the plugin adds on top.

## Locating the vault

In order:

1. `$OBSIDIAN_VAULT` if set.
2. `~/Documents/Obsidian Vault` — the default.
3. Any directory containing `.obsidian/` named in the user's message.

If none resolves, stop and ask. Never guess a path and never create a vault.

**Read `<vault>/90 Meta/Vault Conventions.md` before writing anything.** That
file is the schema of record — folders, naming, frontmatter fields, tags. If it
disagrees with anything here, it wins. Obsidian Bases query frontmatter directly,
so a note with the wrong `type` or a missing field disappears from every
dashboard without erroring.

## Folders

| Path | Holds |
|---|---|
| `10 Sessions` | one note per distilled session |
| `20 Projects` | project hubs |
| `30 Insights` | atomic reusable lessons |
| `50 Reviews/{Weekly,Monthly}` | rollups |
| `90 Meta/Templates` | note templates |

## Transcripts

Live at `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`. The encoded cwd
is the absolute path with `/` and `.` replaced by `-`.

Never estimate stats from memory. Run:

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/session-stats.sh" <transcript.jsonl>
```

It returns one JSON object: `duration_min`, `prompts`, `turns`, `tool_calls`,
`tools`, `tool_counts`, `files_written`, `files_read`, `files_touched`, `errors`,
`tokens`, `git_branch`, `cwd`, `first_prompt`. On failure, `{"ok":false,...}` and
exit 1 — report the error rather than inventing numbers.

Two caveats. `duration_min` is wall-clock, so a session left open overnight reads
as hundreds of minutes; treat it as a weak signal. `errors` counts tool results
the harness flagged, which includes ones that were expected and handled.

## Plugin state

`~/.local/state/claude-vault/` (override with `$VAULT_STATE_DIR`):

- `nudged/<session-id>` — the Stop hook fired for this session
- `queue/<session-id>.json` — session ended unlogged, waiting for backfill
- `logged/<session-id>` — a session note exists; do not queue or re-log

Write `logged/<session-id>` whenever you create a session note, and delete the
matching `queue/` entry. Skipping this is what produces duplicates.

Deliberately **not** under `~/.claude/`: file-editing tools refuse to write there
as a protected path, and no allow rule overrides it. An unattended run could write
notes but never record that it had, so the next run duplicated them.

## Writing

Apply the `/deslop` standard to every note. Sessions and insights are read months
later under no context — scaffolding headings, bold on non-terms, and closing
summaries all make them worse. A note nobody rereads failed.

Never rewrite the frontmatter stats on an existing session note. They are
extracted facts, not prose.
