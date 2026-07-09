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

// 20k repetitions of `tmpl` (with %d substituted), enough to make a producer
// still be writing when a downstream `head` closes the pipe.
function line(tmpl) {
  return Array.from({ length: 20000 }, (_, i) => tmpl.replaceAll("%d", i) + "\n").join("");
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

test("a cross-ref or dependency note does not count as a why", () => {
  for (const second of ["# See models.py.", "# Requires psycopg2."]) {
    const { decision } = runHook({ file_path: "db.py", content: `# Database layer.\n${second}\nx = 1` });
    assert.equal(decision, "ask", `"${second}" describes what, not why`);
  }
});

test("counts avoids/avoiding as a why, but not the word 'avoidance'", () => {
  const why = runHook({ file_path: "buf.py", content: "# Buffered here.\n# This avoids a syscall per row.\nx = 1" });
  assert.equal(why.stdout, "");

  // The stem must not appear in the header, or `echoes_name` would flag this
  // regardless of the why-signal and the assertion would pass vacuously.
  const notWhy = runHook({ file_path: "buf.py", content: "# Avoidance wrapper.\n# Wraps the client.\nx = 1" });
  assert.equal(notWhy.decision, "ask");
});

test("spares a one-line header that does not restate the filename", () => {
  const { stdout } = runHook({ file_path: "auth.py", content: "# Helpers for the login flow.\ndef f(): pass" });
  assert.equal(stdout, "");
});

test("flags a one-line header that only restates the filename", () => {
  const { decision, reason } = runHook({ file_path: "session_store.py", content: "# Session store.\nx = 1" });
  assert.equal(decision, "ask");
  assert.match(reason, /restates the filename/);
});

test("a why-signal spares a header even when it names the file", () => {
  // Naming your subject is prose, not restatement — the filename echo must not
  // override a header that goes on to explain why.
  const { stdout } = runHook({
    file_path: "session_store.py",
    content: "# Session store: in-memory because Redis adds a deploy dependency.\n# Must stay process-local.\nx = 1",
  });
  assert.equal(stdout, "", "an explained header passes regardless of the filename echo");
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

// A license/copyright banner carries its exempt keyword on only ONE of its
// lines; the continuation lines ("All rights reserved.", the MIT permission
// grant) have none. Exemption must be sticky across the whole banner, else the
// continuation lines leak into the header and flag a standard OSS license.
test("spares a multi-line /* */ banner whose keyword is on one line only", () => {
  const { stdout } = runHook({
    file_path: "k.ts",
    content:
      "/*\n * Copyright 2026 Acme\n * All rights reserved.\n" +
      " * Permission is hereby granted, free of charge, to any person obtaining\n" +
      " * a copy of this software.\n */\nexport const f = () => 1",
  });
  assert.equal(stdout, "", "an OSS license block must not be flagged as what-narration");
});

test("spares a multi-line # banner whose keyword is on one line only", () => {
  const { stdout } = runHook({
    file_path: "lic.py",
    content: "# Copyright 2026 Acme\n# All rights reserved.\n# Portions adapted from upstream.\ndef f(): pass",
  });
  assert.equal(stdout, "", "a #-style license block must not be flagged");
});

// The banner exemption must not bleed past the banner. A license block, a blank
// line, then a genuine what-only header is still narration and must flag.
test("still flags a real what-header that follows a license banner", () => {
  const { decision, reason } = runHook({
    file_path: "auth.py",
    content:
      "# Copyright 2026 Acme\n\n# This module handles authentication.\n" +
      "# It exposes login() and logout().\ndef f(): pass",
  });
  assert.equal(decision, "ask");
  assert.match(reason, /Top-of-file comment block/);
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

// The hook's contract is that it never disrupts a session. It must therefore
// never feed a big producer into a consumer that closes the pipe early: the
// producer takes SIGPIPE, `set -o pipefail` turns that into 141, and `set -e`
// aborts. Both directions below crash without the here-string fixes.
test("survives a huge comment block on every heuristic (no SIGPIPE)", () => {
  const cases = {
    "top-of-file": { file_path: "big.py", content: line("# what line %d here.") + "x = 1" },
    narration: { file_path: "big.js", content: line("// increment i%d") + "x = 1;" },
    "step-N": { file_path: "step.js", content: line("// Step %d: do it") + "x = 1;" },
  };
  for (const [name, toolInput] of Object.entries(cases)) {
    // execFileSync throws on a non-zero exit, so reaching the assert means exit 0.
    const { decision } = runHook(toolInput);
    assert.equal(decision, "ask", `${name} should still flag a 20k-line block`);
  }
});

test("survives a huge code-first write (header scan exits on line 1)", () => {
  // The awk that extracts the leading comment block exits at the first
  // non-comment line — here, immediately — while the content is still being
  // written. That is the common case: any large source file not starting with
  // a comment. It must produce no finding and, above all, must not error.
  const { stdout } = runHook({ file_path: "big.py", content: "x = 1\n" + line("y%d = %d") });
  assert.equal(stdout, "");
});

test("tolerates a relative filename that starts with a dash", () => {
  // Unguarded, `basename "-rf.py"` parses the name as options and fails, which
  // `pipefail` + `set -e` turn into a hook-killing exit. Both a header that
  // would flag and plain code with no comments must survive.
  const flagged = runHook({ file_path: "-rf.py", content: "# What this is.\n# More of what.\nx = 1" });
  assert.equal(flagged.decision, "ask");

  const bare = runHook({ file_path: "--help.py", content: "x = 1" });
  assert.equal(bare.stdout, "");
});

test("tolerates CRLF line endings", () => {
  const { decision } = runHook({
    file_path: "auth.py",
    content: "# handles auth.\r\n# used by the router.\r\nx = 1\r\n",
  });
  assert.equal(decision, "ask");
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
