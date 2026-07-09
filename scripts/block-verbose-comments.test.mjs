import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dirname, "..", "plugins", "skillet", "hooks", "block-verbose-comments.sh");

// The hook always exits 0, emitting JSON only when it flags something — hence
// the empty-stdout case below means "no flag".
function runHook(toolInput, env = {}) {
  const input = JSON.stringify({ tool_input: toolInput, hook_event_name: "PreToolUse" });
  const stdout = execFileSync("bash", [SCRIPT], {
    input,
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
  if (!stdout) return { stdout, decision: null, reason: null };
  const parsed = JSON.parse(stdout);
  return {
    stdout,
    decision: parsed.hookSpecificOutput?.permissionDecision ?? null,
    reason: parsed.hookSpecificOutput?.permissionDecisionReason ?? "",
  };
}

// Heuristic 4 only fires on text landing at the file top. For an Edit that
// means the file on disk must already start with old_string, so these cases
// need a real file rather than a synthetic path.
function withFile(name, body, fn) {
  const dir = mkdtempSync(join(tmpdir(), "skillet-hook-"));
  const path = join(dir, name);
  writeFileSync(path, body);
  try {
    return fn(path);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
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

test("flags a top-of-file block that describes what, with no why", () => {
  const { decision, reason } = runHook({
    file_path: "auth.py",
    content: "# This module handles authentication.\n# It exposes login() and logout().\n\ndef login(): pass",
  });
  assert.equal(decision, "ask");
  assert.match(reason, /Top-of-file comment block/);
});

test("spares a long top-of-file block that explains why", () => {
  const { stdout } = runHook({
    file_path: "auth.py",
    content:
      "# Callers must init the store before the router, otherwise the first\n" +
      "# request races the session load and 401s intermittently. Lazy-init\n" +
      "# instead deadlocks under gunicorn.\n\ndef login(): pass",
  });
  assert.equal(stdout, "", "a header dense with reasoning is the good kind of comment");
});

test("flags a top-of-file comment that just restates the filename", () => {
  const { decision, reason } = runHook({
    file_path: "session_store.py",
    content: "# Session store.\n# Keeps sessions in memory.\nx = 1",
  });
  assert.equal(decision, "ask");
  assert.match(reason, /restates the filename/);
});

test("spares a one-line header", () => {
  const { stdout } = runHook({ file_path: "auth.py", content: "# Auth helpers.\ndef f(): pass" });
  assert.equal(stdout, "");
});

test("spares shebang, license, and SPDX lines", () => {
  const { stdout } = runHook({
    file_path: "b.py",
    content: "#!/usr/bin/env python3\n# Copyright 2026 Acme\n# SPDX-License-Identifier: MIT\n\ndef f(): pass",
  });
  assert.equal(stdout, "");
});

test("spares a module docstring", () => {
  const { stdout } = runHook({
    file_path: "f.py",
    content: '"""Auth helpers.\n\nHandles login.\n"""\ndef f(): pass',
  });
  assert.equal(stdout, "", "a docstring is not a comment the toolchain wants removed");
});

test("flags a what-only /* */ block header", () => {
  const { decision, reason } = runHook({
    file_path: "g.ts",
    content: "/*\n * This module does auth.\n * It is used by the router.\n */\nexport const f = () => 1",
  });
  assert.equal(decision, "ask");
  assert.match(reason, /Top-of-file comment block/);
});

test("spares a /* */ block header that explains why", () => {
  const { stdout } = runHook({
    file_path: "g.ts",
    content:
      "/*\n * Kept separate from router.ts because a cyclic import otherwise\n" +
      " * breaks the esbuild bundle.\n */\nexport const f = () => 1",
  });
  assert.equal(stdout, "");
});

test("spares a /* */ license banner and a single-line pragma", () => {
  const banner = runHook({
    file_path: "h.ts",
    content: "/*\n * Copyright 2026 Acme\n * SPDX-License-Identifier: MIT\n */\nexport const f = () => 1",
  });
  assert.equal(banner.stdout, "");
  const pragma = runHook({ file_path: "j.ts", content: "/* eslint-disable */\nexport const f = () => 1" });
  assert.equal(pragma.stdout, "");
});

test("does not flag a comment block added mid-file", () => {
  withFile("mid.py", "def f():\n    return 1\n", (path) => {
    const { stdout } = runHook({
      file_path: path,
      old_string: "    return 1",
      new_string: "    # Computes the sum.\n    # Uses a fold.\n    return 1",
    });
    assert.equal(stdout, "", "heuristic 4 applies only at the top of a file");
  });
});

test("detects a top-of-file Edit whose old_string holds multibyte characters", () => {
  // `head -c` is byte-oriented, so a char-length comparison would misjudge the
  // em dash and silently skip the check.
  const header = "# Header — with em dash";
  withFile("uni.py", `${header}\ndef f(): pass\n`, (path) => {
    const { decision, reason } = runHook(
      {
        file_path: path,
        old_string: header,
        new_string: "# This file sets up things.\n# It also does other things.",
      },
      { LANG: "en_US.UTF-8", LC_ALL: "en_US.UTF-8" },
    );
    assert.equal(decision, "ask");
    assert.match(reason, /Top-of-file/);
  });
});

test("SKILLET_ALLOW_FILE_HEADERS=1 disables only the top-of-file heuristic", () => {
  const toolInput = { file_path: "auth.py", content: "# aaa\n# bbb\n# ccc\ndef f(): pass" };
  assert.match(runHook(toolInput).reason, /Top-of-file/);

  const off = runHook(toolInput, { SKILLET_ALLOW_FILE_HEADERS: "1" });
  assert.equal(off.stdout, "");

  // The other heuristics keep firing with the escape hatch set.
  const narration = runHook(
    { file_path: "foo.js", new_string: "// increment i\ni++;\n// return the result\nreturn result;" },
    { SKILLET_ALLOW_FILE_HEADERS: "1" },
  );
  assert.match(narration.reason, /Narration comments/);
});
