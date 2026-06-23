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
