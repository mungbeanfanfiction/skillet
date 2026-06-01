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
| `/drain-queue` | Work a queue of tasks (GitHub label or markdown checklist) unattended: each task → worktree → checks → draft PR → `/review-fix`, then a run-report. |

## Layout

```
.claude-plugin/marketplace.json   # marketplace manifest
plugins/skillet/
├── plugin.json                   # plugin manifest
└── skills/
    ├── open-pr/SKILL.md
    ├── create-worktree/SKILL.md
    ├── delete-worktree/SKILL.md
    ├── cleanup-worktrees/SKILL.md
    ├── review-fix/SKILL.md
    └── drain-queue/SKILL.md
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
