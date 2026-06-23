# Worktree Status Reporting — Design

**Date:** 2026-06-23
**Repo:** skillet (`/Users/leahpeker/development/skillet`)

## Problem

When running multiple Claude Code agents across many git worktrees, there's no
way to see, at a glance, **what each agent was actually doing** in each worktree.
Git state (branch, dirty, ahead/behind) is derivable on demand, but the
*work-in-progress narrative* — the last thing asked and the last thing done — is
ephemeral and lost once a session ends.

The user runs 13+ worktrees under `pda/.claude/worktrees/`. They want a single
report of the current status of each, where "status" means primarily the
**work-in-progress narrative**, not git/PR/CI metadata.

## Goals

- Capture a current work-in-progress snapshot per worktree, automatically, with
  zero reliance on the model remembering to do it.
- Read all snapshots plus live git state into one combined report on demand.
- Ship entirely inside the **skillet** plugin so it travels with the plugin and
  requires no hand-edited global settings.
- Enforce "no work in main" — only linked worktrees report status; the main
  checkout is never touched.

## Non-Goals (YAGNI)

- No PR / CI / review state (explicitly not wanted).
- No central status directory — status lives per-worktree.
- No append-only history log — each write **overwrites** with current state.
- No global `settings.json` hook — the hook ships with the plugin instead.

## Architecture

Three cooperating pieces, all inside the skillet plugin, plus one tweak to an
existing skill.

| Piece | Location | Role |
|---|---|---|
| **Stop hook registration** | `plugins/skillet/hooks/hooks.json` | Registers a Stop hook that runs the writer script on every turn end. |
| **Writer script** | `plugins/skillet/hooks/worktree-status.sh` | Reads hook stdin, detects worktree-vs-main, writes `.claude/status/STATUS.md`. Passive — always exits 0, never blocks. |
| **Reader skill** | `plugins/skillet/skills/worktree-status/SKILL.md` | `/worktree-status` — merges all STATUS.md files with live git state into one report. |
| **create-worktree tweak** | `plugins/skillet/skills/create-worktree/SKILL.md` | Also ensure `.claude/status/` is excluded when scaffolding a new worktree. |

### Data flow

```
turn ends
  → Claude Code fires Stop hook (plugin hooks.json)
  → worktree-status.sh receives JSON on stdin { cwd, transcript_path, ... }
  → script: is cwd a linked worktree (not main)?  ── no ──► exit 0 (do nothing)
                                                   └─ yes ─► write STATUS.md, exit 0

/worktree-status invoked
  → enumerate `git worktree list --porcelain`
  → for each worktree: read .claude/status/STATUS.md + compute live git state
  → print combined report
```

## Component 1: Stop hook registration (`hooks/hooks.json`)

Plugin hooks live at `<plugin-root>/hooks/hooks.json`. The plugin root is
`plugins/skillet/`. Minimal Stop registration:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "Stop",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/worktree-status.sh"
          }
        ]
      }
    ]
  }
}
```

`${CLAUDE_PLUGIN_ROOT}` resolves to the plugin's installed directory and is also
exported as an env var to the hook process.

**Loop safety:** Our hook is purely passive — it writes a file and exits 0. It
never returns exit code 2 and never emits a block decision, so it cannot cause a
stop-loop. This is the key reason a Stop hook is safe here.

## Component 2: Writer script (`hooks/worktree-status.sh`)

A POSIX shell script. Steps:

1. **Read stdin JSON.** Parse `cwd` and `transcript_path` with `jq`. If `jq` is
   unavailable or input is malformed, exit 0 silently (never disrupt the
   session).

2. **Resolve git context** using `cwd`:
   - `toplevel = git -C "$cwd" rev-parse --show-toplevel` (worktree root)
   - `common  = git -C "$cwd" rev-parse --git-common-dir`
   - If not a git repo → exit 0.
   - **Worktree-vs-main detection:** in a *linked worktree*, the per-worktree
     git dir differs from the common dir. Concretely: resolve
     `git_dir = git -C "$cwd" rev-parse --absolute-git-dir`. If `git_dir`
     contains `/worktrees/` (i.e. `.git/worktrees/<name>`), it's a linked
     worktree → proceed. Otherwise it's the main checkout → **exit 0** (enforces
     "no work in main").

3. **Self-heal the exclude.** Ensure `.claude/status/` is ignored locally so
   STATUS.md never pollutes `git status` or gets committed. Append
   `.claude/status/` to `$common/info/exclude` if not already present. Using
   `info/exclude` (not `.gitignore`) keeps the rule **uncommitted** — no repo
   change in any worktree.

4. **Extract narrative breadcrumbs** from the transcript JSONL:
   - **Last user prompt:** last line where `.type == "user"` (or message role
     user) → first ~200 chars of its text.
   - **Last assistant line:** last assistant text block → first ~200 chars.
   - Both via `tail`-bounded `jq`. Tolerate missing/odd lines — fall back to
     empty strings, never error.

5. **Compute lightweight git state:**
   - branch: `git -C "$cwd" rev-parse --abbrev-ref HEAD`
   - dirty count: `git -C "$cwd" status --porcelain | wc -l`
   - touched files: `git -C "$cwd" diff --stat` summary line (optional).

6. **Write `STATUS.md`** (overwrite) to `$toplevel/.claude/status/STATUS.md`:

   ```markdown
   # worktree status

   - updated: 2026-06-23T14:02:11Z
   - branch: feat-foo
   - dirty files: 3

   ## current activity
   **last ask:** <last user prompt excerpt>
   **last did:** <last assistant line excerpt>

   ## touched
   <git diff --stat summary>
   ```

   Create the `.claude/status/` dir if needed. Exit 0.

**Robustness rule:** every failure path exits 0. The hook must never break a
session or emit noise to the user.

## Component 3: Reader skill (`skills/worktree-status/SKILL.md`)

A documented procedure skill (like the other skillet skills), invoked as
`/worktree-status`. It:

1. Determine the repo root and run `git worktree list --porcelain`.
2. For each worktree path:
   - Read `.claude/status/STATUS.md` if present (the narrative).
   - Compute **live** git state independent of the file:
     - dirty: `git -C <wt> status --porcelain`
     - ahead/behind: `git -C <wt> rev-list --left-right --count @{u}...HEAD`
       (handle no-upstream gracefully)
     - last commit: `git -C <wt> log -1 --format='%cr %s'`
   - **Staleness flag:** if STATUS.md is missing, or its `updated:` timestamp is
     older than 24 hours, flag it as stale / "no recent agent activity". (24h is
     a starting default; trivially tunable in the skill.)
3. Handle the **nested worktree** case (a worktree inside another worktree, as
   currently exists under `feat-issue-supervisor-loop`) — `git worktree list`
   from the main repo lists top-level ones; note nested worktrees are listed by
   their own repo and may need a recursive pass or an explicit note.
4. Print one block per worktree: branch · last-active · current activity
   (from STATUS.md) · live git state · staleness flag.

The skill describes *how* to gather and format; Claude executes it. It does not
need to be a rigid binary.

## Component 4: create-worktree tweak

In the existing create-worktree skill's "create the worktree" step, alongside
the existing `.claude/worktrees/` exclude handling, also ensure `.claude/status/`
is excluded (in `.git/info/exclude`). Largely redundant with the hook's
self-heal, but guarantees cleanliness from the very first turn. One added
sentence/command in the skill.

## Testing

- **Writer script (unit-ish):** pipe synthetic stdin JSON (a fixture `cwd` +
  `transcript_path` to a tiny fake JSONL) and assert STATUS.md content. Cover:
  main checkout → no file written; linked worktree → file written; missing jq →
  exit 0; malformed transcript → exit 0 with empty narrative.
- **Exclude self-heal:** assert `.claude/status/` appears in `info/exclude` after
  a run and is not duplicated on a second run.
- **Reader skill:** manual — run `/worktree-status` against the real pda
  worktrees and eyeball the report; confirm a worktree with no STATUS.md is
  flagged stale, and the nested worktree is handled.

## Open risks / notes

- Plugin Stop-hook stdin field names (`cwd`, `transcript_path`) confirmed via
  claude-code-guide. Some Stop-specific fields (`turn_number`, `stop_reason`,
  `stop_hook_active`) were reported as not fully documented; we depend on none of
  them, so this is low risk.
- Worktree-vs-main detection via `/worktrees/` in the absolute git dir is the
  robust discriminator; verify on the user's actual setup during implementation.
- Frontend lowercase-text rule (pda) does **not** apply here — this is the
  skillet repo, not the pda app.
