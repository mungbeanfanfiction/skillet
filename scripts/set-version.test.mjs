import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, cpSync, readdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { execFileSync } from "node:child_process";
import {
  setVersionInJson,
  TARGETS,
  bumpFromCommits,
  applyBump,
  nextVersions,
  renderChangelogSection,
  annotateRootChangelog,
} from "./set-version.mjs";

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

// --- TARGETS coverage --------------------------------------------------------
// A plugin absent from TARGETS ships a stale version and nothing errors. These
// walk the repo rather than restating the list, so adding a plugin fails here
// until TARGETS and the marketplaces both know about it.

test("TARGETS covers every plugin manifest in the repo", () => {
  const root = dirname(import.meta.dirname);
  const covered = new Set(TARGETS.map((t) => t.rel));
  for (const plugin of readdirSync(join(root, "plugins"))) {
    for (const rel of [
      `plugins/${plugin}/plugin.json`,
      `plugins/${plugin}/.cursor-plugin/plugin.json`,
    ]) {
      if (existsSync(join(root, rel))) {
        assert.ok(covered.has(rel), `${rel} exists but is missing from TARGETS`);
      }
    }
  }
});

test("TARGETS covers every marketplace plugin entry", () => {
  const root = dirname(import.meta.dirname);
  for (const rel of [".claude-plugin/marketplace.json", ".cursor-plugin/marketplace.json"]) {
    const { plugins } = JSON.parse(readFileSync(join(root, rel), "utf8"));
    plugins.forEach((_, i) => {
      const hit = TARGETS.some(
        (t) => t.rel === rel && t.path[0] === "plugins" && t.path[1] === i,
      );
      assert.ok(hit, `${rel} plugins[${i}] is missing from TARGETS`);
    });
  }
});

test("every marketplace entry points at a real plugin directory", () => {
  const root = dirname(import.meta.dirname);
  for (const rel of [".claude-plugin/marketplace.json", ".cursor-plugin/marketplace.json"]) {
    for (const p of JSON.parse(readFileSync(join(root, rel), "utf8")).plugins) {
      assert.ok(existsSync(join(root, p.source, "plugin.json")),
        `${rel}: ${p.name} -> ${p.source} has no plugin.json`);
    }
  }
});

// --- per-plugin versioning ---------------------------------------------------

test("bumpFromCommits maps conventional commits to a bump", () => {
  assert.equal(bumpFromCommits(["feat(vault): add thing"]), "minor");
  assert.equal(bumpFromCommits(["fix(vault): correct thing"]), "patch");
  assert.equal(bumpFromCommits(["perf(vault): speed up"]), "patch");
  assert.equal(bumpFromCommits(["chore(vault): tidy"]), null);
  assert.equal(bumpFromCommits(["docs(vault): note"]), null);
  assert.equal(bumpFromCommits([]), null);
});

test("bumpFromCommits takes the highest bump present", () => {
  assert.equal(bumpFromCommits(["fix(a): x", "feat(a): y", "chore(a): z"]), "minor");
  assert.equal(bumpFromCommits(["feat(a): y", "feat(a)!: breaking"]), "major");
  assert.equal(bumpFromCommits(["fix(a): x\n\nBREAKING CHANGE: gone"]), "major");
});

test("applyBump moves the right semver component", () => {
  assert.equal(applyBump("0.37.0", "minor"), "0.38.0");
  assert.equal(applyBump("0.37.2", "patch"), "0.37.3");
  assert.equal(applyBump("0.37.0", "major"), "1.0.0");
  assert.equal(applyBump("0.0.0", "minor"), "0.1.0");
  assert.equal(applyBump("1.2.3", null), "1.2.3");
});

// The property that matters: a commit touching one plugin must not move the other.
test("nextVersions bumps only the plugin a commit touched", () => {
  const repo = mkdtempSync(join(tmpdir(), "ver-"));
  const git = (...a) => execFileSync("git", a, { cwd: repo, stdio: "pipe" });

  for (const [dir, version] of [["plugins/skillet", "0.37.0"], ["plugins/vault", "0.0.0"]]) {
    mkdirSync(join(repo, dir), { recursive: true });
    writeFileSync(join(repo, dir, "plugin.json"), JSON.stringify({ name: dir, version }, null, 2) + "\n");
  }

  git("init", "-q", "-b", "main");
  git("config", "user.email", "t@t.t");
  git("config", "user.name", "t");
  git("config", "commit.gpgsign", "false");
  git("add", "-A");
  git("commit", "-qm", "chore: init");
  git("tag", "v0.37.0");

  writeFileSync(join(repo, "plugins/skillet/new.md"), "x\n");
  git("add", "-A");
  git("commit", "-qm", "feat(skillet): add a thing");

  const v = nextVersions(repo);
  assert.equal(v.skillet.next, "0.38.0", "skillet should bump");
  assert.equal(v.vault.next, "0.0.0", "vault must not move");
  assert.equal(v.vault.bump, null);
  // Reported so the release log shows which tag the range started from; absent
  // means no tags were reachable and all history was scanned.
  assert.equal(v._since, "v0.37.0");
});

// --- changelogs --------------------------------------------------------------

test("renderChangelogSection groups by type and skips non-releasing commits", () => {
  const out = renderChangelogSection(
    "0.1.0",
    [
      { hash: "a".repeat(40), message: "feat(vault): add thing" },
      { hash: "b".repeat(40), message: "fix(vault): correct thing" },
      { hash: "c".repeat(40), message: "chore(vault): tidy" },
      { hash: "d".repeat(40), message: "docs: notes" },
    ],
    { date: "2026-09-09" },
  );
  assert.match(out, /^## 0\.1\.0 \(2026-09-09\)/);
  assert.match(out, /### Features\n\n\* \*\*vault:\*\* add thing \(aaaaaaa\)/);
  assert.match(out, /### Bug Fixes\n\n\* \*\*vault:\*\* correct thing \(bbbbbbb\)/);
  assert.ok(!out.includes("tidy"), "chore must not appear");
  assert.ok(!out.includes("notes"), "docs must not appear");
});

test("renderChangelogSection marks breaking changes and links commits", () => {
  const out = renderChangelogSection(
    "1.0.0",
    [{ hash: "e".repeat(40), message: "feat(vault)!: drop old format" }],
    { date: "2026-09-09", url: "https://example.com/r" },
  );
  assert.match(out, /\*\*BREAKING\*\* \*\*vault:\*\* drop old format/);
  assert.match(out, /\(\[eeeeeee\]\(https:\/\/example\.com\/r\/commit\/e{40}\)\)/);
});

test("annotateRootChangelog records the plugin versions a release shipped", () => {
  const dir = mkdtempSync(join(tmpdir(), "cl-"));
  writeFileSync(
    join(dir, "CHANGELOG.md"),
    "## [0.39.0](x) (2026-09-09)\n\n### Features\n\n* something\n",
  );
  const versions = {
    skillet: { next: "0.38.0", bump: null },
    vault: { next: "0.1.0", bump: "minor" },
  };
  annotateRootChangelog(dir, versions);
  const out = readFileSync(join(dir, "CHANGELOG.md"), "utf8");
  assert.match(out, /Plugin versions: `skillet@0\.38\.0` \(unchanged\), `vault@0\.1\.0`/);
  assert.ok(out.indexOf("Plugin versions") < out.indexOf("### Features"), "must sit under the heading");

  // Re-running a release must not stack duplicate lines.
  annotateRootChangelog(dir, versions);
  assert.equal(readFileSync(join(dir, "CHANGELOG.md"), "utf8").match(/Plugin versions:/g).length, 1);
});
