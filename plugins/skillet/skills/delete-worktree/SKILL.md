---
name: delete-worktree
description: Safely remove a git worktree. Checks for uncommitted changes and unmerged/unpushed commits before removing. Optionally deletes the branch too. Use when done with a feature and ready to clean up its worktree.
argument-hint: "<worktree-path-or-branch-name>"
---

# Delete Worktree Skill

Remove a worktree without losing work. Always check for uncommitted/unpushed state before removing.

## When Invoked

Argument can be:
- A path (absolute or relative) to a worktree
- A branch name — resolve to the matching worktree via `git worktree list --porcelain`

If no argument, list all worktrees and ask which to delete.

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
If non-empty, show the user what's dirty and ask for explicit confirmation before proceeding.

**Unpushed commits:**
```bash
git -C <path> log @{u}..HEAD --oneline 2>/dev/null
```
If the branch has no upstream OR has commits ahead of upstream, warn the user and ask for confirmation.

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
- Dirty: yes/no
- Unpushed commits: count
- PR status: open / merged / closed / none

Ask: **"Remove this worktree? (y/n)"**

### 4. Remove the worktree

```bash
git worktree remove <path>
```

If the worktree has uncommitted changes and the user confirmed proceeding anyway, use `--force`:

```bash
git worktree remove --force <path>
```

**Never use `--force` without explicit user confirmation** — it discards uncommitted changes irreversibly.

### 5. Offer to delete the branch

Ask: **"Also delete the branch `<branch>`? (y/n)"**

If yes:
```bash
git branch -d <branch>     # safe delete (fails if unmerged)
# if user confirmed unmerged was OK in step 2:
git branch -D <branch>     # force delete
```

### 6. Done

Confirm the worktree is gone with `git worktree list` and report back.

## Notes

- This skill does NOT delete the remote branch on GitHub. If desired, the user can `git push origin --delete <branch>` themselves, or GitHub may have already cleaned it up after the PR merged.
- If `git worktree remove` complains about a locked worktree, surface the message — don't auto-unlock.
