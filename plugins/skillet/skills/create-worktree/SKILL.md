---
name: create-worktree
description: Create a git worktree for a task or GitHub issue, with untracked dotfiles (.env, etc.) symlinked from the main repo. Does NOT merge or push. Use when starting isolated work on a feature, bug fix, or issue.
argument-hint: "<branch-name-or-issue-number> [description] [--yes]"
---

# Create Worktree Skill

Use a separate git worktree to isolate work on a task. This keeps the main working directory clean and allows parallel work on multiple tasks.

## When Invoked

Parse the argument:
- If it's a number → treat as a GitHub issue number; fetch the issue title and use it to derive a branch name
- Otherwise → treat as a branch name (with optional free-text description as the remaining args)

## Non-interactive mode

When invoked with a `--yes` flag (e.g. by another skill or the autonomous queue),
**skip every confirmation prompt** below and proceed with the documented default
choice instead. Specifically: do not ask the user to confirm the branch name or
the worktree path, and do not ask about issue assignment (skip assignment unless a
flag explicitly requests it). In non-interactive mode the skill must never block
on input.

## Workflow

### 1. Resolve repo + branch name

Detect the repo from the current working directory:

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
```

If an issue number was provided, fetch it:

```bash
gh issue view <number> --repo "$REPO" --json number,title,url
```

Derive a branch name from the issue title (or the user's argument): lowercase, hyphens, no special chars. Use a conventional prefix only if the repo's existing branch history shows the user normally uses one — and separate the prefix with a hyphen, not a slash (`refactor-...`, `feat-...`, `fix-...`, never `refactor/...`). Otherwise leave it un-prefixed.

Ask the user to confirm the proposed branch name before creating anything. (In
non-interactive mode, skip this and use the derived name.)

### 2. Pick the worktree location

Default: `<repo-root>/.claude/worktrees/<branch-name>`. Branch names use hyphens (no slashes), so the directory stays flat without any transformation. So for a repo on branch `feat-foo`, the worktree would be `<repo-root>/.claude/worktrees/feat-foo`.

Always anchor to the repo root — don't use a bare relative path, since the working directory may be a subdirectory of the repo:

```bash
ROOT=$(git rev-parse --show-toplevel)
WORKTREE="$ROOT/.claude/worktrees/<branch-name>"
```

But check existing convention first:

```bash
git worktree list
```

If the repo already keeps worktrees somewhere else (e.g. sibling directories, or a `.worktrees/` subdir), match that instead.

Confirm the chosen path with the user before proceeding. (In non-interactive mode,
skip this and use the chosen path.)

### 3. Create the worktree

Make sure the worktree dir is ignored so it doesn't pollute the main repo's `git status`. If `git -C "$ROOT" check-ignore .claude/worktrees/` comes up empty, add `.claude/worktrees/` to `$ROOT/.gitignore` (or `$ROOT/.git/info/exclude` to keep the rule uncommitted).

Also ensure the per-worktree status directory is excluded so the skillet worktree-status hook's `STATUS.md` never pollutes `git status`. If `git -C "$ROOT" check-ignore .claude/status/` comes up empty, add `.claude/status/` to `$ROOT/.git/info/exclude` (keeping the rule uncommitted, matching how `.claude/worktrees/` is handled).

Fetch the latest default branch first so the new branch starts from up-to-date code rather than whatever your current `HEAD` happens to be. Resolve the default branch from the remote, fetch it, and branch off it:

```bash
DEFAULT_BRANCH=$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
git -C "$ROOT" fetch origin "$DEFAULT_BRANCH"
git worktree add "$WORKTREE" -b <branch-name> "origin/$DEFAULT_BRANCH"
# e.g. branch feat-foo off latest origin/main → <repo-root>/.claude/worktrees/feat-foo
```

If the repo has no `origin` remote, fall back to branching off the local default branch:

```bash
git worktree add "$WORKTREE" -b <branch-name> "$DEFAULT_BRANCH"
```

### 4. Symlink untracked dotfiles from the main repo

Worktrees share the git history but not the working tree, so files like `.env`, `.env.local`, etc. don't carry over. Most projects need these to run.

Find the main worktree path:

```bash
MAIN=$(git -C <new-worktree-path> worktree list --porcelain | head -1 | sed 's/^worktree //')
```

Symlink any gitignored env-like files from the main into the same relative path in the new worktree:

```bash
# Discover ignored env-like files in the main repo:
git -C "$MAIN" ls-files --others --ignored --exclude-standard \
    | grep -E '(^|/)\.env(\.|$)' \
    | while read -r rel; do
        mkdir -p "<new-worktree-path>/$(dirname "$rel")"
        ln -sfn "$MAIN/$rel" "<new-worktree-path>/$rel"
    done
```

`ln -sfn` makes this idempotent — safe to re-run.

If the user's project needs other untracked files symlinked (e.g. local config, secrets, certificates), ask before adding them — don't guess.

### 5. (Optional) Assign the GitHub issue

If an issue number was used and the user wants it assigned to them:

```bash
gh issue edit <number> --repo "$REPO" --add-assignee @me
```

Ask first — not every workflow uses issue assignment. (In non-interactive mode,
skip assignment entirely unless explicitly requested.)

### 6. Hand off

Tell the user the worktree path. They can `cd` into it to work, or start a new Claude session there.

## Notes

- Never commit directly to `main`/`master` in the worktree — always work on the new branch.
- Run `git worktree list` anytime to see all active worktrees.
- To remove a worktree, use `/delete-worktree`.
- To bulk-clean merged worktrees, use `/cleanup-worktrees`.
- The main repo's running processes (dev server, db, etc.) keep working — worktrees share git history but have their own working tree.
