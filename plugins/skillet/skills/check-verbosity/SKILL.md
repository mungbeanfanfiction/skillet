---
name: check-verbosity
description: Check the current branch's diff against its base for verbosity that should be trimmed before a PR is opened — redundant/obvious comments, leftover narration and debug log lines, dead or scaffolding code, and overly wordy prose in docs/skill markdown. Reports concrete findings with file/line references and can optionally apply safe trims. Standalone, and also runs as a pre-PR gate before /open-pr. Never opens, pushes, or commits anything. Use to tighten a branch before publishing it.
argument-hint: "[base-branch] [--fix] [--json]"
---

# Check Verbosity

Catch the verbosity that creeps into a branch before it ships: comments that
restate the code, narration/debug log lines left behind, dead scaffolding, and
wordy prose in docs/skill markdown. This is the **diff-level** counterpart to the
per-edit `block-verbose-comments` hook — it judges the whole branch at once, so
it catches things that only look verbose in aggregate (e.g. a comment that was
fine alone but duplicates the function name right above it).

This is a **review**, not a rewrite. It is **read-only by default**: it reports
findings with file/line references and stops. With `--fix` it may apply only the
**safe, mechanical** trims it is confident about, and it always surfaces exactly
what it changed. It **never** opens a PR, pushes, commits, or stages — it only
inspects (and optionally edits) the working tree.

## When invoked

This is a pure-judgment skill — there is no backing script. The "flags" below are
**skill arguments** you interpret yourself (the bash snippets are for *gathering*
the diff, not a `check-verbosity` binary to shell out to). Parse the arguments:

- **`[base-branch]`** — the branch to diff against. If omitted, detect the repo's
  default branch and use that (see step 1).
- **`--fix`** — apply safe trims to the working tree after reporting. Without
  this flag the skill only reports.
- **`--json`** — print a machine-readable findings envelope instead of the
  human summary (for callers like the pre-PR gate or `/issue-supervisor`).

### 1. Determine the base and collect the diff

Resolve the base branch. If no `[base-branch]` argument was given, use the repo's
default branch — and if that can't be resolved, **stop with an error** (don't
silently assume `main`, which would review against the wrong base):

```bash
# Substitute the [base-branch] you parsed for $1 — these snippets are illustrative,
# so there is no positional arg unless you supply one. With no base given, $1 is
# empty and this falls through to default-branch detection.
BASE="${1:-$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)}"
# Prefer the local base ref; fall back to origin/<base>.
git rev-parse --verify "$BASE" >/dev/null 2>&1 || BASE="origin/$BASE"
MERGE_BASE=$(git merge-base "$BASE" HEAD 2>/dev/null)
# Fatal if the base couldn't be resolved (handle per the note below).
[ -n "$MERGE_BASE" ] || { echo "could not determine base branch"; exit 1; }
```

If the base can't be resolved — empty `$BASE`, or `git merge-base` fails because
the ref exists neither locally nor as `origin/<base>` (so `$MERGE_BASE` is
empty) — that is a fatal setup error: **stop** (there is no backing process to
exit; "stop" means end the skill and report). Surface it in the mode you were
invoked in — a plain-text error line by default, or the `{"ok": false,
"error": "could not determine base branch"}` envelope when `--json` was passed.

Now collect **everything this branch contributes**, which is three sources you
must union — committed work, uncommitted edits, and brand-new untracked files
(in a skills repo a whole new skill is often a single untracked file, so missing
this would make the check report "clean" on the most important content):

```bash
# 1. Committed on this branch (merge-base ... so you review what the branch ADDS,
#    not changes that arrived on the base since the branch started).
git diff --name-only "$MERGE_BASE"...HEAD
git diff "$MERGE_BASE"...HEAD

# 2. Uncommitted tracked edits (staged + unstaged) — the latest work.
git diff HEAD

# 3. Untracked new files — surface them as additions to inspect.
git ls-files --others --exclude-standard
```

Treat the untracked files (source 3) as if every line were an added line and run
the same checks on them. Inspect the union of all three; de-dupe files that
appear in more than one source.

If the union is empty, the branch is clean, not broken: report `nothing to
check` and stop. Under `--json` this is a successful pass — emit
`{"ok": true, ..., "counts": {"total": 0, ...}}`, **not** `ok: false` (a caller
like the pre-PR gate would misread an error envelope as a failure).

### 2. Inspect the added lines for verbosity

Look **only at added/modified lines** (the `+` side of the diff). For each, judge
against the four categories below. Be conservative — the goal is to flag genuine
noise, not to strip every comment. When unsure, **don't flag it**; a false
positive trains the user to ignore the check.

**A. Redundant / obvious comments.** A comment that restates what the adjacent
code plainly says, echoes a symbol name, or narrates line-by-line
("increment counter", "return the result", "// set x to 5"). Good comments
explain *why*; flag the ones that explain *what* the code already shows. This
includes **top-of-file / module header comments** that merely restate the
filename or an obvious one-line summary of what's below (e.g.
`// UserService.ts - handles user stuff`) — these read as legitimate doc
comments at a glance but add no information beyond what the filename already
says. Do **not** flag: doc comments on public APIs, `TODO`/`FIXME`/`NOTE`,
license headers, or comments (including file headers) that capture
non-obvious intent, edge cases, or rationale.

**B. Leftover narration / debug logs.** `print`/`console.log`/`println!`/
`fmt.Println`/`echo`-style lines that look like development scaffolding —
`print("here")`, `console.log("got to step 3", x)`, commented-out logging.
Do **not** flag logging that is clearly intentional and structured (a logger
call at an appropriate level, user-facing CLI output, test assertions).

**C. Dead / scaffolding code.** Unreachable code, unused locals/imports
introduced by this branch, commented-out blocks of old code, empty
placeholder functions, `if False:` / `if (false)` guards, or TODO stubs that
were never filled in. Flag only code **this branch added** — pre-existing dead
code is out of scope.

**D. Wordy prose in docs / skill markdown.** In `.md`/`.mdx` (and skill
`SKILL.md`) files: paragraphs that restate the obvious, redundant preamble,
"In this section we will…" filler, the same point made twice, or three
sentences where one carries the meaning. Flag the wordiness; suggest the
tighter version. Do **not** flag necessary detail, examples, or warnings.

For each finding record: the file path, the line number (from the new file),
the category, the offending text (truncated), and a one-line suggested action
(`remove`, `trim to: "…"`, `tighten`). When a fix is mechanical and safe
(delete a pure debug print, drop a redundant comment line, remove an unused
import), mark it `safe_fix: true`.

### 3. Report

**Default (no `--fix`, no `--json`)** — print a concise, grouped summary. Lead
with counts by category, then list findings grouped by file, each on one line:
`line — category — "offending text…" → suggested action`.

```
Verbosity check — feature/foo vs main · 6 findings (3 comments, 1 log, 1 dead, 1 prose)

src/auth.ts
  • 42 — comment — "// return the user object" → remove (restates the return)
  • 58 — log — 'console.log("here", token)' → remove (debug scaffolding)
  • 71 — dead — commented-out old validate() block → remove

src/util.ts
  • 12 — comment — "// increment i" → remove

docs/auth.md
  • 30 — prose — "In this section we will explain how…" → tighten to "Auth flow:"

4 of 6 are safe mechanical trims. Re-run with --fix to apply them; the rest need a judgment call.
```

If there are **no findings**, say so plainly:
`Verbosity check — feature/foo vs main · clean, nothing to trim.`

**`--json`** — print one envelope and stop (do not also print the human
summary):

```json
{
  "ok": true,
  "base": "main",
  "counts": { "total": 6, "comments": 3, "logs": 1, "dead": 1, "prose": 1, "safe_fixes": 4 },
  "findings": [
    { "path": "src/auth.ts", "line": 42, "category": "comment", "text": "// return the user object", "action": "remove", "safe_fix": true }
  ]
}
```

On genuine setup failure under `--json` (not in a git repo, bad base) print
`{"ok": false, "error": "…"}` and stop. An empty diff is **not** a failure — see
step 1 (emit `ok: true` with `total: 0`). In default mode the same failures are
reported as a plain-text error line, then stop.

### 4. Apply safe trims (only with `--fix`)

If `--fix` was passed, apply **only** the findings marked `safe_fix: true` —
the mechanical, unambiguous ones (delete a debug print, drop a redundant
comment line, remove an unused import this branch added). Leave everything that
needs a judgment call (prose tightening, possibly-intentional logging, dead code
that might be load-bearing) **for the human** — list it as still-open.

Apply each deletion by matching its recorded offending text (or work
bottom-to-top through the file) so an earlier edit doesn't shift the line
numbers of later ones.

Edit the working tree only. After applying, print what changed:

```
Applied 4 safe trims:
  • src/auth.ts:42 removed redundant comment
  • src/auth.ts:58 removed debug log
  • src/util.ts:12 removed redundant comment
  • src/auth.ts:71 removed commented-out block

2 findings need your judgment (not auto-applied):
  • docs/auth.md:30 — prose — tighten "In this section we will…"
  • src/foo.ts:88 — log — 'console.log(result)' may be intentional
```

Do **not** commit, stage, or push. The user reviews `git diff` and commits
themselves.

## Pre-PR gate

This skill runs **before `/open-pr`** as a tightening gate (`/open-pr` invokes
it first). In that flow it runs in report-only mode and surfaces findings so the
branch can be trimmed before the PR is created — it does not block, and it never
opens or pushes the PR itself. It is equally usable on its own, any time, to
check a branch.

## Notes

- **Read-only by default.** Without `--fix`, this skill never edits a file.
- **Never opens/pushes/commits.** It only inspects (and with `--fix`, edits) the
  working tree. Publishing is always a separate, explicit step (`/open-pr`).
- **Conservative by design.** Prefer missing a borderline case to flagging a
  legitimate comment/log — a noisy check gets ignored.
- **Complements the hook.** `block-verbose-comments` nudges per-edit on comments
  only; this checks the whole branch across comments, logs, dead code, and prose.
