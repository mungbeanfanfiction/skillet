import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { join } from "node:path";

const SCRIPT = join(import.meta.dirname, "..", "plugins", "skillet", "hooks", "block-verbose-comments.sh");

// The hook always exits 0, emitting JSON only when it flags something — hence
// the empty-stdout case below means "no flag".
function runHook(toolInput) {
  const input = JSON.stringify({ tool_input: toolInput, hook_event_name: "PreToolUse" });
  const stdout = execFileSync("bash", [SCRIPT], { input, encoding: "utf8" }).trim();
  if (!stdout) return { stdout, decision: null, reason: null };
  const parsed = JSON.parse(stdout);
  return {
    stdout,
    decision: parsed.hookSpecificOutput?.permissionDecision ?? null,
    reason: parsed.hookSpecificOutput?.permissionDecisionReason ?? "",
  };
}

test("flags line-by-line narration comments", () => {
  const { decision, reason } = runHook({
    file_path: "foo.js",
    new_string: "// increment i\ni++;\n// return the result\nreturn result;",
  });
  assert.equal(decision, "ask");
  assert.match(reason, /Narration comments/);
});

test("flags Step N play-by-play comments", () => {
  const { decision, reason } = runHook({
    file_path: "x.py",
    content: "# Step 1: open\nf = open(p)\n# Step 2: read\nd = f.read()",
  });
  assert.equal(decision, "ask");
  assert.match(reason, /Step-by-step/);
});

test("flags comment-heavy edits (>50% comment lines)", () => {
  const { decision, reason } = runHook({
    file_path: "a.ts",
    new_string: "// a\n// b\n// c\n// d\n// e\nconst x=1;\nconst y=2;\nconst z=3;",
  });
  assert.equal(decision, "ask");
  assert.match(reason, /Comment-heavy/);
});

test("stays silent on clean why-comments", () => {
  const { stdout, decision } = runHook({
    file_path: "foo.js",
    new_string: "// Cache busts hourly: upstream rotates the token on the hour.\nconst t = computeToken();\nreturn t;",
  });
  assert.equal(stdout, "");
  assert.equal(decision, null);
});

test("skips non-source files (markdown)", () => {
  const { stdout } = runHook({
    file_path: "README.md",
    content: "# Heading\n# Step 1: do thing\n# increment the counter\n# return the value",
  });
  assert.equal(stdout, "", "markdown is content, not code comments — must not flag");
});

test("ignores a shebang and proceeds on normal scripts", () => {
  const { stdout } = runHook({
    file_path: "run.sh",
    content: "#!/usr/bin/env bash\nset -e\necho hi\nexit 0",
  });
  assert.equal(stdout, "", "shebang must not count as a comment");
});

test("exits silently with no parseable content", () => {
  const { stdout } = runHook({ file_path: "foo.js" });
  assert.equal(stdout, "");
});
