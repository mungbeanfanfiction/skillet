#!/usr/bin/env bash
# PreToolUse hook: discourage edits in the primary git checkout.
#
# When multiple Claude sessions run against the same repo, editing the shared
# main checkout clobbers other sessions' work. Every session should work in its
# own git worktree instead.
#
# Detection: in the primary checkout `git rev-parse --git-dir` equals
# `--git-common-dir`; in a linked worktree they differ. This is branch-name
# independent, so it also catches a fresh branch created off main that was
# never moved into a worktree.
#
# Behavior: in the main checkout, return permissionDecision "ask" so the edit
# is not silently blocked but requires explicit approval. In a worktree (or
# outside any git repo) emit nothing, letting the edit proceed.

set -euo pipefail

git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null || true)

# Not in a git repo (or git unavailable): don't interfere.
[ -z "$git_dir" ] && exit 0

# Linked worktree: git-dir differs from the common dir. Allow.
[ "$git_dir" != "$git_common_dir" ] && exit 0

# Primary checkout: ask for confirmation.
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"You are editing in the MAIN CHECKOUT, not a worktree. With multiple sessions running, editing the shared main checkout will clobber other sessions. Create or switch to a git worktree first (e.g. /create-worktree). Approve only if you truly mean to edit the main checkout."}}'
