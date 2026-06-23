import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dirname, "..", "plugins", "skillet", "hooks", "worktree-status.sh");

function git(cwd, ...args) {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

// Build a main repo with one commit and one linked worktree. Returns { main, wt }.
function setupRepoWithWorktree() {
  const main = mkdtempSync(join(tmpdir(), "wt-main-"));
  git(main, "init", "-q", "-b", "main");
  git(main, "config", "user.email", "t@t.com");
  git(main, "config", "user.name", "t");
  writeFileSync(join(main, "a.txt"), "hello\n");
  git(main, "add", "a.txt");
  git(main, "commit", "-q", "-m", "init");
  const wt = join(main, ".claude", "worktrees", "feat-x");
  mkdirSync(join(main, ".claude", "worktrees"), { recursive: true });
  git(main, "worktree", "add", "-q", "-b", "feat-x", wt);
  return { main, wt };
}

// Run the hook script with the given cwd as the stdin `cwd`. Uses a throwaway transcript.
function runHook(cwd) {
  const transcript = join(mkdtempSync(join(tmpdir(), "wt-tr-")), "t.jsonl");
  writeFileSync(transcript, "");
  const input = JSON.stringify({ cwd, transcript_path: transcript, hook_event_name: "Stop" });
  execFileSync("bash", [SCRIPT], { input, encoding: "utf8" });
}

test("writes STATUS.md when cwd is a linked worktree", () => {
  const { wt } = setupRepoWithWorktree();
  runHook(wt);
  const statusPath = join(wt, ".claude", "status", "STATUS.md");
  assert.ok(existsSync(statusPath), "STATUS.md should be created in the worktree");
  const body = readFileSync(statusPath, "utf8");
  assert.match(body, /branch: feat-x/);
});

test("does NOT write STATUS.md when cwd is the main checkout", () => {
  const { main } = setupRepoWithWorktree();
  runHook(main);
  const statusPath = join(main, ".claude", "status", "STATUS.md");
  assert.equal(existsSync(statusPath), false, "main checkout must not get a STATUS.md");
});
