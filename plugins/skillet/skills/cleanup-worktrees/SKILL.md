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
  makes a worktree 🔴 — **unless** every such entry's path is on the bookkeeping
  allowlist below AND the branch's PR is closed or merged (see the carve-out
  after the flag computation).
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

**Bookkeeping allowlist carve-out.** Do not special-case individual tracked paths in
general — any tracked modification keeps a worktree 🔴 by default. The one exception:
if `tracked-modified` is true, re-check which tracked paths are dirty:

```bash
git -C <path> status --porcelain | grep '^[^?]' | awk '{print $2}'
```

If **every** one of those paths is in the bookkeeping allowlist —

```
.claude/task.md
.claude/question.md
```

— and the branch's PR (fetch PR status now if you haven't yet — see the PR-status
check below) is `CLOSED` or `MERGED`, then treat this worktree as
`untracked-only-or-clean` for classification purposes (same bucket as the
untracked-only case). These files are per-task supervisor scratch state
(issue number, labels, progress log) rewritten on every dispatch and hold no
reviewable code. If the PR is `OPEN` or there is no PR at all, do **not** apply the
carve-out — keep the worktree 🔴, since there's no external record confirming the
branch's real content is done. Any tracked path outside the allowlist, in the same
worktree or not, keeps the worktree 🔴 regardless of PR status.

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

Bucket each worktree into one of ("no tracked modifications" = clean, dirty with
untracked/ignored files only, or dirty only on allowlisted bookkeeping files with a
closed/merged PR, per the dirty check above):

- **🟢 Safe to remove** — no tracked modifications, pushed, AND (branch merged OR PR merged)
- **🟡 Likely safe** — no tracked modifications, pushed, PR closed (not merged) — user may want to discard
- **🟠 Open PR** — no tracked modifications, has open PR — probably keep
- **🔴 Has work** — has tracked modifications OR has unpushed commits → never auto-suggest removal

A worktree whose only dirt is untracked/ignored files (`??` entries — session
scaffolding, `node_modules/`, caches) is treated as clean for classification and
removed with `git worktree remove --force` (see step 7).

### 4. "Possibly superseded" hint for 🔴 worktrees

A 🔴 worktree's uncommitted/unpushed content can turn out to be a duplicate of a fix
that already shipped under a **different** branch name — e.g. `fix-971-plus-one-party-together`
sitting unmerged while `fix-971-plus-one-solo-seat-fit` (same underlying issue,
different branch) already merged as PR #1024. The merged-check in step 3 only compares
a worktree's own branch name against `--merged`, so it cannot catch this. Run this
cheap hint check for every 🔴 worktree whose PR is `CLOSED` (not merged) or has no PR
at all — skip it for 🔴 worktrees with an `OPEN` PR (still active work, not a dup
candidate):

1. Pull the issue number out of the branch name (e.g. `fix-971-plus-one-party-together`
   → `971`). If the branch name has no leading issue number, skip this worktree's hint
   check — nothing to search for.
2. Search for other PRs referencing that issue number:
   ```bash
   gh pr list --search "971" --state all --json number,title,state,url
   ```
3. If a **merged** PR shows up that isn't this worktree's own PR, diff this worktree's
   touched files against that content to see if it's actually superseded:
   ```bash
   git -C <path> diff <branch> "origin/$BASE" -- <touched files>
   ```
   (`<touched files>` = the files changed in `git -C <path> log @{u}..HEAD --stat` or,
   for unpushed/uncommitted work, `git -C <path> status --porcelain` plus
   `git -C <path> diff HEAD --stat`.) A small/empty diff on the overlapping files is a
   strong signal the same fix already shipped under the other branch/PR.
4. If step 3 suggests an overlap, surface it in the report (step 5) as:
   ```
   🔴 ../myapp-fix-971-party-together   fix-971-plus-one-party-together   may already be shipped under PR #1024
   ```
   This is a **hint, not a verdict** — still requires a human `git diff` glance to
   confirm before removal. Never auto-remove a 🔴 worktree based on this hint alone,
   and never run this check in `--noninteractive` mode (it's informational only, for
   the interactive report).

### 5. Present the list

Show a table like:

```
PATH                            BRANCH                            STATUS
🟢 ../myapp-feat-foo            feat-foo                          PR #123 merged
🟢 ../myapp-fix-bar             fix-bar                           merged into main
🟡 ../myapp-experiment-baz      experiment-baz                    PR #99 closed (not merged)
🟠 ../myapp-feat-qux            feat-qux                          PR #124 open
🔴 ../myapp-wip-thing           wip-thing                         tracked changes, 3 unpushed commits
🔴 ../myapp-fix-971-together    fix-971-plus-one-party-together   may already be shipped under PR #1024
```

### 6. Ask what to remove

Offer choices:
- Remove all 🟢
- Remove all 🟢 and 🟡
- Pick individually
- Cancel

If "pick individually", ask for each one separately — show its details before each prompt.

**In `--noninteractive` mode, skip this step entirely** and select exactly the 🟢 bucket —
no prompt, never 🟡 (a closed-but-unmerged PR can still hold work worth a human
glance).

🔴 worktrees are never removed by this skill. Tell the user to handle them manually with `/delete-worktree` after committing/pushing — pass along any "possibly superseded" hint from step 4 so they know where to look first.

### 7. Remove the chosen worktrees

Issue `git worktree remove` calls in **small batches instead of one long shell
loop** — a loop over a large worktree count (e.g. 16+) can run past the tool's
command timeout partway through, leaving some removed and some not with no clear
resume point. Chunk the selected worktrees into groups of **5** and issue each
chunk as its own tool call (or, in an interactive shell, its own loop iteration
batch), checking the result before moving to the next chunk:

```bash
# Chunk 1 of N (worktrees 1-5)
git worktree remove <path1>
git worktree remove <path2>
git worktree remove <path3>
git worktree remove <path4>
git worktree remove <path5>
```

Then chunk 2, etc. If a chunk fails partway (e.g. hits a timeout), the remaining
chunks are unaffected and resuming means re-running just the failed/not-yet-run
entries, not the whole batch.

If the worktree is dirty with untracked/ignored files only (a 🟢/🟡 that was kept
eligible by the untracked-only allowance), **or** dirty only on allowlisted
bookkeeping files under the closed/merged-PR carve-out from step 3, plain `remove`
fails with *"contains modified or untracked files"* — use `--force`:

```bash
git worktree remove --force <path>
```

`--force` here discards only untracked/ignored files (session scaffolding, caches)
or allowlisted bookkeeping files (`.claude/task.md`, `.claude/question.md`) whose
PR is already closed/merged; worktrees with any other tracked modifications are 🔴
and never reach this step, so no real work is destroyed.

After each removal, ask whether to also delete the local branch:

```bash
git branch -d <branch>     # safe delete (fails if unmerged)
```

Batch the branch-delete prompt with a "yes to all" / "no to all" option to avoid repetitive confirmation.

**In `--noninteractive` mode, skip the branch-delete prompt and run `git branch -d`** for
each removed worktree (safe delete only — a 🟢 branch is merged, so it succeeds;
never `-D`).

### 8. Report

Summarize:
- N worktrees removed
- M branches deleted
- K worktrees skipped (and why)
- Any 🔴 worktrees flagged "possibly superseded" in step 4, with the candidate PR

Run `git worktree list` once more and show what's left.

## Notes

- This skill does NOT delete remote branches on GitHub.
- It does NOT touch the main worktree.
- It does NOT remove worktrees with **tracked** uncommitted modifications or unpushed
  work, even if the user says "remove all". Untracked/ignored-only dirt (session
  scaffolding, caches) does not count as work and is discarded with `--force` when the
  worktree is otherwise 🟢. The one narrow exception is the bookkeeping allowlist
  carve-out (`.claude/task.md`, `.claude/question.md`) in step 3, gated on the
  branch's PR being closed or merged — every other tracked path keeps a worktree 🔴.
- The "possibly superseded" hint (step 4) is informational only — it never changes a
  worktree's bucket or triggers auto-removal, and it does not run in `--noninteractive`
  mode.
- If `gh` isn't authenticated or the repo isn't on GitHub, fall back to the local `--merged` check and skip the PR-status column and the superseded-hint step (both need `gh`).
