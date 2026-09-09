# skillet

Personal marketplace of agent skills (Claude Code and Cursor).

Two plugins: **skillet** (PR automation, worktrees, GitHub issues) and **vault**
(capturing sessions into an Obsidian vault).

## Install

### Claude Code

```bash
/plugin marketplace add mungbeanfanfiction/skillet
/plugin install skillet@skillet
/plugin install vault@skillet
```

### Cursor

**Team marketplace (Teams / Enterprise):** Dashboard → Settings → Plugins → Import Marketplace → `https://github.com/mungbeanfanfiction/skillet`, then install **skillet** from **Customize → Plugins**.

**Local development:** symlink the plugin and reload the window:

```bash
ln -s /path/to/skillet/plugins/skillet ~/.cursor/plugins/local/skillet
```

## Skillet skills

| Skill | What it does |
|---|---|
| `/open-pr` | Open a draft PR using the repo's PR template, prefilled from the linked issue or conversation context. Runs `/check-verbosity` first as a pre-PR gate. |
| `/check-verbosity` | Diff the branch vs base and flag verbosity to trim before a PR — redundant comments, leftover debug logs, dead scaffolding, wordy prose. Read-only by default; `--fix` applies safe trims. Never opens/pushes. |
| `/create-worktree` | Create a git worktree for a branch or GitHub issue, with env files symlinked. |
| `/delete-worktree` | Safely remove a worktree (checks for uncommitted/unpushed work). |
| `/cleanup-worktrees` | Survey all worktrees and bulk-remove ones whose branches are merged or whose PRs are closed. |
| `/review-fix` | Review a PR with `/code-review` and auto-fix high/medium findings, looping until clean; unsafe findings become PR comments. |
| `/resolve-conflicts` | Bring a PR up to date with its base and auto-resolve only safe conflicts (lock/generated/import-only), leaving the branch pushable; escalate cleanly when a conflict needs human judgment. |
| `/explore-issue` | Deep-dive one GitHub issue: worktree off main, parallel Explore agents, findings spec, draft PR, and an issue comment. Routed by the `explore` label. |
| `/create-issue` | Create a GitHub issue from the conversation, auto-labeled (queue/type/area/priority); creates any missing labels first. |
| `/create-epic` | Create a GitHub epic (parent issue + child issues) from the conversation, all filed under a new GitHub Project. |
| `/create-skill` | Scaffold a new skill directory + SKILL.md, following this plugin's frontmatter conventions; always decides on a `model:` pin so new skills don't skip it. |
| `/deslop` | Strip AI tells out of prose and rewrite it in Leah's voice — concise, concrete, no scaffolding. Reports by default; `--fix` rewrites. Also the shared writing standard other skills follow before writing prose. |
| `/triage-issue` | First-pass triage of an existing GitHub issue: assess, enrich a thin body, apply canonical labels (incl. `auto`), set a milestone, and post a triage comment. The inverse of `/create-issue`. |
| `/sync-repo-labels` | Seed/sync the canonical label set into a repo (additive + drift-fix, never deletes). |
| `/init-repo` | Bootstrap a repo to the standard setup: seed labels (via `/sync-repo-labels`), add a PR template if missing, optionally protect the default branch. Additive + idempotent. |
| `/worktree-status` | Report every worktree's WIP narrative (from `STATUS.md`) plus live git state; flags stale worktrees. |
| `/check-pr-comments` | One-shot: list a PR's new/unaddressed comments — inline review threads, review summaries, and top-level PR comments — excluding the agent's own, and distinguishing unaddressed from already-resolved. Read-only. |
| `/pr-fleet-manager` | Loop that watches your open PRs in the current repo: retries flaky CI, surfaces review comments, rebases safe conflicts, and prints a status digest. Starts in observation mode; never auto-merges or applies suggestions. |
| `/issue-supervisor` | ~5h loop: survey worktrees, restart stalled sessions, dispatch `auto`-labeled issues (or a `--file` checklist) to background sessions, groom the backlog. Watches its own open PRs each pass — dispatches follow-up sessions into a PR's worktree for new comments (via `check-pr-comments`) or merge conflicts (via `resolve-conflicts`), with per-PR de-dup. Opens draft PRs via `review-fix` + `open-pr`. |
| `/question-sweeper` | ~1h loop: route sessions parked on design questions to `docs/superpowers/questions/` + a GitHub comment, and re-dispatch once answered. |

## Skillet hooks

| Hook | What it does |
|---|---|
| Worktree guard (`PreToolUse`) | Before any `Edit`/`Write`/`NotebookEdit`, asks for confirmation if you're editing the **primary checkout** instead of a git worktree. Prevents concurrent sessions from clobbering each other in the shared main checkout. Worktrees proceed without a prompt. |
| Verbose-comment guard (`PreToolUse`) | Before an `Edit`/`Write` to a source file, asks for confirmation when the edit adds **overly verbose, low-value comments** — line-by-line narration that restates the code, `Step N` play-by-play, or comment-heavy diffs. Nudges comments toward explaining *why*, not *what*. Clean edits proceed without a prompt. |
| Slop guard (`PreToolUse`) | Before an `Edit`/`Write` to markdown, asks for confirmation when the prose reads as agent-written — stock vocabulary, contrast-frame rhythm, em-dash or bold density, scaffolding headings over thin content. Thresholds are relative to document length and calibrated against this repo. |

## Vault plugin

Captures Claude Code sessions into an Obsidian vault so you can look back on what
you worked on and what you learned doing it. Expects the vault at
`~/Documents/Obsidian Vault`, or `$OBSIDIAN_VAULT`.

| Skill | What it does |
|---|---|
| `/vault:log` | Distill a session into `10 Sessions/` with exact stats read from the transcript, and keep its project hub current. Judges whether the session is worth keeping and writes nothing when it isn't. |
| `/vault:insights` | Pull generalizable lessons into atomic notes in `30 Insights/`, deduped against what's there and backlinked to the source session. |
| `/vault:recall` | Search the vault before starting work — "have I hit this before?" |
| `/vault:review` | Roll up a week or month into `50 Reviews/`: what moved, what stalled, recurring themes. |
| `/vault:backfill` | Sweep `~/.claude/projects/` for sessions never logged and distill the ones worth keeping. |
| `/vault:lint` | Find broken wikilinks, orphans, and missing frontmatter before they silently empty a Bases dashboard. |

| Hook | What it does |
|---|---|
| Session ledger (`Stop`) | Scores the session's accumulated material each turn — turns, files, tool variety, errors, elapsed — and once it clears a loose bar, says so on stdout where Claude can read it and offer `/vault:log`. Fires at most once per session. It does not judge importance; that needs the transcript read, which is the skill's job. |
| Session queue (`SessionEnd`) | Writes one marker file for a session that ended unlogged, so `/vault:backfill` can find it. `SessionEnd` shares a 1.5s budget and can't prompt, so one small write is the only honest work to do there. |

State lives in `~/.claude/vault/` (`$VAULT_STATE_DIR` to override): `nudged/`,
`queue/`, and `logged/` markers.

## Layout

```
.claude-plugin/marketplace.json   # Claude Code marketplace manifest
.cursor-plugin/marketplace.json   # Cursor marketplace manifest
plugins/skillet/
├── plugin.json                   # Claude Code plugin manifest
├── .cursor-plugin/
│   └── plugin.json               # Cursor plugin manifest
├── hooks/
│   ├── hooks.json                # hook declarations
│   ├── block-main-checkout.sh    # worktree-guard logic
│   ├── block-verbose-comments.sh # verbose-comment guard
│   ├── block-slop.sh             # AI-prose guard
│   └── worktree-status.sh        # writes STATUS.md per worktree
└── skills/
    ├── open-pr/SKILL.md
    ├── check-verbosity/SKILL.md
    ├── create-worktree/SKILL.md
    ├── delete-worktree/SKILL.md
    ├── cleanup-worktrees/SKILL.md
    ├── review-fix/SKILL.md
    ├── resolve-conflicts/SKILL.md
    ├── explore-issue/SKILL.md
    ├── create-issue/SKILL.md
    ├── create-epic/SKILL.md
    ├── create-skill/SKILL.md
    ├── triage-issue/SKILL.md
    ├── sync-repo-labels/SKILL.md
    ├── init-repo/SKILL.md
    ├── worktree-status/SKILL.md
    ├── pr-fleet-manager/SKILL.md
    ├── check-pr-comments/
    │   ├── SKILL.md
    │   └── scripts/check-pr-comments.sh
    ├── _shared/labels.json
    ├── issue-supervisor/
    │   ├── SKILL.md
    │   ├── lib/supervisorlib/     # tested, stdlib-only deterministic logic
    │   └── scripts/               # survey / dispatch / restart / resume glue
    └── question-sweeper/
        ├── SKILL.md
        └── scripts/sweep.sh

plugins/vault/
├── plugin.json
├── .cursor-plugin/plugin.json
├── hooks/
│   ├── hooks.json
│   ├── session-ledger.sh         # Stop: score material, nudge toward /vault:log
│   └── queue-session.sh          # SessionEnd: queue unlogged sessions
├── scripts/
│   ├── session-stats.sh          # transcript -> stats JSON
│   └── session-stats.jq
└── skills/
    ├── _shared/vault-schema.md   # the contract every vault skill reads
    ├── log/SKILL.md
    ├── insights/SKILL.md
    ├── recall/SKILL.md
    ├── review/SKILL.md
    ├── backfill/SKILL.md
    └── lint/SKILL.md
```

## Issue automation

Two self-paced loops supervise `auto`-labeled issues (or a markdown checklist)
across worktrees in ANY repo:

- `/loop issue-supervisor` — ~5h: dispatch/restart/groom; opens draft PRs.
- `/loop question-sweeper` — ~1h: routes design questions to `docs/superpowers/questions/`.

Label an issue `auto` (or pass `--file <checklist>.md`) to enqueue it. Runtime
state lives in the target repo's `.claude/issue-supervisor/` (gitignore it).
Requires `python3` + `pytest` for the test suite, and `gh`/`jq`/`git`. See
`docs/superpowers/specs/2026-06-23-issue-supervisor-v2-design.md`.

## Versioning

Releases run on [semantic-release](https://semantic-release.gitbook.io/): every merge to
`main` is analyzed for [Conventional Commits](https://www.conventionalcommits.org/), and a
releasable merge updates `CHANGELOG.md` and pushes a `vX.Y.Z` repo tag.

**Each plugin versions independently.** `scripts/set-version.mjs` computes a bump per plugin
from the commits since the last tag that touched **that plugin's directory**, so a skillet
fix leaves `vault` untouched and vice versa. A plugin nothing touched keeps its version.

The commit *scope* is documentation; the **paths a commit changes** decide the bump. A commit
labelled `feat(vault):` that only edits `scripts/` bumps neither plugin. Keep the scope honest
anyway — it is how the history stays readable.

### Changelogs

Each plugin has its own `plugins/<name>/CHANGELOG.md`, written from the commits that
touched it, so a heading there always matches that plugin's `plugin.json`. A plugin nothing
touched gets no new section.

The root `CHANGELOG.md` covers the repo and is numbered by the repo tag, which is *not* any
plugin's version. Each entry therefore records which plugin versions that release shipped:

```
## [0.39.0](...) (2026-09-09)

Plugin versions: `skillet@0.38.0` (unchanged), `vault@0.1.0`
```

### Commit conventions

| Commit message | Bump | Example → from `0.2.0` |
|---|---|---|
| `fix: …` / `perf: …` / `revert: …` | patch | `0.2.1` |
| `feat: …` | minor | `0.3.0` |
| `<type>!: …` (e.g. `feat!:`, `fix!:`) | **major** | `1.0.0` |
| footer contains `BREAKING CHANGE: …` | **major** | `1.0.0` |
| `docs:` / `chore:` / `style:` / `test:` / `refactor:` / `build:` / `ci:` | none | no release |

Notes:

- The `!` must sit immediately before the colon: `feat!:` works, `feat !:` does not.
- `BREAKING CHANGE:` must be in the commit **body/footer**, not the subject line.
- Several commits touching one plugin take the highest bump among them.
- Commits that map to "none" still run the workflow, but it exits without releasing.

### Adding a plugin

Add it to `PLUGINS` in `scripts/set-version.mjs` and to the `plugins[]` array in both
marketplace manifests, in the same order. Three tests walk the repo and fail until you do,
so a new plugin cannot silently ship with a stale version. Start it at `0.0.0` and let its
first `feat:` produce `0.1.0`.
