---
name: delete-worktree
description: Safely remove a git worktree. Checks for uncommitted changes and unmerged/unpushed commits before removing. Optionally deletes the branch too. Supports an autonomous (--noninteractive) mode for unattended callers like /issue-supervisor that act on the safety-check result without prompting. Use when done with a feature and ready to clean up its worktree.
argument-hint: "<worktree-path-or-branch-name> [--noninteractive]"
---

# Delete Worktree Skill

Remove a worktree without losing work. Always check for uncommitted/unpushed state before removing.

## When Invoked

Argument can be:
- A path (absolute or relative) to a worktree
- A branch name — resolve to the matching worktree via `git worktree list --porcelain`

If no argument, list all worktrees and ask which to delete.

### Autonomous mode (`--noninteractive`)

When invoked with `--noninteractive` (e.g. from `/issue-supervisor` or any unattended
loop), run **non-interactively**: perform every safety check below and **act on
its result instead of prompting**. The rule is:

- If the worktree has **no tracked modifications, is fully pushed, and is merged**
  (branch merged into the base OR its PR is merged/closed) → remove it (and delete
  the local branch) without asking. Untracked or gitignored dirt alone — supervisor
  runtime state, caches, `node_modules/` — does not block removal.
- If any safety check **fails** (tracked modifications, unpushed commits, or an
  unmerged branch with no merged/closed PR) → do **not** remove anything. Skip the
  worktree and report why. Autonomous mode never destroys unsaved or unmerged work;
  it only removes what is provably safe.

`--noninteractive` removes the interactive confirmation, not the safety checks. It requires
an explicit worktree argument; it never operates on the "no argument → list and
pick" path.

## Workflow

### 1. Resolve the target

```bash
git worktree list --porcelain
```

Match the argument against `worktree` paths or `branch` entries. If multiple match, list them and ask the user to pick.

Refuse to delete:
- The main worktree (the first entry of `git worktree list`)
- The worktree you're currently inside (`pwd` matches the target) — tell the user to `cd` elsewhere first

### 2. Safety checks

Run all of these in the target worktree (`git -C <path> ...`):

**Uncommitted changes:**
```bash
git -C <path> status --porcelain
```
Not all dirt is equal. `--porcelain` already omits gitignored files (so supervisor
runtime state like `.claude/task.md` never shows up), and untracked `??` entries are
scaffolding and caches rather than work. Only **tracked** modifications — any entry whose
two-char status code does not start with `?` (` M`, `MM`, `A `, `D `, `R `, `UU`, …) —
represent work that removing the worktree would destroy:

```bash
if git -C <path> status --porcelain | grep -q '^[^?]'; then echo "tracked-modified"; else echo "untracked-only-or-clean"; fi
```

(`grep -q '^[^?]'` matches only lines starting with a non-`?`. A clean tree gives empty
output → no match. Do **not** invert with `grep -qv '^?? '`: that exits 1 on empty input
and would mislabel a clean worktree as `tracked-modified`.)

If `tracked-modified`, show the user what's dirty and ask for explicit confirmation before
proceeding; in `--noninteractive` mode treat it as a failed check and skip this worktree
(never `--force`). If `untracked-only-or-clean`, the check passes — this matches
`cleanup-worktrees`, so a merged worktree carrying only runtime state is still removable.
Do not special-case individual tracked paths: any tracked modification fails the check.

**Unpushed commits:**
```bash
git -C <path> log @{u}..HEAD --oneline 2>/dev/null
```
If the branch has no upstream OR has commits ahead of upstream, warn the user and ask for confirmation. In `--noninteractive` mode, treat "no upstream" or "ahead of upstream" as a failed check: skip this worktree.

**Unmerged branch:**

Check whether the branch is merged into the default branch:
```bash
BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
git -C <path> branch --merged "origin/$BASE" | grep -q "<branch>"
```
If not merged, mention it — but it's fine to proceed if the PR was squash-merged (which doesn't show up in `--merged`). Cross-check with:
```bash
gh pr list --head <branch> --state merged --json number,url
```

### 3. Confirm

Summarize for the user:
- Worktree path
- Branch name
- Dirty: tracked-modified / untracked-only / clean
- Unpushed commits: count
- PR status: open / merged / closed / none

Ask: **"Remove this worktree? (y/n)"**

**In `--noninteractive` mode, skip this prompt.** Proceed to removal only if every safety
check in step 2 passed (no tracked modifications, pushed, merged/closed PR or merged
branch); otherwise skip the worktree and report the reason. Print the same summary to the
log so the action is auditable.

### 4. Remove the worktree

```bash
git worktree remove <path>
```

`git worktree remove` refuses to delete a worktree that holds *any* untracked file, so a
worktree that passed the safety check as `untracked-only` still needs `--force`:

```bash
git worktree remove --force <path>
```

Reach for `--force` in exactly two cases: an `untracked-only` worktree that passed every
safety check, or a `tracked-modified` one where the user explicitly confirmed discarding
their work. **Never `--force` a `tracked-modified` worktree without that confirmation** —
it discards uncommitted work irreversibly. `--noninteractive` mode only ever forces the
first case; a tracked modification fails the safety check and is skipped before this step.

### 5. Offer to delete the branch

Ask: **"Also delete the branch `<branch>`? (y/n)"**

If yes:
```bash
git branch -d <branch>     # safe delete (fails if unmerged)
# if user confirmed unmerged was OK in step 2:
git branch -D <branch>     # force delete
```

**In `--noninteractive` mode, skip the prompt and run the safe delete** (`git branch -d`).
Because the worktree only got removed when its branch was merged/closed, `-d`
succeeds; never fall back to `-D` in autonomous mode (an unexpected `-d` failure
means the branch was not actually merged — leave it and report).

### 6. Done

Confirm the worktree is gone with `git worktree list` and report back.

## Notes

- This skill does NOT delete the remote branch on GitHub. If desired, the user can `git push origin --delete <branch>` themselves, or GitHub may have already cleaned it up after the PR merged.
- If `git worktree remove` complains about a locked worktree, surface the message — don't auto-unlock.
