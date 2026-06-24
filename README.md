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
| `/explore-issue` | Deep-dive one GitHub issue: worktree off main, parallel Explore agents, findings spec, draft PR, and an issue comment. Routed by the `explore` label. |
| `/create-issue` | Create a GitHub issue from the conversation, auto-labeled (queue/type/area/priority); creates any missing labels first. |
| `/triage-issue` | First-pass triage of an existing GitHub issue: assess, enrich a thin body, apply canonical labels (incl. `auto`), set a milestone, and post a triage comment. The inverse of `/create-issue`. |
| `/sync-repo-labels` | Seed/sync the canonical label set into a repo (additive + drift-fix, never deletes). |

## Hooks

| Hook | What it does |
|---|---|
| Worktree guard (`PreToolUse`) | Before any `Edit`/`Write`/`NotebookEdit`, asks for confirmation if you're editing the **primary checkout** instead of a git worktree. Prevents concurrent sessions from clobbering each other in the shared main checkout. Worktrees proceed without a prompt. |

## Layout

```
.claude-plugin/marketplace.json   # marketplace manifest
plugins/skillet/
├── plugin.json                   # plugin manifest
├── hooks/
│   ├── hooks.json                # hook declarations
│   └── block-main-checkout.sh    # worktree-guard logic
└── skills/
    ├── open-pr/SKILL.md
    ├── create-worktree/SKILL.md
    ├── delete-worktree/SKILL.md
    ├── cleanup-worktrees/SKILL.md
    ├── review-fix/SKILL.md
    ├── explore-issue/SKILL.md
    ├── create-issue/SKILL.md
    ├── triage-issue/SKILL.md
    ├── sync-repo-labels/SKILL.md
    └── _shared/labels.json
```

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
