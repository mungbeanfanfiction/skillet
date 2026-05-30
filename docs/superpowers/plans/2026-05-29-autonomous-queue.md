# Autonomous Task Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two composable skills to the skillet marketplace — `/review-fix` (auto-review and fix a PR's serious findings) and `/drain-queue` (work a queue of tasks end-to-end, unattended) — so the user can launch a session, walk away, and return to improved PRs plus a run-report.

**Architecture:** Two prose `SKILL.md` skills under `plugins/skillet/skills/`, following the existing skill pattern. `/review-fix` wraps the project's `/code-review` command in a bounded loop. `/drain-queue` orchestrates capped-parallel subagents, each of which uses `create-worktree`, `open-pr`, and `/review-fix`. Skills are auto-discovered from the `skills/` directory by their `SKILL.md` frontmatter — neither manifest needs editing; only `README.md` is updated for human readers.

**Tech Stack:** Markdown skill definitions, `gh` CLI, the `/code-review` command (plugin `code-review@2.0.1`, accepts `medium`/`--comment`/`--fix`/PR-number), the superpowers `dispatching-parallel-agents` skill, and existing skillet skills `create-worktree` + `open-pr`.

**Validation note:** These are prose skills, not executable code, so "tests" here are concrete checks — frontmatter parses, the skill is registered, and a documented dry-run trace holds together. There is no test runner to invoke for skill content (`npm test` only covers release tooling). Commits must NOT include a `Co-Authored-By` trailer (forbidden by `.claude/rules/no-co-authored-by.md`).

---

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `plugins/skillet/skills/review-fix/SKILL.md` | The PR review + auto-fix loop skill | Create |
| `plugins/skillet/skills/drain-queue/SKILL.md` | The queue orchestrator skill | Create |
| `README.md` | User-facing skill table + layout | Modify: add two rows + tree entries |

Neither `plugin.json` nor `marketplace.json` lists skills (they are auto-discovered from `skills/`), so neither needs changing. Each `SKILL.md` is one focused file with a single responsibility, well under the 300-line target.

---

## Task 1: Create `/review-fix` skill

**Files:**
- Create: `plugins/skillet/skills/review-fix/SKILL.md`

- [ ] **Step 1: Write the skill file**

Create `plugins/skillet/skills/review-fix/SKILL.md` with exactly this content:

````markdown
---
name: review-fix
description: Review a PR with /code-review and automatically fix high and medium severity findings without asking, looping until clean. Unsafe-to-automate findings are posted as inline PR comments instead. Use to auto-improve a PR unattended.
argument-hint: "[pr-number] [effort]"
---

# Review-Fix Skill

Run code review on a PR and automatically apply fixes for serious findings
without requiring authorization, so the PR is iterated on and improved before a
human looks at it.

This skill never prompts for permission on the fixes it applies — that is the
point. Nothing is silently dropped: every finding is fixed, commented, or
logged.

## When Invoked

Parse the arguments:

- A **number** → the PR to review. If omitted, infer the PR from the current
  branch:
  ```bash
  gh pr view --json number,headRefName,url --jq '.number'
  ```
  If there is no PR for the current branch, stop and report that.
- An **effort** word (`low` / `medium` / `high` / `max`) → code-review effort.
  Default `medium` (fewer, high-confidence findings — best for unattended runs).
  Never use `ultra` here: it is billed and user-triggered and cannot be
  auto-launched from a skill.

Work from the worktree/branch that the PR was opened from.

## Workflow

### The review/fix loop

Repeat for at most **3 rounds**:

#### 1. Review

Run code review against the PR, scoped to that PR's diff:

```bash
/code-review medium <pr-number>
```

(Use the provided effort word in place of `medium` if one was passed.)

Collect the findings with their severities.

#### 2. Partition findings by severity

- **High + Medium** → fix candidates.
- **Low** → log only; never auto-fix.

#### 3. Triage each fix candidate

For each high/medium finding, decide whether it is **safe to auto-fix**:

- **Safe** — clear, mechanical, behavior-preserving (e.g. a missing null
  guard, an obvious off-by-one, dead code, a typo'd identifier). Apply the fix
  to the working tree.
- **Unsafe** — needs a judgment call or could change behavior (e.g. "this
  caching strategy may be wrong", an API contract change, anything ambiguous).
  Do **not** modify code. Post the finding as an inline PR comment for the
  human:
  ```bash
  /code-review medium <pr-number> --comment
  ```
  or post a targeted comment via `gh pr comment <pr-number> --body "..."`.
  Record it in the summary.

#### 4. Commit and push applied fixes

If any fixes were applied this round:

```bash
git add -A
git commit -m "fix: address code-review findings (round N)"
git push
```

Then continue to the next round (this catches issues the fixes introduced).

#### 5. Stop condition

Stop when a round produces **no new high/medium findings**, or after the **3rd
round**, whichever comes first.

## Report

Output a short summary:

- Rounds run.
- Fixes applied (brief description each).
- Findings posted as PR comments for human review (the unsafe pile).
- Low-severity findings logged.
````

- [ ] **Step 2: Verify frontmatter parses and file is well-formed**

Run:
```bash
head -5 plugins/skillet/skills/review-fix/SKILL.md
wc -l plugins/skillet/skills/review-fix/SKILL.md
```
Expected: the four frontmatter lines (`name: review-fix`, a `description:`, an
`argument-hint:`, and the closing `---`) appear, and the file is well under 300
lines.

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/review-fix/SKILL.md
git commit -m "feat: add review-fix skill for autonomous PR review and fixing"
```

---

## Task 2: Create `/drain-queue` skill

**Files:**
- Create: `plugins/skillet/skills/drain-queue/SKILL.md`

- [ ] **Step 1: Write the skill file**

Create `plugins/skillet/skills/drain-queue/SKILL.md` with exactly this content:

````markdown
---
name: drain-queue
description: Work a queue of tasks autonomously — from a GitHub label or a markdown checklist — dispatching capped-parallel subagents that each create a worktree, do the work, run the repo's own checks, open a draft PR, and auto-improve it via review-fix. Never asks the human anything; writes a run-report at the end. Use to leave the machine and return to finished, improved work.
argument-hint: "--label <label> | --file <path> [--cap N]"
---

# Drain-Queue Skill

Drain a queue of tasks with no human input required. Each task is worked in
isolation, verified, turned into a draft PR, and auto-improved via the
`review-fix` skill. When done, write a run-report so the user can triage on
return.

## When Invoked

Parse the arguments:

- **Queue source (exactly one required):**
  - `--label <label>` → list GitHub issues carrying that label.
  - `--file <path>` → parse unchecked (`- [ ]`) items from a markdown file as
    tasks.
- `--cap N` → maximum concurrent tasks. Default **3**.

If neither queue source is given, stop and ask which to use (this is setup, not
mid-run — asking here is fine).

## Workflow

### 1. Gather the queue

For a label:
```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
gh issue list --repo "$REPO" --label "<label>" --state open \
  --json number,title,url
```

For a file: read it and extract every line matching `- [ ]` as a task (keep the
text after the checkbox as the task description).

Build an ordered task list. If the queue is empty, report that and stop.

### 2. Dispatch subagents, capped at N concurrent

Use the **superpowers:dispatching-parallel-agents** skill to run up to `--cap`
tasks at once. Give every subagent this exact charter:

> You are working ONE task autonomously. You must NEVER ask the human anything.
>
> 1. Create an isolated worktree for this task using the `create-worktree`
>    skill (pass the issue number, or a derived branch name for file tasks).
> 2. Do the work for the task in that worktree.
> 3. Verify using the repo's OWN check command. Detect it in this order and run
>    the first that exists: `make ci`, then `npm test` / `npm run test`, then
>    `pytest`, then any check documented in the repo's CLAUDE.md/README. If none
>    exists, note "no check command found" in your result. Only proceed to the
>    PR if the check passes (or there is none).
> 4. Open a **draft PR** using the `open-pr` skill (pass the issue number if
>    this task came from an issue).
> 5. Run the `review-fix` skill on that PR to auto-improve it.
> 6. On genuine ambiguity (missing info, unclear spec): attempt a **documented
>    best guess** and note the assumption in the PR body. If no safe guess is
>    possible, **skip the task** — do not open a PR — and explain why.
> 7. Return a STRUCTURED result with these fields: `task` (id/title),
>    `status` (`done` | `skipped`), `pr_url` (if done), `review_summary` (from
>    review-fix), `skip_reason` (if skipped), `flagged_for_human` (any unsafe
>    findings review-fix left as PR comments).

### 3. Never stall

The pipeline must never idle waiting for the user. This is guaranteed by three
things, all already in the charter above:

1. **Isolation** — each task in its own worktree, so parallel tasks never block
   on shared state or merge conflicts.
2. **No-questions rule** — the subagent best-guesses-and-documents or
   skips-and-logs; it never asks.
3. **Unambiguous done** — verification uses the repo's existing check command.

### 4. Loop until drained

Continue dispatching until every task in the queue has a result, respecting the
concurrency cap.

### 5. Write the run-report

Write `docs/superpowers/runs/YYYY-MM-DD-drain-queue.md` (create the directory if
needed). Use today's date. Include three sections:

- **Shipped** — for each `done` task: title → PR link → one-line review summary.
- **Skipped** — for each `skipped` task: title → reason.
- **Needs your attention** — every `flagged_for_human` item across all tasks
  (the unsafe findings review-fix posted as PR comments).

Then output the report path and a one-line tally (e.g. "7 shipped, 2 skipped,
3 flagged").
````

- [ ] **Step 2: Verify frontmatter parses and file is well-formed**

Run:
```bash
head -5 plugins/skillet/skills/drain-queue/SKILL.md
wc -l plugins/skillet/skills/drain-queue/SKILL.md
```
Expected: frontmatter (`name: drain-queue`, a `description:`, an
`argument-hint:`, closing `---`) is present and the file is under 300 lines.

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/drain-queue/SKILL.md
git commit -m "feat: add drain-queue skill for autonomous task-queue execution"
```

---

## ## Task 3: ~~Register both skills in the marketplace manifest~~ (NOT NEEDED)

**Correction during implementation:** `.claude-plugin/marketplace.json` has **no
`skills` array** — it only lists the plugin under `plugins[]`. Skills are
**auto-discovered** from the `plugins/skillet/skills/` directory by their
`SKILL.md` frontmatter. Creating the skill folders (Tasks 1-2) is sufficient to
register them; no manifest edit is required. This task is skipped.

---

## Task 4: Document both skills in the README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add two rows to the skills table**

The skills table currently ends with the `/cleanup-worktrees` row. Add these
two rows immediately after it (before the table ends):

```markdown
| `/review-fix` | Review a PR with `/code-review` and auto-fix high/medium findings, looping until clean; unsafe findings become PR comments. |
| `/drain-queue` | Work a queue of tasks (GitHub label or markdown checklist) unattended: each task → worktree → checks → draft PR → `/review-fix`, then a run-report. |
```

- [ ] **Step 2: Add the two skills to the layout tree**

In the `## Layout` code block, the skills tree currently lists the four
existing skills under `skills/`. Update that tree so it reads:

```
    ├── open-pr/SKILL.md
    ├── create-worktree/SKILL.md
    ├── delete-worktree/SKILL.md
    ├── cleanup-worktrees/SKILL.md
    ├── review-fix/SKILL.md
    └── drain-queue/SKILL.md
```

(Note the connector on `cleanup-worktrees` changes from `└──` to `├──`, and
`drain-queue` carries the final `└──`.)

- [ ] **Step 3: Verify the edits landed**

Run:
```bash
grep -n "review-fix\|drain-queue" README.md
```
Expected: four matches — two table rows and two tree lines.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document review-fix and drain-queue skills in README"
```

---

## Task 5: Final verification

- [ ] **Step 1: Confirm both skills are discoverable and well-formed**

Run:
```bash
for s in review-fix drain-queue; do
  echo "== $s =="
  head -4 "plugins/skillet/skills/$s/SKILL.md"
  wc -l "plugins/skillet/skills/$s/SKILL.md"
done
node -e "const m=JSON.parse(require('fs').readFileSync('.claude-plugin/marketplace.json','utf8')); console.log(m.plugins[0].skills)"
```
Expected: both files have valid frontmatter and are under 300 lines; the
printed skills array includes `review-fix` and `drain-queue`.

- [ ] **Step 2: Confirm a clean tree and review the log**

Run:
```bash
git status --porcelain
git log --oneline -6
```
Expected: working tree clean; the last commits are the four feature/docs
commits from Tasks 1-4.

- [ ] **Step 3: Run the release tooling tests (sanity, unaffected)**

Run:
```bash
npm test
```
Expected: PASS. These cover release tooling only and should be unaffected by
the new skills — this just confirms nothing was broken.

---

## Self-Review

**Spec coverage:**
- `/review-fix` purpose, args (PR + effort default medium), 3-round loop,
  high+medium partition, low logged, safe/unsafe triage, unsafe → PR comment,
  commit/push, stop condition, report → Task 1. ✔
- `/drain-queue` purpose, args (`--label`/`--file`/`--cap` default 3), gather,
  capped dispatch, subagent charter (worktree → work → repo check → draft PR →
  review-fix → best-guess-or-skip → structured result), never-stall trio, loop,
  run-report at `docs/superpowers/runs/…` → Task 2. ✔
- Reuse of `create-worktree`, `open-pr`, `/code-review`, `dispatching-parallel-agents`
  → referenced in Tasks 1-2. ✔
- Skill registration + discoverability (marketplace + README) → Tasks 3-4
  (implied by "lives in skillet" requirement). ✔
- Out-of-scope items (workflow script, cron, non-GitHub sources, ultra) →
  correctly omitted. ✔

**Placeholder scan:** Full skill content is inlined in Tasks 1-2; no TBD/TODO;
all commands concrete with expected output.

**Type/name consistency:** Skill names `review-fix` and `drain-queue` are used
identically across SKILL.md frontmatter, marketplace.json, README, and
verification steps. `/code-review` invocation matches its real interface
(`medium`, PR number, `--comment`). Commit messages contain no `Co-Authored-By`
trailer, per the project rule.
