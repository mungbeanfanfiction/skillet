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

// Build a transcript JSONL with user + assistant turns (Claude Code transcript shape).
function writeTranscript(lines) {
  const dir = mkdtempSync(join(tmpdir(), "wt-tr-"));
  const path = join(dir, "t.jsonl");
  writeFileSync(path, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
  return path;
}

function runHookWithTranscript(cwd, transcript) {
  const input = JSON.stringify({ cwd, transcript_path: transcript, hook_event_name: "Stop" });
  execFileSync("bash", [SCRIPT], { input, encoding: "utf8" });
}

test("captures last user prompt and last assistant line", () => {
  const { wt } = setupRepoWithWorktree();
  const transcript = writeTranscript([
    { type: "user", message: { role: "user", content: "first ask" } },
    { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "first reply" }] } },
    { type: "user", message: { role: "user", content: "add the login button" } },
    { type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "added the button and a test" }] } },
  ]);
  runHookWithTranscript(wt, transcript);
  const body = readFileSync(join(wt, ".claude", "status", "STATUS.md"), "utf8");
  assert.match(body, /add the login button/, "should capture the last user prompt");
  assert.match(body, /added the button and a test/, "should capture the last assistant line");
  assert.match(body, /updated:/, "should include a timestamp");
});

test("tolerates an empty transcript without erroring", () => {
  const { wt } = setupRepoWithWorktree();
  const transcript = writeTranscript([]); // empty
  // Must not throw (script must exit 0 even with no narrative).
  runHookWithTranscript(wt, transcript);
  const body = readFileSync(join(wt, ".claude", "status", "STATUS.md"), "utf8");
  assert.match(body, /branch: feat-x/);
});
