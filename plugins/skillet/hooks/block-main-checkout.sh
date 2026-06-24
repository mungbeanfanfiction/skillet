#!/usr/bin/env bash
# PreToolUse hook: block edits in the primary git checkout.
#
# When multiple Claude sessions run against the same repo, editing the shared
# main checkout clobbers other sessions' work. Every session should work in its
# own git worktree instead.
#
# Detection: resolve the git dir for the TARGET FILE's location (not the hook's
# cwd). In the primary checkout `--git-dir` and `--git-common-dir` resolve to
# the same place; in a linked worktree `--git-dir` lives under
# `<common>/worktrees/<name>` and so differs. This is branch-name independent,
# so it also catches a fresh branch created off main that was never moved into
# a worktree.
#
# Why the file's directory and not the cwd: a session can be launched from the
# main checkout while editing files by absolute path inside a worktree. Keying
# off the cwd would wrongly block those edits. We inspect where the target file
# actually lives instead.
#
# New-file care: for a Write to a path that does not exist yet, we walk up to
# the nearest existing ancestor — but ONLY within the same worktree. Worktrees
# live at <repo-root>/.claude/worktrees/<branch>, i.e. INSIDE the main
# checkout's tree, so a naive walk-up can escape a not-yet-created worktree dir
# and land on the main checkout's own .claude/worktrees/, falsely flagging the
# edit as a main-checkout edit. To avoid that, when the walk-up lands somewhere
# that resolves to the primary checkout, we additionally check whether the
# ORIGINAL target path is under any linked worktree's root and, if so, allow it.
#
# Behavior: if the target file lives in the primary checkout, return
# permissionDecision "deny" so edits to main are blocked outright. The user can
# still proceed by explicitly instructing it. In a worktree (or outside any git
# repo) emit nothing, letting the edit proceed.

set -euo pipefail

input=$(cat)

# Extract the target path from the tool input. Edit/Write carry file_path;
# NotebookEdit carries notebook_path.
target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)

# No target path: fall back to the hook's cwd for the probe.
if [ -z "$target" ]; then
  probe_dir="."
else
  # For a new file the path may not exist yet; walk up to the nearest existing
  # ancestor directory so `git -C` has somewhere real to run.
  probe_dir=$(dirname "$target")
  while [ ! -d "$probe_dir" ] && [ "$probe_dir" != "/" ] && [ "$probe_dir" != "." ]; do
    probe_dir=$(dirname "$probe_dir")
  done
fi

# Resolve both git dirs to ABSOLUTE paths. `git rev-parse` may return one as
# absolute and the other relative (relative to the -C dir), so a raw string
# compare would spuriously differ even when they point at the same .git. Run
# rev-parse with --absolute-git-dir / -C to normalize.
git_dir=$(git -C "$probe_dir" rev-parse --absolute-git-dir 2>/dev/null || true)
git_common_dir=$(git -C "$probe_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)

# Not in a git repo (or git unavailable): don't interfere.
[ -z "$git_dir" ] && exit 0

# Linked worktree: git-dir differs from the common dir. Allow.
[ "$git_dir" != "$git_common_dir" ] && exit 0

# At this point the PROBE dir resolved to the primary checkout. This is either a
# genuine main-checkout edit, OR a new file inside a not-yet-created worktree
# whose walk-up escaped into the main tree (worktrees live under the main
# checkout at .claude/worktrees/<branch>). Disambiguate by checking whether the
# original target path is under any linked worktree's root.
if [ -n "$target" ]; then
  # Absolute-ize the target without requiring it to exist.
  case "$target" in
    /*) abs_target="$target" ;;
    *)  abs_target="$(pwd)/$target" ;;
  esac

  # List every linked worktree root (skip the first entry, the main checkout).
  while IFS= read -r wt_root; do
    [ -z "$wt_root" ] && continue
    case "$abs_target/" in
      "$wt_root"/*) exit 0 ;;  # target lives inside a linked worktree → allow
    esac
  done < <(git -C "$probe_dir" worktree list --porcelain 2>/dev/null \
             | awk '/^worktree / { print substr($0, 10) }' | tail -n +2)
fi

# Genuine primary-checkout edit: deny.
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Editing the MAIN CHECKOUT is blocked. With multiple sessions running, editing the shared main checkout clobbers other sessions. Create or switch to a git worktree first (e.g. /create-worktree) and edit there. If you genuinely intend to edit the main checkout, the user can explicitly instruct you to proceed."}}'
