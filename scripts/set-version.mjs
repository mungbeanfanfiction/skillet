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
