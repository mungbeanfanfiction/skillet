# Worktree Status Reporting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a skillet-plugin Stop hook that records each worktree's work-in-progress status to `.claude/status/STATUS.md`, plus a `/worktree-status` skill that reports the combined status of all worktrees.

**Architecture:** A passive Stop hook (registered in the plugin's `hooks/hooks.json`) runs `hooks/worktree-status.sh` on every turn end. The script detects whether `cwd` is a linked worktree (not main), self-excludes `.claude/status/` via `.git/info/exclude`, extracts the last user prompt + last assistant line from the transcript, and overwrites `STATUS.md`. The hook is purely passive (always exits 0, never blocks). A documented reader skill merges all `STATUS.md` files with live git state into one report.

**Tech Stack:** POSIX shell + `jq` (writer script), Node `node --test` `.test.mjs` (tests, matching existing skillet convention), Claude Code plugin hooks (`${CLAUDE_PLUGIN_ROOT}`), Markdown skill docs.

---

## File Structure

| File | Responsibility |
|---|---|
| `plugins/skillet/hooks/hooks.json` | Register the Stop hook → run the writer script. |
| `plugins/skillet/hooks/worktree-status.sh` | The writer: read stdin, detect worktree, self-exclude, write `STATUS.md`. |
| `scripts/worktree-status.test.mjs` | Node test that drives the shell script against a temp git repo + worktree. |
| `plugins/skillet/skills/worktree-status/SKILL.md` | The `/worktree-status` reader skill (documented procedure). |
| `plugins/skillet/skills/create-worktree/SKILL.md` | Modify: also exclude `.claude/status/` at scaffold time. |

Work happens on branch `feat-worktree-status` (already created off `origin/main`; the design spec is already committed there).

---

## Task 1: Writer script — worktree detection + main-checkout bail

**Files:**
- Create: `plugins/skillet/hooks/worktree-status.sh`
- Test: `scripts/worktree-status.test.mjs`

This task builds the script far enough to (a) read stdin JSON, (b) resolve git context, (c) bail with exit 0 when in the main checkout, and (d) write a minimal `STATUS.md` when in a linked worktree. Narrative extraction comes in Task 2.

- [ ] **Step 1: Write the failing test**

Create `scripts/worktree-status.test.mjs`. It builds a real temp git repo, adds a linked worktree, then runs the script with synthetic stdin for both the main checkout and the worktree.

```javascript
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/leahpeker/development/skillet && node --test "scripts/worktree-status.test.mjs"`
Expected: FAIL — the script does not exist yet (`bash: .../worktree-status.sh: No such file or directory`).

- [ ] **Step 3: Write the minimal script**

Create `plugins/skillet/hooks/worktree-status.sh`:

```bash
#!/usr/bin/env bash
# Skillet worktree-status Stop hook (writer).
# Passive: writes .claude/status/STATUS.md for linked worktrees only.
# Always exits 0 — never disrupts the session.
set -u

# Read the hook's stdin JSON. Bail quietly if jq is missing or input is unusable.
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)"
[ -n "$input" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || exit 0
[ -d "$cwd" ] || exit 0

# Must be inside a git repo.
toplevel="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
git_dir="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
common_dir="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || exit 0

# Linked-worktree detection: a linked worktree's git dir lives under
# <common>/worktrees/<name>, so it contains "/worktrees/". The main checkout's
# git dir equals the common dir and does not. Bail in main (no work in main).
case "$git_dir" in
  */worktrees/*) : ;;   # linked worktree → proceed
  *) exit 0 ;;          # main checkout → do nothing
esac

# Self-heal the local exclude so STATUS.md never pollutes git status / commits.
exclude_file="$common_dir/info/exclude"
mkdir -p "$(dirname "$exclude_file")"
touch "$exclude_file"
grep -qxF '.claude/status/' "$exclude_file" 2>/dev/null || printf '.claude/status/\n' >>"$exclude_file"

branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
dirty_count="$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

status_dir="$toplevel/.claude/status"
mkdir -p "$status_dir"
cat >"$status_dir/STATUS.md" <<EOF
# worktree status

- branch: $branch
- dirty files: $dirty_count
EOF

exit 0
```

Make it executable:

```bash
chmod +x /Users/leahpeker/development/skillet/plugins/skillet/hooks/worktree-status.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/leahpeker/development/skillet && node --test "scripts/worktree-status.test.mjs"`
Expected: PASS — both tests green (worktree gets STATUS.md with `branch: feat-x`; main checkout gets none).

- [ ] **Step 5: Commit**

```bash
cd /Users/leahpeker/development/skillet
git add plugins/skillet/hooks/worktree-status.sh scripts/worktree-status.test.mjs
git commit -m "feat: worktree-status writer detects linked worktree, bails in main"
```

---

## Task 2: Writer script — narrative extraction + timestamp + touched files

**Files:**
- Modify: `plugins/skillet/hooks/worktree-status.sh`
- Test: `scripts/worktree-status.test.mjs`

Add: last user prompt + last assistant line pulled from the transcript JSONL, an `updated:` timestamp, and a `## touched` section. All extraction must tolerate empty/malformed transcripts (fall back to empty, never error).

- [ ] **Step 1: Write the failing test (append to the existing test file)**

Append these tests to `scripts/worktree-status.test.mjs`. They write a small transcript JSONL with user and assistant messages and assert the narrative appears.

```javascript
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/leahpeker/development/skillet && node --test "scripts/worktree-status.test.mjs"`
Expected: FAIL — the two new tests fail because STATUS.md has no `updated:`, no last-ask, no last-reply text yet. (Task 1's tests still pass.)

- [ ] **Step 3: Add narrative extraction to the script**

In `plugins/skillet/hooks/worktree-status.sh`, add this block AFTER the `dirty_count=` line and BEFORE `status_dir=`. Then replace the `cat >"$status_dir/STATUS.md"` heredoc with the expanded version below.

Add extraction (transcript path comes from stdin JSON):

```bash
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

last_ask=""
last_did=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # Last user prompt: content may be a string or an array of blocks.
  last_ask="$(jq -rs '
    [ .[] | select(.type=="user")
          | (.message.content // .content) ] | last
    | if type=="array" then (map(select(.type=="text").text) | join(" "))
      elif type=="string" then .
      else "" end // ""' "$transcript" 2>/dev/null | head -c 200)"
  # Last assistant text block.
  last_did="$(jq -rs '
    [ .[] | select(.type=="assistant")
          | (.message.content // .content) ] | last
    | if type=="array" then (map(select(.type=="text").text) | join(" "))
      elif type=="string" then .
      else "" end // ""' "$transcript" 2>/dev/null | head -c 200)"
fi

touched="$(git -C "$cwd" diff --stat 2>/dev/null | tail -1)"
```

Replace the heredoc that writes STATUS.md with:

```bash
status_dir="$toplevel/.claude/status"
mkdir -p "$status_dir"
cat >"$status_dir/STATUS.md" <<EOF
# worktree status

- updated: $updated
- branch: $branch
- dirty files: $dirty_count

## current activity
**last ask:** $last_ask
**last did:** $last_did

## touched
$touched
EOF
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd /Users/leahpeker/development/skillet && node --test "scripts/worktree-status.test.mjs"`
Expected: PASS — all tests green (narrative captured, timestamp present, empty transcript tolerated).

- [ ] **Step 5: Commit**

```bash
cd /Users/leahpeker/development/skillet
git add plugins/skillet/hooks/worktree-status.sh scripts/worktree-status.test.mjs
git commit -m "feat: worktree-status writer captures narrative + timestamp from transcript"
```

---

## Task 3: Exclude self-heal test

**Files:**
- Test: `scripts/worktree-status.test.mjs`

The self-heal logic was written in Task 1; this task pins it with a test (idempotent, no duplicate lines). No script change expected — if the test fails, fix the script.

- [ ] **Step 1: Write the failing test (append to the test file)**

```javascript
test("adds .claude/status/ to info/exclude exactly once (idempotent)", () => {
  const { main, wt } = setupRepoWithWorktree();
  // The shared common dir's exclude file (worktrees share the main repo's .git).
  const excludePath = join(main, ".git", "info", "exclude");
  runHook(wt);
  runHook(wt); // second run must not duplicate
  const body = readFileSync(excludePath, "utf8");
  const occurrences = body.split("\n").filter((l) => l === ".claude/status/").length;
  assert.equal(occurrences, 1, "exclude entry should appear exactly once");
});
```

- [ ] **Step 2: Run the test**

Run: `cd /Users/leahpeker/development/skillet && node --test "scripts/worktree-status.test.mjs"`
Expected: PASS (the `grep -qxF` guard in the script already makes this idempotent). If it FAILS with 0 occurrences, confirm the worktree's `--git-common-dir` resolves to `<main>/.git`; if it FAILS with 2, the guard regex is wrong — fix it in the script.

- [ ] **Step 3: Commit**

```bash
cd /Users/leahpeker/development/skillet
git add scripts/worktree-status.test.mjs
git commit -m "test: pin worktree-status exclude self-heal idempotency"
```

---

## Task 4: Register the Stop hook in the plugin

**Files:**
- Create: `plugins/skillet/hooks/hooks.json`

This wires the script into the plugin so it fires automatically for any session with skillet enabled.

- [ ] **Step 1: Create the hooks file**

Create `plugins/skillet/hooks/hooks.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "Stop",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/worktree-status.sh"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Validate it is well-formed JSON and references an existing executable**

Run:
```bash
cd /Users/leahpeker/development/skillet
jq -e '.hooks.Stop[0].hooks[0].command' plugins/skillet/hooks/hooks.json
test -x plugins/skillet/hooks/worktree-status.sh && echo "script is executable"
```
Expected: prints the `${CLAUDE_PLUGIN_ROOT}/hooks/worktree-status.sh` command string, then `script is executable`.

- [ ] **Step 3: Commit**

```bash
cd /Users/leahpeker/development/skillet
git add plugins/skillet/hooks/hooks.json
git commit -m "feat: register skillet Stop hook for worktree status"
```

---

## Task 5: The `/worktree-status` reader skill

**Files:**
- Create: `plugins/skillet/skills/worktree-status/SKILL.md`

A documented procedure skill, matching the style of the other skillet skills (frontmatter + workflow steps). It is a procedure for Claude to follow, not executable code, so there is no automated test — Task 7 verifies it manually.

- [ ] **Step 1: Create the skill**

Create `plugins/skillet/skills/worktree-status/SKILL.md`:

````markdown
---
name: worktree-status
description: Report the current status of every git worktree — the work-in-progress narrative (from each worktree's STATUS.md) plus live git state (branch, dirty, ahead/behind, last commit). Flags stale or inactive worktrees. Use when you want to see what's going on across all your worktrees at a glance.
argument-hint: ""
---

# Worktree Status Skill

Show a combined status report for every git worktree of the current repo. Each
worktree's work-in-progress narrative is written automatically by the skillet
Stop hook to `.claude/status/STATUS.md`; this skill reads those and layers live
git state on top.

## Workflow

### 1. Enumerate worktrees

```bash
git worktree list --porcelain
```

Parse each `worktree <path>` entry. The first entry is the main checkout — note
it but expect it to have NO `STATUS.md` (no work happens in main by design).

### 2. Gather per-worktree status

For each worktree path `<wt>`:

**Narrative (from the hook):**
```bash
cat "<wt>/.claude/status/STATUS.md" 2>/dev/null
```
If missing, the worktree has had no agent activity since the hook was installed
— mark it accordingly (see staleness below).

**Live git state (computed fresh, independent of STATUS.md):**
```bash
git -C "<wt>" rev-parse --abbrev-ref HEAD                       # branch
git -C "<wt>" status --porcelain                                # dirty (count lines)
git -C "<wt>" rev-list --left-right --count @{u}...HEAD 2>/dev/null  # behind/ahead vs upstream
git -C "<wt>" log -1 --format='%cr | %s'                        # last commit (relative) + subject
```
If `@{u}` fails (no upstream), report "no upstream" instead of ahead/behind.

### 3. Staleness flag

Mark a worktree **stale / inactive** if EITHER:
- `STATUS.md` is missing, OR
- its `updated:` timestamp is more than 24 hours old.

(24h is the default threshold — adjust here if you want it tighter/looser.)

### 4. Print the report

One block per worktree (skip or clearly separate the main checkout). Keep it
scannable:

```
<branch>  (<relative-path>)
  activity: <last ask> → <last did>     # from STATUS.md, or "no recent activity"
  git:      <dirty> uncommitted · <ahead>↑ <behind>↓ · last commit <when>
  [stale]   # only if flagged
```

Sort so active worktrees (recent `updated:`) come first, stale ones last.

### 5. Nested worktrees

A worktree may itself contain worktrees (e.g. a worktree under another
worktree's `.claude/worktrees/`). `git worktree list` from the main repo lists
only that repo's worktrees. If you spot a worktree path that contains
`.claude/worktrees/` under it, run `git -C <wt> worktree list --porcelain` and
include those nested worktrees too, labeled as nested.
````

- [ ] **Step 2: Validate the frontmatter parses**

Run:
```bash
cd /Users/leahpeker/development/skillet
head -5 plugins/skillet/skills/worktree-status/SKILL.md
```
Expected: shows the `---` frontmatter block with `name: worktree-status` and a `description:` line.

- [ ] **Step 3: Commit**

```bash
cd /Users/leahpeker/development/skillet
git add plugins/skillet/skills/worktree-status/SKILL.md
git commit -m "feat: add /worktree-status reader skill"
```

---

## Task 6: create-worktree tweak — exclude `.claude/status/`

**Files:**
- Modify: `plugins/skillet/skills/create-worktree/SKILL.md`

Belt-and-suspenders: ensure `.claude/status/` is excluded at scaffold time, so a new worktree is clean from its very first turn even before the hook runs.

- [ ] **Step 1: Read the current create-worktree step 3**

Run:
```bash
cd /Users/leahpeker/development/skillet
grep -n "check-ignore\|info/exclude\|\.gitignore\|worktrees/" plugins/skillet/skills/create-worktree/SKILL.md
```
This locates the existing exclude-handling block (the one that ensures
`.claude/worktrees/` is ignored).

- [ ] **Step 2: Add the status exclude alongside the worktrees exclude**

In the create-worktree skill, in the step that ensures `.claude/worktrees/` is
ignored, add a sibling instruction immediately after it:

```markdown
Also ensure the per-worktree status directory is excluded so the skillet
worktree-status hook's `STATUS.md` never pollutes `git status`. If
`git -C "$ROOT" check-ignore .claude/status/` comes up empty, add
`.claude/status/` to `$ROOT/.git/info/exclude` (keeping the rule uncommitted,
matching how `.claude/worktrees/` is handled).
```

Place this so it reads naturally right after the existing `.claude/worktrees/`
exclude paragraph. Do not duplicate or remove the existing instruction.

- [ ] **Step 3: Verify the edit landed and the doc still reads cleanly**

Run:
```bash
cd /Users/leahpeker/development/skillet
grep -n "\.claude/status/" plugins/skillet/skills/create-worktree/SKILL.md
```
Expected: shows the new `.claude/status/` reference inside the create-worktree skill.

- [ ] **Step 4: Commit**

```bash
cd /Users/leahpeker/development/skillet
git add plugins/skillet/skills/create-worktree/SKILL.md
git commit -m "feat: create-worktree also excludes .claude/status/"
```

---

## Task 7: End-to-end verification + full test run

**Files:** none (verification only)

- [ ] **Step 1: Run the full skillet test suite**

Run: `cd /Users/leahpeker/development/skillet && node --test "scripts/**/*.test.mjs"`
Expected: all tests pass, including the pre-existing `set-version` tests and the new `worktree-status` tests.

- [ ] **Step 2: Manual smoke test of the writer against a real worktree**

Pick a real pda worktree path and drive the script directly:
```bash
WT="/Users/leahpeker/development/pda/.claude/worktrees/fix-auth-session"
printf '{"cwd":"%s","transcript_path":"","hook_event_name":"Stop"}' "$WT" \
  | bash /Users/leahpeker/development/skillet/plugins/skillet/hooks/worktree-status.sh
cat "$WT/.claude/status/STATUS.md"
```
Expected: `STATUS.md` is created with `branch:`, `updated:`, and `dirty files:` populated (narrative blank since transcript is empty). Confirm `git -C "$WT" status --porcelain` does NOT list `.claude/status/` (proves the exclude self-heal worked).

- [ ] **Step 3: Confirm main checkout is untouched**

```bash
printf '{"cwd":"/Users/leahpeker/development/pda","transcript_path":"","hook_event_name":"Stop"}' \
  | bash /Users/leahpeker/development/skillet/plugins/skillet/hooks/worktree-status.sh
test ! -f /Users/leahpeker/development/pda/.claude/status/STATUS.md && echo "main untouched ✓"
```
Expected: prints `main untouched ✓`.

- [ ] **Step 4: Manual run of the reader skill**

Invoke `/worktree-status` in a session and confirm it prints a per-worktree
report, flags worktrees with no `STATUS.md` as stale, and handles the nested
worktree under `feat-issue-supervisor-loop`.

- [ ] **Step 5: Open a PR**

Use the skillet `/open-pr` skill (or `gh pr create`) to open a PR from
`feat-worktree-status` into `main`. Do NOT merge — that's the user's call.

---

## Notes for the implementer

- **Never break a session:** every failure path in `worktree-status.sh` must
  `exit 0`. The hook is passive — it never returns exit code 2 and never blocks.
- **`jq` is a hard dependency of the writer** but its absence is handled (the
  script exits 0). `jq` is present on the dev machine (`/usr/bin/jq`).
- **Transcript shape:** the tests assume the Claude Code transcript JSONL has
  lines with `.type` of `"user"`/`"assistant"` and `.message.content` that is
  either a string or an array of `{type:"text", text:...}` blocks. The `jq`
  fallback (`.message.content // .content`) tolerates both shapes; if a real
  transcript differs, widen the filter in Task 2's extraction block — the
  narrative falling back to empty is acceptable, an error is not.
- This is the skillet repo — the pda frontend lowercase-text rule does NOT apply.
