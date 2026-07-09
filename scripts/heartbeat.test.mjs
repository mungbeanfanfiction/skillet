import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dirname, "..", "plugins", "skillet", "hooks", "heartbeat.sh");

function git(cwd, ...args) {
  return execFileSync("git", args, { cwd, encoding: "utf8" }).trim();
}

function setupRepoWithWorktree() {
  const main = mkdtempSync(join(tmpdir(), "hb-main-"));
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

function runHook(cwd, payload = {}) {
  const input = JSON.stringify({ cwd, hook_event_name: "PostToolUse", ...payload });
  execFileSync("bash", [SCRIPT], { input, encoding: "utf8" });
}

const heartbeatPath = (wt) => join(wt, ".claude", "status", "HEARTBEAT.md");

test("writes HEARTBEAT.md with tool name and timestamp in a linked worktree", () => {
  const { wt } = setupRepoWithWorktree();
  runHook(wt, { tool_name: "Bash" });
  const body = readFileSync(heartbeatPath(wt), "utf8");
  assert.match(body, /- updated: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/, "machine-readable timestamp");
  assert.match(body, /- last step: Bash/);
  assert.match(body, /- event: PostToolUse/);
});

test("does NOT write HEARTBEAT.md in the main checkout", () => {
  const { main } = setupRepoWithWorktree();
  runHook(main, { tool_name: "Bash" });
  assert.equal(existsSync(heartbeatPath(main)), false);
});

test("records the pipeline stage from task.md", () => {
  const { wt } = setupRepoWithWorktree();
  mkdirSync(join(wt, ".claude"), { recursive: true });
  writeFileSync(join(wt, ".claude", "task.md"), "## Pipeline stage\nci\n");
  runHook(wt, { tool_name: "Edit" });
  assert.match(readFileSync(heartbeatPath(wt), "utf8"), /- last step: Edit \(stage: ci\)/);
});

test("SessionEnd records the exit reason for post-mortem", () => {
  const { wt } = setupRepoWithWorktree();
  runHook(wt, { hook_event_name: "SessionEnd", reason: "other" });
  const body = readFileSync(heartbeatPath(wt), "utf8");
  assert.match(body, /- event: SessionEnd/);
  assert.match(body, /- exit reason: other/);
});

test("overwrites rather than appends, and PostToolUse carries no exit reason", () => {
  // A cold heartbeat with no exit reason is how the survey tells "died" from "exited".
  const { wt } = setupRepoWithWorktree();
  runHook(wt, { tool_name: "Read" });
  runHook(wt, { tool_name: "Write" });
  const body = readFileSync(heartbeatPath(wt), "utf8");
  assert.doesNotMatch(body, /Read/);
  assert.doesNotMatch(body, /exit reason/);
  assert.match(body, /- last step: Write/);
});

test("adds .claude/status/ to info/exclude exactly once (idempotent)", () => {
  const { main, wt } = setupRepoWithWorktree();
  runHook(wt, { tool_name: "Bash" });
  runHook(wt, { tool_name: "Bash" });
  const body = readFileSync(join(main, ".git", "info", "exclude"), "utf8");
  assert.equal(body.split("\n").filter((l) => l === ".claude/status/").length, 1);
});
