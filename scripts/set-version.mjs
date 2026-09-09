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

/** Commits since `since` that touched `dir`, as {hash, message}. */
function commitsTouching(repoRoot, dir, since) {
  try {
    const range = since ? `${since}..HEAD` : "HEAD";
    const out = execFileSync(
      "git",
      ["log", range, "--no-merges", "--format=%H%x1f%B%x1e", "--", dir],
      { cwd: repoRoot, encoding: "utf8" },
    );
    return out
      .split("\x1e")
      .map((r) => r.trim())
      .filter(Boolean)
      .map((r) => {
        const [hash, message] = r.split("\x1f");
        return { hash, message: (message || "").trim() };
      });
  } catch {
    return [];
  }
}

function repoUrl(repoRoot) {
  try {
    const url = execFileSync("git", ["config", "--get", "remote.origin.url"], {
      cwd: repoRoot,
      encoding: "utf8",
    }).trim();
    return url.replace(/^git@github\.com:/, "https://github.com/").replace(/\.git$/, "");
  } catch {
    return null;
  }
}

/**
 * A conventional-changelog-style section for one plugin's release. Only the
 * types that drive a bump appear, matching what the root changelog shows.
 */
export function renderChangelogSection(version, commits, { date, url } = {}) {
  const day = date || new Date().toISOString().slice(0, 10);
  const groups = { Features: [], "Bug Fixes": [], "Performance Improvements": [], Reverts: [] };
  const groupFor = { feat: "Features", fix: "Bug Fixes", perf: "Performance Improvements", revert: "Reverts" };

  for (const { hash, message } of commits) {
    const subject = message.split("\n", 1)[0];
    const m = subject.match(/^([a-z]+)(?:\(([^)]*)\))?!?:\s*(.+)$/);
    if (!m) continue;
    const [, type, scope, text] = m;
    const group = groupFor[type];
    if (!group) continue;
    const breaking = /!:/.test(subject) || /^BREAKING[ -]CHANGE:/m.test(message);
    const short = (hash || "").slice(0, 7);
    const link = url ? ` ([${short}](${url}/commit/${hash}))` : ` (${short})`;
    groups[group].push(`* ${breaking ? "**BREAKING** " : ""}${scope ? `**${scope}:** ` : ""}${text}${link}`);
  }

  let out = `## ${version} (${day})\n`;
  for (const [name, entries] of Object.entries(groups)) {
    if (!entries.length) continue;
    out += `\n### ${name}\n\n${entries.join("\n")}\n`;
  }
  return out;
}

/** Prepend a release section to a plugin's own CHANGELOG, creating it if needed. */
function writePluginChangelog(repoRoot, dir, section) {
  const file = join(repoRoot, dir, "CHANGELOG.md");
  const existing = existsSync(file) ? readFileSync(file, "utf8") : "";
  writeFileSync(file, section + (existing ? "\n" + existing : ""));
  return file;
}

/**
 * Record which plugin versions a repo release actually shipped, under the newest
 * heading in the root CHANGELOG. Without this the root file implies its own
 * version number is what shipped, which it is not.
 */
export function annotateRootChangelog(repoRoot, versions) {
  const file = join(repoRoot, "CHANGELOG.md");
  if (!existsSync(file)) return null;

  const line =
    "Plugin versions: " +
    PLUGINS.filter((p) => versions[p.name])
      .map((p) => {
        const v = versions[p.name];
        return `\`${p.name}@${v.next}\`${v.bump ? "" : " (unchanged)"}`;
      })
      .join(", ");

  const lines = readFileSync(file, "utf8").split("\n");
  const i = lines.findIndex((l) => /^#{1,3} \[?\d+\.\d+\.\d+/.test(l));
  if (i === -1) return null;
  if ((lines[i + 2] || "").startsWith("Plugin versions:")) return file; // idempotent

  lines.splice(i + 1, 0, "", line);
  writeFileSync(file, lines.join("\n"));
  return file;
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
    const commits = commitsTouching(repoRoot, p.dir, since);
    const bump = bumpFromCommits(commits.map((c) => c.message));
    out[p.name] = { current, bump, next: applyBump(current, bump), commits };
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

  const url = repoUrl(repoRoot);
  for (const p of PLUGINS) {
    const v = versions[p.name];
    if (!v || !v.bump) continue; // nothing shipped for this plugin
    writePluginChangelog(repoRoot, p.dir, renderChangelogSection(v.next, v.commits, { url }));
  }

  annotateRootChangelog(repoRoot, versions);
  return versions;
}

// CLI entry: node scripts/set-version.mjs [repo-version]
// The argument is semantic-release's repo version. It drives the git tag and the
// root CHANGELOG; plugin versions are computed from commits, not from it.
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
        ? `${name}: ${v.current} -> ${v.next} (${v.bump}, ${v.commits.length} commits)`
        : `${name}: ${v.current} (unchanged)`,
    );
  }
}
