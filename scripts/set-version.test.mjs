import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, cpSync } from "node:fs";
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
