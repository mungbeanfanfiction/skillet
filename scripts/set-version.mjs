import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
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

// Each plugin versions independently. Order matches the plugins[] arrays in both
// marketplace manifests.
export const PLUGINS = [
  { name: "skillet", dir: "plugins/skillet" },
  { name: "vault", dir: "plugins/vault" },
];

const MARKETPLACES = [".claude-plugin/marketplace.json", ".cursor-plugin/marketplace.json"];

/** Every version field this script owns. The coverage tests walk the repo against it. */
export const TARGETS = PLUGINS.flatMap((p, i) => [
  { rel: `${p.dir}/plugin.json`, path: ["version"], plugin: p.name },
  { rel: `${p.dir}/.cursor-plugin/plugin.json`, path: ["version"], plugin: p.name },
  ...MARKETPLACES.map((rel) => ({ rel, path: ["plugins", i, "version"], plugin: p.name })),
]);

/**
 * Which bump a set of conventional-commit messages implies.
 * Returns "major" | "minor" | "patch" | null.
 */
export function bumpFromCommits(messages) {
  let bump = null;
  const rank = { patch: 1, minor: 2, major: 3 };
  const raise = (b) => {
    if (!bump || rank[b] > rank[bump]) bump = b;
  };

  for (const msg of messages) {
    const subject = msg.split("\n", 1)[0];
    if (/^[a-z]+(\([^)]*\))?!:/.test(subject) || /^BREAKING[ -]CHANGE:/m.test(msg)) raise("major");
    else if (/^feat(\([^)]*\))?:/.test(subject)) raise("minor");
    else if (/^(fix|perf|revert)(\([^)]*\))?:/.test(subject)) raise("patch");
  }
  return bump;
}

/** Apply a bump to a semver string. */
export function applyBump(version, bump) {
  const [maj, min, pat] = version.split(".").map(Number);
  if (bump === "major") return `${maj + 1}.0.0`;
  if (bump === "minor") return `${maj}.${min + 1}.0`;
  if (bump === "patch") return `${maj}.${min}.${pat + 1}`;
  return version;
}

/** Commit messages since `since` that touched `dir`. Empty when git is unavailable. */
function commitsTouching(repoRoot, dir, since) {
  try {
    const range = since ? `${since}..HEAD` : "HEAD";
    const out = execFileSync(
      "git",
      ["log", range, "--no-merges", "--format=%B%x00", "--", dir],
      { cwd: repoRoot, encoding: "utf8" },
    );
    return out.split("\0").map((s) => s.trim()).filter(Boolean);
  } catch {
    return [];
  }
}

function lastTag(repoRoot) {
  try {
    return execFileSync("git", ["describe", "--tags", "--abbrev=0"], {
      cwd: repoRoot,
      encoding: "utf8",
    }).trim();
  } catch {
    return null; // no tags yet
  }
}

/**
 * Next version per plugin, derived from commits touching that plugin's directory
 * since the last tag. A plugin nothing touched keeps its current version, which
 * is the whole point: a skillet fix no longer churns vault.
 */
export function nextVersions(repoRoot) {
  const since = lastTag(repoRoot);
  const out = { _since: since };
  for (const p of PLUGINS) {
    const manifest = join(repoRoot, p.dir, "plugin.json");
    if (!existsSync(manifest)) continue;
    const current = JSON.parse(readFileSync(manifest, "utf8")).version;
    const bump = bumpFromCommits(commitsTouching(repoRoot, p.dir, since));
    out[p.name] = { current, bump, next: applyBump(current, bump) };
  }
  return out;
}

/** Write each plugin's computed version into every manifest that carries it. */
export function updateVersion(_repoVersion, repoRoot) {
  const versions = nextVersions(repoRoot);
  for (const { rel, path, plugin } of TARGETS) {
    const v = versions[plugin];
    if (!v) continue;
    setVersionInJson(join(repoRoot, rel), path, v.next);
  }
  return versions;
}

// CLI entry: node scripts/set-version.mjs [repo-version]
// The argument is semantic-release's repo version. It drives the git tag and
// CHANGELOG; plugin versions are computed from commits, not from it.
if (import.meta.filename === process.argv[1]) {
  const repoRoot = dirname(import.meta.dirname);
  const versions = updateVersion(process.argv[2], repoRoot);

  // Surfaced in the release log. "no tag found" means the checkout has no tags
  // (shallow clone?) and every commit was scanned, which over-bumps.
  console.log(
    versions._since
      ? `computing bumps from commits since ${versions._since}`
      : "WARNING: no tag found -- scanning all history; versions may over-bump",
  );

  for (const [name, v] of Object.entries(versions)) {
    if (name === "_since") continue;
    console.log(
      v.bump
        ? `${name}: ${v.current} -> ${v.next} (${v.bump})`
        : `${name}: ${v.current} (unchanged)`,
    );
  }
}
