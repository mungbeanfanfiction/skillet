---
name: worktree-status
description: Report the current status of every git worktree — the work-in-progress narrative (from each worktree's STATUS.md) plus live git state (branch, dirty, ahead/behind, last commit). Flags stale or inactive worktrees. Use when you want to see what's going on across all your worktrees at a glance.
argument-hint: ""
model: haiku
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
