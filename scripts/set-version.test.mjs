import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, cpSync, readdirSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { setVersionInJson, TARGETS } from "./set-version.mjs";

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
