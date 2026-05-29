# Versioning Automation — Design

**Date:** 2026-05-29
**Status:** Approved for planning

## Goal

Automatically bump the project version on every merge to `main`, with **zero
manual clicks**, driven by Conventional Commit messages. On release, also:

- Update the two version fields in the repo's JSON manifests.
- Maintain a `CHANGELOG.md`.
- Create and push a git tag (`vX.Y.Z`).

## Context

`skillet` is a Claude Code skills marketplace. It is **not** an npm package and
has no `package.json`. The version `0.1.0` currently lives in two places that
must stay in sync:

- `plugins/skillet/plugin.json` → `$.version`
- `.claude-plugin/marketplace.json` → `$.plugins[0].version`

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Trigger | On merge/push to `main` (CI, GitHub Actions) |
| Bump size | Conventional Commits (`feat:`→minor, `fix:`→patch, `feat!:`/`BREAKING CHANGE`→major) |
| Extra outputs | Git tag + `CHANGELOG.md` (no standalone GitHub Release page desired) |
| Tooling | `semantic-release` (pure off-the-shelf, fully zero-click) |

## Tool choice: semantic-release

`release-please` was ruled out because its model is a gated "release PR" that
requires a one-click merge — not zero-click. `semantic-release` runs on every
push to `main`, computes the next version from commits, and releases inline
with no human step. It is npm-oriented, so this repo will gain minimal Node
scaffolding (`package.json` + dev-deps) used **only** to run the release
toolchain — nothing is published to npm.

## Components

### 1. `package.json` (new)

Minimal, `"private": true`, no publish. Holds devDependencies for the release
toolchain and pins versions:

- `semantic-release`
- `@semantic-release/commit-analyzer`
- `@semantic-release/release-notes-generator`
- `@semantic-release/changelog`
- `@semantic-release/exec`
- `@semantic-release/git`
- `conventional-changelog-conventionalcommits` (for the `conventionalcommits` preset)

`"version"` in this file is irrelevant to releases (it is not one of the two
synced fields) and will be left at `0.0.0` / `private`.

### 2. `.releaserc.json` (new)

```jsonc
{
  "branches": ["main"],
  "plugins": [
    ["@semantic-release/commit-analyzer", { "preset": "conventionalcommits" }],
    ["@semantic-release/release-notes-generator", { "preset": "conventionalcommits" }],
    "@semantic-release/changelog",
    ["@semantic-release/exec", {
      "prepareCmd": "node scripts/set-version.mjs ${nextRelease.version}"
    }],
    ["@semantic-release/git", {
      "assets": [
        "CHANGELOG.md",
        "plugins/skillet/plugin.json",
        ".claude-plugin/marketplace.json"
      ],
      "message": "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}"
    }]
  ]
}
```

Notes:
- **No `@semantic-release/npm`** → nothing publishes to the registry.
- **No `@semantic-release/github`** → no standalone GitHub Release page is
  created (matches the "git tag + CHANGELOG only" decision). The git **tag** is
  still created by semantic-release's core release step and pushed by
  `@semantic-release/git`.
- `[skip ci]` in the commit message prevents the release commit from
  re-triggering the workflow (infinite-loop guard).

### 3. `scripts/set-version.mjs` (new)

Tiny Node script invoked by `@semantic-release/exec` with the computed version.
Edits the two JSON fields in place, preserving formatting/indentation as much
as practical:

- `plugins/skillet/plugin.json` → set `.version`
- `.claude-plugin/marketplace.json` → set `.plugins[0].version`

It reads, parses, mutates, and writes each file. Fails loudly (non-zero exit) if
either file or field is missing, so a malformed repo aborts the release rather
than producing a half-updated state.

### 4. `.github/workflows/release.yml` (new)

```yaml
name: Release
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write      # push tag + release commit
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0    # full history for commit analysis
          persist-credentials: false
      - uses: actions/setup-node@v4
        with:
          node-version: "lts/*"
      - run: npm clean-install
      - run: npx semantic-release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### 5. `CHANGELOG.md` (new, seeded empty)

Created/maintained by `@semantic-release/changelog`. Seeded with a minimal
header so the first run has something to prepend to.

## Data flow

```
merge to main
  → workflow runs semantic-release
    → commit-analyzer reads commits since last tag → next version
    → release-notes-generator builds notes
    → changelog plugin prepends notes to CHANGELOG.md
    → exec runs set-version.mjs → edits both JSON files
    → git plugin commits [CHANGELOG + 2 JSON files] with [skip ci], tags vX.Y.Z, pushes
```

## Error handling

- **No releasable commits** (only `docs:`/`chore:`/`style:` since last tag):
  semantic-release exits 0 without releasing. No bump, no tag. Expected.
- **First run:** with existing `0.1.0` and no prior tag, semantic-release treats
  the repo as having no released version and will publish `1.0.0` by default
  **unless** seeded. To preserve current `0.x` line, we seed a baseline tag
  `v0.1.0` at the current commit before the first workflow run (documented as a
  one-time manual step in the plan).
- **set-version.mjs failure:** non-zero exit aborts the release before the git
  commit/tag, leaving the repo unchanged.
- **Loop guard:** `[skip ci]` on the release commit prevents re-triggering.

## Permissions / setup gotchas

- Workflow needs `contents: write` (granted in YAML above).
- Default `GITHUB_TOKEN` is sufficient; no PAT required since we don't trigger
  downstream workflows from the release commit.
- Repo Settings → Actions → Workflow permissions should allow read/write (or the
  job-level `contents: write` above covers it).

## Testing strategy

- **set-version.mjs:** unit-test against fixture copies of both JSON files —
  assert the correct field changes and untouched fields/formatting are
  preserved; assert it exits non-zero on a missing field/file.
- **Dry run:** `npx semantic-release --dry-run` locally (with `GITHUB_TOKEN`)
  against a branch to confirm the computed next version and notes without
  pushing.
- **End-to-end:** land a `fix:` commit on `main` in a throwaway test and confirm
  the tag, both JSON bumps, and CHANGELOG entry appear.

## Out of scope (YAGNI)

- Publishing to any registry.
- Standalone GitHub Release pages.
- Pre-release / maintenance branches (`next`, `beta`).
- Monorepo / per-package versioning.

## Open decision (minor, resolve during planning)

We dropped `@semantic-release/github` to avoid a GitHub Release page. If you
later decide a Release page (with notes) is actually fine/desirable, re-adding
that one plugin is a one-line change and removes the need to think about tag
pushing at all. Default for now: **no GitHub Release page.**
