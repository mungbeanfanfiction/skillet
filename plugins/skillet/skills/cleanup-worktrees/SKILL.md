---
name: cleanup-worktrees
description: Survey all git worktrees and present cleanup candidates whose branches are merged or whose PRs are closed/merged. Lets the user pick which to remove. Supports an autonomous (--noninteractive) mode for unattended callers like /issue-supervisor that removes only provably-safe (🟢) worktrees without prompting. Use when worktrees have accumulated and you want to tidy up.
argument-hint: "[--noninteractive]"
---

# Cleanup Worktrees Skill

Survey worktrees, classify them by safety-to-remove, and let the user batch-delete the safe ones.

By default this skill never deletes anything without explicit per-worktree (or
"yes to all") confirmation.

### Autonomous mode (`--noninteractive`)

When invoked with `--noninteractive` (e.g. from `/issue-supervisor` or any unattended
loop), run **non-interactively**: classify every worktree exactly as below, then
remove **only the 🟢 "Safe to remove" bucket** (no tracked modifications, pushed,
AND branch merged or PR merged) along with its local branch — without prompting.
🟡/🟠/🔴 worktrees are left untouched and reported. `--noninteractive` removes the
interactive confirmation, not the classification gate; nothing with tracked
modifications, unpushed, or unmerged is ever removed. A worktree dirty **only** with
untracked/ignored files still qualifies for 🟢 (see step 3) and is removed with
`--force`.

## Workflow

### 1. Enumerate worktrees

```bash
git worktree list --porcelain
```

Skip the main worktree (the first entry). For each remaining entry, collect:
- path
- branch name
- HEAD sha

### 2. Determine repo + default branch

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
```

Make sure the local default-branch ref is fresh:

```bash
git fetch origin "$BASE" --quiet
```

### 3. Classify each worktree

For each worktree, gather:

**Dirty?**
```bash
git -C <path> status --porcelain
```
Non-empty = dirty. But not all dirt is equal — distinguish two kinds:

- **Tracked modifications** — any entry whose two-char status code is not `??`
  (e.g. ` M`, `MM`, `A `, `D `, `R `, `C `, `UU`). This is real work-in-progress and
  makes a worktree 🔴.
- **Untracked/ignored only** — every entry is `??` (untracked), or the tree is
  otherwise clean of tracked changes. This is typically supervisor bookkeeping
  (session scaffolding under `.claude/`, `node_modules/`, `__pycache__/`, etc.) and
  is **safe to discard** when the worktree is also pushed and merged.

Compute a "has tracked modifications" flag:
```bash
if git -C <path> status --porcelain | grep -q '^[^?]'; then echo "tracked-modified"; else echo "untracked-only-or-clean"; fi
```
(`grep -q '^[^?]'` succeeds only when a line begins with a non-`?` character, i.e. a
real tracked entry. A clean tree produces empty output → no match → `untracked-only-or-clean`,
and a tree dirty only with `??` untracked entries also yields `untracked-only-or-clean`.
Do **not** use `grep -qv '^?? '`: it exits 1 on empty input, which would mislabel a
clean worktree as `tracked-modified`.)

Do **not** special-case individual tracked paths (e.g. a modified `.claude/task.md`):
any tracked modification keeps the worktree 🔴. The untracked-only allowance covers
the common supervisor-bookkeeping case without risking real work.

**Unpushed?**
```bash
git -C <path> log @{u}..HEAD --oneline 2>/dev/null | wc -l
```
Count > 0, or no upstream = unpushed.

**Merged?**
```bash
git -C <path> branch --merged "origin/$BASE" | grep -q "<branch>"
```

**PR status?**
```bash
gh pr list --head <branch> --state all --json number,state,url --limit 1
```
States to look for: `MERGED`, `CLOSED`, `OPEN`, or no PR at all.

Bucket each worktree into one of ("no tracked modifications" = clean **or** dirty
with untracked/ignored files only, per the dirty check above):

- **🟢 Safe to remove** — no tracked modifications, pushed, AND (branch merged OR PR merged)
- **🟡 Likely safe** — no tracked modifications, pushed, PR closed (not merged) — user may want to discard
- **🟠 Open PR** — no tracked modifications, has open PR — probably keep
- **🔴 Has work** — has tracked modifications OR has unpushed commits → never auto-suggest removal

A worktree whose only dirt is untracked/ignored files (`??` entries — session
scaffolding, `node_modules/`, caches) is treated as clean for classification and
removed with `git worktree remove --force` (see step 6).

### 4. Present the list

Show a table like:

```
PATH                            BRANCH                STATUS
🟢 ../myapp-feat-foo            feat-foo              PR #123 merged
🟢 ../myapp-fix-bar             fix-bar               merged into main
🟡 ../myapp-experiment-baz      experiment-baz        PR #99 closed (not merged)
🟠 ../myapp-feat-qux            feat-qux              PR #124 open
🔴 ../myapp-wip-thing           wip-thing             tracked changes, 3 unpushed commits
```

### 5. Ask what to remove

Offer choices:
- Remove all 🟢
- Remove all 🟢 and 🟡
- Pick individually
- Cancel

If "pick individually", ask for each one separately — show its details before each prompt.

**In `--noninteractive` mode, skip this step entirely** and select exactly the 🟢 bucket —
no prompt, never 🟡 (a closed-but-unmerged PR can still hold work worth a human
glance).

🔴 worktrees are never removed by this skill. Tell the user to handle them manually with `/delete-worktree` after committing/pushing.

### 6. Remove the chosen worktrees

For each selected worktree:

```bash
git worktree remove <path>
```

If the worktree is dirty with untracked/ignored files only (a 🟢/🟡 that was kept
eligible by the untracked-only allowance), plain `remove` fails with *"contains
modified or untracked files"* — use `--force`:

```bash
git worktree remove --force <path>
```

`--force` here only discards untracked/ignored files (session scaffolding, caches);
worktrees with tracked modifications are 🔴 and never reach this step, so no real
work is destroyed.

After each removal, ask whether to also delete the local branch:

```bash
git branch -d <branch>     # safe delete (fails if unmerged)
```

Batch the branch-delete prompt with a "yes to all" / "no to all" option to avoid repetitive confirmation.

**In `--noninteractive` mode, skip the branch-delete prompt and run `git branch -d`** for
each removed worktree (safe delete only — a 🟢 branch is merged, so it succeeds;
never `-D`).

### 7. Report

Summarize:
- N worktrees removed
- M branches deleted
- K worktrees skipped (and why)

Run `git worktree list` once more and show what's left.

## Notes

- This skill does NOT delete remote branches on GitHub.
- It does NOT touch the main worktree.
- It does NOT remove worktrees with **tracked** uncommitted modifications or unpushed
  work, even if the user says "remove all". Untracked/ignored-only dirt (session
  scaffolding, caches) does not count as work and is discarded with `--force` when the
  worktree is otherwise 🟢.
- If `gh` isn't authenticated or the repo isn't on GitHub, fall back to the local `--merged` check and skip the PR-status column.
