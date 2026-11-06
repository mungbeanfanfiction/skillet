---
name: check-slop
description: Review pending code changes for slop before they're committed -- code duplicated within the diff or against the codebase, new helpers/fixtures/constants that already exist, test setup that should be a shared fixture, and other agent tells like defensive noise, one-caller abstractions, and convention drift. Searches the existing codebase for what the diff should have reused. Reports by default; `--fix` swaps in existing helpers where they're a drop-in. Never stages, commits, or pushes. Runs by default inside /commit and as a gate before /open-pr. Use before committing or opening a PR, or when asked for a slop/reuse/duplication review.
argument-hint: "[--staged | --branch [base] | <path>...] [--fix] [--json]"
model: sonnet
---

# Check Slop

Agents write code that works and still makes the codebase worse: a fourth copy
of a date formatter, a test file that rebuilds the same user object in every
test while `conftest.py` already has a `user` fixture, a wrapper that forwards
its arguments. Each one is small. Commit after commit, they pile up.

This skill reviews a diff for that. The core difference from `/check-verbosity`
is that it reads **outside the diff**: for each thing the change adds, it looks
for something in the codebase that already does it.

Leave comments, debug logs, commented-out code, and wordy markdown to
`/check-verbosity`. Don't report them here.

## When invoked

Pure-judgment skill, no backing script. Parse the arguments:

- **`--staged`** -- the staged diff (`git diff --cached`). This is what
  `/commit` passes.
- **`--branch [base]`** -- everything the branch adds vs. its base: committed,
  uncommitted, and untracked. This is what `/open-pr` passes. Resolve the base
  the same way `/check-verbosity` step 1 does, and stop with an error if it
  can't be resolved.
- **`<path>...`** -- review these files in full, as if every line were new.
- **No scope** -- staged changes if anything is staged, otherwise uncommitted
  tracked edits plus untracked files.
- **`--fix`** -- after reporting, apply the drop-in fixes (step 7).
- **`--json`** -- print the envelope in step 6 instead of the human summary.

If the scope is empty, or holds only files with nothing to reuse (lockfiles,
generated code, binary files, markdown), report `nothing to check` and stop.
Under `--json` that's `{"ok": true, "counts": {"total": 0}, "findings": []}`.

## Workflow

### 1. Collect the diff

```bash
git diff --cached                         # --staged
git diff "$MERGE_BASE"...HEAD; git diff HEAD; git ls-files --others --exclude-standard   # --branch
git diff HEAD; git ls-files --others --exclude-standard                                 # default, nothing staged
```

Treat untracked files as all-added. Only judge added and modified lines.

### 2. Inventory what the diff adds

List each new unit worth checking for an existing equivalent:

- functions, methods, classes, hooks, components
- test fixtures, factories, builders, mocks, and setup blocks (a `beforeEach`,
  an arrange section, a hand-built object literal used as test data)
- constants, regexes, enums, config keys, error messages, URL/path fragments
- new files, especially new `utils`/`helpers`/`common` modules

Skip trivial one-liners with no logic.

### 3. Hunt for what should have been reused

First, map where this repo keeps shared code. Look for: `conftest.py`,
`__fixtures__/`, `fixtures/`, `factories/`, `testutils`, `test-utils`,
`tests/helpers`, `spec/support`, `testing/`, and `utils`/`lib`/`common`/`shared`/
`helpers` directories near the changed files. Read their exports. This is the
step agents skip, and it finds most of the findings.

Then, for each inventoried unit:

- **Search by name and by shape.** Grep for synonyms of the name (`formatDate`,
  `fmtDate`, `toDateString`, `date_format`), distinctive literals in the body
  (a regex, a magic number, an error string), and the key calls it makes.
- **Check the dependencies.** Does the language stdlib or an already-installed
  package do this? Look at the manifest (`package.json`, `pyproject.toml`,
  `go.mod`, `Cargo.toml`) before calling it duplication of a library.
- **Check within the diff.** The same block pasted into three tests or two
  handlers is duplication even if the codebase has nothing like it.

For a large diff (more than ~8 inventoried units, or units spread across
unrelated areas), dispatch parallel `Explore` agents, one per area, each given
the units to look for and the shared-code locations from the map. Merge their
results.

### 4. Check the other slop tells

On the added lines, look for:

- **Test slop.** Repeated arrange blocks that should be a fixture or a
  parametrized test. Assertions on a mock the test just configured, so the test
  passes no matter what the code does. Tests that would still pass with the
  function body deleted. Mocking the unit under test.
- **Defensive noise.** `try`/`except` that swallows the error or re-raises with
  nothing added. Null checks and `isinstance` guards for values the types or the
  only caller already guarantee. Fallback defaults that hide a bug instead of
  surfacing it.
- **Speculative generality.** A parameter, config option, base class, factory,
  or interface with exactly one caller and one implementation. A wrapper that
  only forwards its arguments. Backward-compat shims for code that never
  shipped.
- **Convention drift.** Naming, error handling, logging, imports, or file layout
  that differ from the neighboring code. A new `utils.ts` next to an existing
  `helpers.ts`.
- **Phantom APIs.** Calls to functions, flags, or options that don't exist in
  the version this repo uses. Grep for the definition or check the installed
  package before flagging.
- **Scope creep.** Reformatting, renames, or refactors unrelated to the change,
  riding along in the same diff.

### 5. Verify before reporting

Open every existing helper or fixture you plan to point at and confirm it's
equivalent: same inputs, same output, same side effects, importable from where
the new code lives. If it differs in a way that matters, drop the finding or
say what would need to change. A wrong "just use X" costs more than a missed
duplicate, and a noisy check gets ignored.

Mark a finding `drop_in: true` only when the fix is a mechanical swap: replace
the new code with a call to the existing helper or fixture, and delete the new
code, with no behavior change.

### 6. Report

Lead with counts, then group by file. Every finding names the existing thing
to use, with its path and line.

```
Slop check -- staged · 5 findings (2 dup, 1 fixture, 1 test, 1 generality)

tests/test_orders.py
  • 14-31 — fixture — builds a User by hand in 4 tests → use `user` fixture (tests/conftest.py:22)
  • 58 — test — asserts mock_send.called after setting it up; never checks the order → assert on the order state

src/orders/format.py
  • 9 — dup — format_cents() reimplements money.format_amount (src/money.py:40) → call it
  • 30-44 — dup — same validation block as src/orders/create.py:71 → extract or import

src/orders/client.py
  • 5 — generality — OrderClientBase has one subclass and one caller → inline it

2 are drop-in swaps. Re-run with --fix to apply them.
```

Clean: `Slop check -- staged · clean.`

**`--json`**:

```json
{
  "ok": true,
  "scope": "staged",
  "counts": { "total": 5, "dup": 2, "fixture": 1, "test": 1, "generality": 1, "drop_in": 2 },
  "findings": [
    {
      "path": "src/orders/format.py",
      "line": 9,
      "category": "dup",
      "text": "def format_cents(n):",
      "existing": "src/money.py:40",
      "action": "call money.format_amount",
      "drop_in": true
    }
  ]
}
```

Categories: `dup`, `helper` (missed existing helper or library), `fixture`,
`test`, `defensive`, `generality`, `convention`, `phantom`, `scope`. On a setup
failure (not a git repo, base unresolved) print `{"ok": false, "error": "…"}`.

### 7. Apply drop-ins (only with `--fix`)

Apply only `drop_in: true` findings. Work bottom-to-top within each file so
earlier edits don't shift later line numbers. Add the import, delete the
duplicate, and remove any import the deletion left unused.

Then run the tests that cover the touched files, if the repo has an obvious
test command. If a test fails, revert that fix and report it as open.

List what changed and what still needs a judgment call. Edit the working tree
only.

## Do not

- Don't stage, commit, or push. Under `/commit` the caller re-stages.
- Don't flag pre-existing duplication the diff didn't touch.
- Don't report what `/check-verbosity` owns (comments, logs, dead code, prose).
- Don't suggest extracting a shared helper for two short, similar blocks that
  will likely diverge. Three real copies is the usual bar.
- Don't point at a helper you haven't opened and verified.
