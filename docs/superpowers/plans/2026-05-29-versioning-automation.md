# Versioning Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Zero-click semantic versioning on every merge to `main`, driven by Conventional Commits, that bumps both JSON version fields, maintains a CHANGELOG, and pushes a git tag.

**Architecture:** A GitHub Actions workflow runs `semantic-release` on push to `main`. semantic-release computes the next version from commit messages, prepends release notes to `CHANGELOG.md`, runs a small Node script (`scripts/set-version.mjs`) via `@semantic-release/exec` to edit the two JSON version fields, then commits and tags via `@semantic-release/git`. No registry publish, no GitHub Release page.

**Tech Stack:** semantic-release, GitHub Actions, Node (ESM script), Conventional Commits.

---

## File Structure

- Create: `package.json` — private, holds release-toolchain devDependencies only.
- Create: `scripts/set-version.mjs` — edits the two JSON version fields in place.
- Create: `scripts/set-version.test.mjs` — unit tests for the script (node:test).
- Create: `scripts/__fixtures__/plugin.json` — fixture copy for tests.
- Create: `scripts/__fixtures__/marketplace.json` — fixture copy for tests.
- Create: `.releaserc.json` — semantic-release plugin config.
- Create: `.github/workflows/release.yml` — CI workflow.
- Create: `CHANGELOG.md` — seeded header.
- Create: `.gitignore` — ignore `node_modules/`.

---

### Task 1: Project scaffolding (package.json + .gitignore)

**Files:**
- Create: `package.json`
- Create: `.gitignore`

- [ ] **Step 1: Create `.gitignore`**

```
node_modules/
```

- [ ] **Step 2: Create `package.json`**

```json
{
  "name": "skillet-release-tooling",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "description": "Release tooling for the skillet marketplace (not published).",
  "scripts": {
    "test": "node --test scripts/"
  },
  "devDependencies": {
    "@semantic-release/changelog": "^6.0.3",
    "@semantic-release/commit-analyzer": "^13.0.1",
    "@semantic-release/exec": "^7.1.0",
    "@semantic-release/git": "^10.0.1",
    "@semantic-release/release-notes-generator": "^14.0.3",
    "conventional-changelog-conventionalcommits": "^8.0.0",
    "semantic-release": "^24.2.3"
  }
}
```

- [ ] **Step 3: Install dependencies**

Run: `npm install`
Expected: creates `node_modules/` and `package-lock.json`, no errors.

- [ ] **Step 4: Commit**

```bash
git add .gitignore package.json package-lock.json
git commit -m "build: add release tooling scaffolding"
```

---

### Task 2: set-version.mjs script (TDD)

**Files:**
- Create: `scripts/__fixtures__/plugin.json`
- Create: `scripts/__fixtures__/marketplace.json`
- Create: `scripts/set-version.test.mjs`
- Create: `scripts/set-version.mjs`

The script is a CLI: `node scripts/set-version.mjs <version>`. It updates
`$.version` in `plugins/skillet/plugin.json` and `$.plugins[0].version` in
`.claude-plugin/marketplace.json`, relative to the repo root (the script's
parent-of-parent dir). For testability, the core logic is an exported
`setVersionInJson(filePath, jsonPath, version)` function plus an exported
`updateVersion(version, repoRoot)`; the CLI entry calls `updateVersion`.

- [ ] **Step 1: Create fixtures**

`scripts/__fixtures__/plugin.json`:
```json
{
  "name": "skillet",
  "version": "0.1.0",
  "description": "test fixture"
}
```

`scripts/__fixtures__/marketplace.json`:
```json
{
  "name": "skillet",
  "plugins": [
    { "name": "skillet", "version": "0.1.0", "source": "./plugins/skillet" }
  ]
}
```

- [ ] **Step 2: Write the failing tests**

`scripts/set-version.test.mjs`:
```javascript
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, cpSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setVersionInJson } from "./set-version.mjs";

function tmpFixture(name) {
  const dir = mkdtempSync(join(tmpdir(), "setver-"));
  const dest = join(dir, name);
  cpSync(join(import.meta.dirname, "__fixtures__", name), dest);
  return dest;
}

test("setVersionInJson updates a top-level version field", () => {
  const file = tmpFixture("plugin.json");
  setVersionInJson(file, ["version"], "1.2.3");
  const json = JSON.parse(readFileSync(file, "utf8"));
  assert.equal(json.version, "1.2.3");
  assert.equal(json.name, "skillet"); // untouched
});

test("setVersionInJson updates a nested array version field", () => {
  const file = tmpFixture("marketplace.json");
  setVersionInJson(file, ["plugins", 0, "version"], "1.2.3");
  const json = JSON.parse(readFileSync(file, "utf8"));
  assert.equal(json.plugins[0].version, "1.2.3");
  assert.equal(json.plugins[0].name, "skillet"); // untouched
});

test("setVersionInJson throws when the path is missing", () => {
  const file = tmpFixture("plugin.json");
  assert.throws(() => setVersionInJson(file, ["nope", "missing"], "1.2.3"),
    /missing|not found/i);
});

test("setVersionInJson throws when the file does not exist", () => {
  assert.throws(() => setVersionInJson(join(tmpdir(), "does-not-exist.json"), ["version"], "1.2.3"));
});

test("setVersionInJson ends file with a trailing newline", () => {
  const file = tmpFixture("plugin.json");
  setVersionInJson(file, ["version"], "9.9.9");
  assert.ok(readFileSync(file, "utf8").endsWith("\n"));
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `node --test scripts/set-version.test.mjs`
Expected: FAIL — `Cannot find module './set-version.mjs'` / `setVersionInJson is not a function`.

- [ ] **Step 4: Write the implementation**

`scripts/set-version.mjs`:
```javascript
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

/**
 * Set a version value at a path of keys/indices within a JSON file, in place.
 * Preserves 2-space indentation and a trailing newline.
 * Throws if the file is unreadable or the path does not resolve.
 */
export function setVersionInJson(filePath, path, version) {
  const raw = readFileSync(filePath, "utf8");
  const json = JSON.parse(raw);

  let node = json;
  for (let i = 0; i < path.length - 1; i++) {
    const key = path[i];
    if (node == null || !(key in node)) {
      throw new Error(`Path segment "${key}" not found in ${filePath}`);
    }
    node = node[key];
  }
  const last = path[path.length - 1];
  if (node == null || !(last in node)) {
    throw new Error(`Version field "${last}" missing in ${filePath}`);
  }
  node[last] = version;

  writeFileSync(filePath, JSON.stringify(json, null, 2) + "\n");
}

const TARGETS = [
  { rel: "plugins/skillet/plugin.json", path: ["version"] },
  { rel: ".claude-plugin/marketplace.json", path: ["plugins", 0, "version"] },
];

/** Update both manifest version fields relative to repoRoot. */
export function updateVersion(version, repoRoot) {
  for (const { rel, path } of TARGETS) {
    setVersionInJson(join(repoRoot, rel), path, version);
  }
}

// CLI entry: node scripts/set-version.mjs <version>
if (import.meta.filename === process.argv[1]) {
  const version = process.argv[2];
  if (!version) {
    console.error("Usage: node scripts/set-version.mjs <version>");
    process.exit(1);
  }
  const repoRoot = dirname(import.meta.dirname); // scripts/ -> repo root
  updateVersion(version, repoRoot);
  console.log(`Set version ${version} in manifests.`);
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `node --test scripts/set-version.test.mjs`
Expected: PASS — all 5 tests pass.

- [ ] **Step 6: Manually verify the CLI end-to-end (then revert the change)**

Run: `node scripts/set-version.mjs 9.9.9 && git --no-pager diff plugins/skillet/plugin.json .claude-plugin/marketplace.json`
Expected: both files show `version` changed to `9.9.9`.
Then revert ONLY those two files: `git checkout -- plugins/skillet/plugin.json .claude-plugin/marketplace.json`
(Note: this revert is explicitly part of verifying the script and is safe — these two files have no other uncommitted changes at this point.)

- [ ] **Step 7: Commit**

```bash
git add scripts/
git commit -m "feat: add set-version script for manifest version bumps"
```

---

### Task 3: semantic-release config + CHANGELOG seed

**Files:**
- Create: `.releaserc.json`
- Create: `CHANGELOG.md`

- [ ] **Step 1: Create `.releaserc.json`**

```json
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

- [ ] **Step 2: Create seeded `CHANGELOG.md`**

```markdown
# Changelog

All notable changes to this project are documented here. This file is
maintained automatically by semantic-release.
```

- [ ] **Step 3: Validate config loads (dry run, expected to be inert offline)**

Run: `npx semantic-release --dry-run --no-ci || true`
Expected: semantic-release starts and loads the config without a "plugin not found" or JSON parse error. It will likely stop early complaining about authentication/CI environment or git remote — that is fine; we are only confirming the config and plugins resolve. A `SyntaxError` or "Cannot find module '@semantic-release/...'" is a FAILURE to fix.

- [ ] **Step 4: Commit**

```bash
git add .releaserc.json CHANGELOG.md
git commit -m "build: configure semantic-release"
```

---

### Task 4: GitHub Actions release workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create the workflow**

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
      contents: write
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          persist-credentials: false
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: "lts/*"
      - name: Install dependencies
        run: npm clean-install
      - name: Release
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: npx semantic-release
```

- [ ] **Step 2: Lint YAML syntax**

Run: `node -e "const yaml=require('node:fs').readFileSync('.github/workflows/release.yml','utf8'); if(!/semantic-release/.test(yaml)) throw new Error('bad'); console.log('ok')"`
Expected: prints `ok`. (Confirms file exists and is readable; GitHub validates schema on push.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "ci: add release workflow"
```

---

### Task 5: Documentation + first-run baseline note

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a "Versioning" section to `README.md`**

Append after the existing content:
```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document automated versioning"
```

---

## Self-Review

**Spec coverage:**
- Trigger on merge to main → Task 4 workflow. ✓
- Conventional Commits bump → `.releaserc.json` commit-analyzer (Task 3). ✓
- Both JSON fields → `set-version.mjs` (Task 2) + exec plugin (Task 3). ✓
- CHANGELOG → changelog plugin + seed (Task 3). ✓
- Git tag, no Release page → no `@semantic-release/github`; git plugin pushes tag (Task 3). ✓
- Loop guard `[skip ci]` → git plugin message (Task 3). ✓
- First-run baseline tag → documented (Task 5). ✓
- Tests for set-version → Task 2 (node:test). ✓

**Placeholder scan:** No TBD/TODO; all code blocks complete.

**Type consistency:** `setVersionInJson(filePath, path, version)` and `updateVersion(version, repoRoot)` signatures are consistent between the implementation (Task 2 Step 4) and tests (Task 2 Step 2). The `TARGETS` paths match the jsonpaths in the spec.
