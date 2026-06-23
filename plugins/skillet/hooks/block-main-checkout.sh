#!/usr/bin/env bash
# PreToolUse hook: discourage edits in the primary git checkout.
#
# When multiple Claude sessions run against the same repo, editing the shared
# main checkout clobbers other sessions' work. Every session should work in its
# own git worktree instead.
#
# Detection: for the file being edited, run git in the file's own directory
# (NOT the hook's cwd). In the primary checkout `git rev-parse --git-dir`
# equals `--git-common-dir`; in a linked worktree they differ. This is
# branch-name independent, so it also catches a fresh branch created off main
# that was never moved into a worktree.
#
# Why the file's directory and not the cwd: a session can be launched from the
# main checkout while editing files by absolute path inside a worktree. Keying
# off the cwd would wrongly block those edits. We inspect where the target file
# actually lives instead.
#
# Behavior: if the target file lives in the main checkout, return
# permissionDecision "ask" so the edit is not silently blocked but requires
# explicit approval. In a worktree (or outside any git repo) emit nothing,
# letting the edit proceed.

set -euo pipefail

input=$(cat)

# Extract the target path from the tool input. Edit/Write carry file_path;
# NotebookEdit carries notebook_path.
target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)

# Determine the directory to run git in. For a new file (Write), the path may
# not exist yet, so walk up to the nearest existing ancestor directory.
if [ -n "$target" ]; then
  probe_dir=$(dirname "$target")
  while [ ! -d "$probe_dir" ] && [ "$probe_dir" != "/" ] && [ "$probe_dir" != "." ]; do
    probe_dir=$(dirname "$probe_dir")
  done
else
  # No target path available: fall back to the hook's cwd.
  probe_dir="."
fi

git_dir=$(git -C "$probe_dir" rev-parse --git-dir 2>/dev/null || true)
git_common_dir=$(git -C "$probe_dir" rev-parse --git-common-dir 2>/dev/null || true)

# Not in a git repo (or git unavailable): don't interfere.
[ -z "$git_dir" ] && exit 0

# Linked worktree: git-dir differs from the common dir. Allow.
[ "$git_dir" != "$git_common_dir" ] && exit 0

# Primary checkout: ask for confirmation.
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"You are editing in the MAIN CHECKOUT, not a worktree. With multiple sessions running, editing the shared main checkout will clobber other sessions. Create or switch to a git worktree first (e.g. /create-worktree). Approve only if you truly mean to edit the main checkout."}}'
