# skillet

Personal marketplace of Claude Code skills.

## Install

```bash
/plugin marketplace add mungbeanfanfiction/skillet
/plugin install skillet@skillet
```

## Skills

| Skill | What it does |
|---|---|
| `/open-pr` | Open a draft PR using the repo's PR template, prefilled from the linked issue or conversation context. |
| `/create-worktree` | Create a git worktree for a branch or GitHub issue, with env files symlinked. |
| `/delete-worktree` | Safely remove a worktree (checks for uncommitted/unpushed work). |
| `/cleanup-worktrees` | Survey all worktrees and bulk-remove ones whose branches are merged or whose PRs are closed. |
| `/review-fix` | Review a PR with `/code-review` and auto-fix high/medium findings, looping until clean; unsafe findings become PR comments. |
| `/resolve-conflicts` | Bring a PR up to date with its base and auto-resolve only safe conflicts (lock/generated/import-only), leaving the branch pushable; escalate cleanly when a conflict needs human judgment. |
| `/explore-issue` | Deep-dive one GitHub issue: worktree off main, parallel Explore agents, findings spec, draft PR, and an issue comment. Routed by the `explore` label. |
| `/create-issue` | Create a GitHub issue from the conversation, auto-labeled (queue/type/area/priority); creates any missing labels first. |
| `/triage-issue` | First-pass triage of an existing GitHub issue: assess, enrich a thin body, apply canonical labels (incl. `auto`), set a milestone, and post a triage comment. The inverse of `/create-issue`. |
| `/sync-repo-labels` | Seed/sync the canonical label set into a repo (additive + drift-fix, never deletes). |
| `/init-repo` | Bootstrap a repo to the standard setup: seed labels (via `/sync-repo-labels`), add a PR template if missing, optionally protect the default branch. Additive + idempotent. |
| `/worktree-status` | Report every worktree's WIP narrative (from `STATUS.md`) plus live git state; flags stale worktrees. |
| `/check-pr-comments` | One-shot: list a PR's new/unaddressed comments — inline review threads, review summaries, and top-level PR comments — excluding the agent's own, and distinguishing unaddressed from already-resolved. Read-only. |
| `/pr-fleet-manager` | Loop that watches your open PRs in the current repo: retries flaky CI, surfaces review comments, rebases safe conflicts, and prints a status digest. Starts in observation mode; never auto-merges or applies suggestions. |
| `/issue-supervisor` | ~5h loop: survey worktrees, restart stalled sessions, dispatch `auto`-labeled issues (or a `--file` checklist) to background sessions, groom the backlog. Opens draft PRs via `review-fix` + `open-pr`. |
| `/question-sweeper` | ~1h loop: route sessions parked on design questions to `docs/superpowers/questions/` + a GitHub comment, and re-dispatch once answered. |

## Hooks

| Hook | What it does |
|---|---|
| Worktree guard (`PreToolUse`) | Before any `Edit`/`Write`/`NotebookEdit`, asks for confirmation if you're editing the **primary checkout** instead of a git worktree. Prevents concurrent sessions from clobbering each other in the shared main checkout. Worktrees proceed without a prompt. |
| Verbose-comment guard (`PreToolUse`) | Before an `Edit`/`Write` to a source file, asks for confirmation when the edit adds **overly verbose, low-value comments** — line-by-line narration that restates the code, `Step N` play-by-play, or comment-heavy diffs. Nudges comments toward explaining *why*, not *what*. Clean edits proceed without a prompt. |

## Layout

```
.claude-plugin/marketplace.json   # marketplace manifest
plugins/skillet/
├── plugin.json                   # plugin manifest
├── hooks/
│   ├── hooks.json                # hook declarations
│   ├── block-main-checkout.sh    # worktree-guard logic
│   ├── block-verbose-comments.sh # verbose-comment guard
│   └── worktree-status.sh        # writes STATUS.md per worktree
└── skills/
    ├── open-pr/SKILL.md
    ├── create-worktree/SKILL.md
    ├── delete-worktree/SKILL.md
    ├── cleanup-worktrees/SKILL.md
    ├── review-fix/SKILL.md
    ├── resolve-conflicts/SKILL.md
    ├── explore-issue/SKILL.md
    ├── create-issue/SKILL.md
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

Versions are managed automatically by [semantic-release](https://semantic-release.gitbook.io/).
Every merge to `main` is analyzed for [Conventional Commits](https://www.conventionalcommits.org/);
the highest bump among the merged commits wins. On a releasable merge, CI bumps
the version in `plugins/skillet/plugin.json` and `.claude-plugin/marketplace.json`,
updates `CHANGELOG.md`, and pushes a `vX.Y.Z` tag — no manual step required.

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
- A release with both a `feat:` and a `fix:` takes the higher bump (minor).
- Commits that map to "none" still run the workflow, but it exits without releasing.
