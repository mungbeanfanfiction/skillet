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

## Layout

```
.claude-plugin/marketplace.json   # marketplace manifest
plugins/skillet/
├── plugin.json                   # plugin manifest
└── skills/
    ├── open-pr/SKILL.md
    ├── create-worktree/SKILL.md
    ├── delete-worktree/SKILL.md
    └── cleanup-worktrees/SKILL.md
```

## Versioning

Versions are managed automatically by [semantic-release](https://semantic-release.gitbook.io/).
Merges to `main` are analyzed for [Conventional Commits](https://www.conventionalcommits.org/):

- `fix:` → patch, `feat:` → minor, `feat!:` / `BREAKING CHANGE` → major.

On a releasable merge, CI bumps the version in `plugins/skillet/plugin.json`
and `.claude-plugin/marketplace.json`, updates `CHANGELOG.md`, and pushes a
`vX.Y.Z` tag — no manual step required.

> **One-time setup:** before the first automated release, tag the current
> commit as the baseline so semantic-release continues the `0.x` line instead
> of jumping to `1.0.0`:
> ```bash
> git tag v0.1.0 && git push origin v0.1.0
> ```
