#!/usr/bin/env bash
# PreToolUse hook for Bash: block `git commit` when HEAD is on the default
# branch (main/master/trunk).
#
# Complements block-main-checkout.sh (which guards Edit/Write): even if files
# are edited correctly inside a worktree, a stray `git commit` run while the
# session sits on the primary checkout's main branch would land commits on
# main. With multiple sessions sharing a repo, commits belong on feature
# branches in worktrees, never on main. This denies the commit at the source.
#
# Detection: resolve the branch for the directory the commit will run in. We
# honor `git -C <path>` in the command so a commit targeting another worktree
# is judged by THAT worktree's branch, not the hook's cwd. A detached HEAD or
# any non-default branch is allowed; only main/master/trunk is blocked.

set -euo pipefail

input="$(cat)"
tool_name="$(jq -r '.tool_name // ""' <<<"$input")"
command="$(jq -r '.tool_input.command // ""' <<<"$input")"

if [ "$tool_name" != "Bash" ] || [ -z "$command" ]; then
  exit 0
fi

# Match `git commit` as a command, allowing intervening global flags like
# `git -C /path commit` or `git --git-dir=... commit`. Anchored on a boundary
# before `git` so we don't false-positive on `git commit` inside a quoted
# string (e.g. an echo). `commit` must be its own token.
if ! printf '%s' "$command" \
  | grep -qE '(^|[[:space:]]|;|&&|\|\||\||\()git([[:space:]]+[^[:space:];&|()]+)*[[:space:]]+commit([[:space:]]|;|&&|\|\||\||\)|$)'; then
  exit 0
fi

# Extract a `-C <dir>` target from the command, if present, so we evaluate the
# branch of the directory the commit actually runs in. Falls back to the hook's
# cwd otherwise.
probe_dir="."
c_target="$(printf '%s' "$command" | sed -nE 's/.*git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-C[[:space:]]+([^[:space:]]+).*/\2/p')"
if [ -n "$c_target" ] && [ -d "$c_target" ]; then
  probe_dir="$c_target"
fi

# Resolve the current branch. Detached HEAD yields empty → allow.
branch="$(git -C "$probe_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

# Not in a git repo, or detached HEAD: don't interfere.
[ -z "$branch" ] && exit 0

case "$branch" in
  main|master|trunk)
    reason="blocked: committing on '$branch' is not allowed. Commits belong on a feature branch in a git worktree, never on the primary checkout's default branch — a commit here clobbers the shared main branch other sessions depend on. Create or switch to a worktree (e.g. /create-worktree) and commit there. If you genuinely intend to commit to $branch, the user can explicitly instruct you to proceed."
    jq -n --arg r "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
    ;;
  *)
    exit 0
    ;;
esac
