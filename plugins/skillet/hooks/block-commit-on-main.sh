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
# start from the session cwd in the hook input, then honor a leading
# `cd <dir> &&` (Claude Code now prefixes commands this way to target a
# worktree while the hook runs from the primary checkout) and `git -C <path>`,
# so a commit targeting another worktree is judged by THAT worktree's branch.
# A detached HEAD or any non-default branch is allowed; only main/master/trunk
# is blocked.

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

# Resolve a path token against a base dir: strip surrounding quotes, expand a
# leading ~, and make relative paths relative to the base.
resolve_dir() {
  local p="$1" base="$2"
  p="${p#\"}"; p="${p%\"}"; p="${p#\'}"; p="${p%\'}"
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in
    /*) printf '%s' "$p" ;;
    *) printf '%s/%s' "$base" "$p" ;;
  esac
}

# Start from the session's cwd (hook input), falling back to the hook's own cwd.
probe_dir="$(jq -r '.cwd // ""' <<<"$input")"
[ -n "$probe_dir" ] && [ -d "$probe_dir" ] || probe_dir="."

# A leading `cd <dir> &&` (or `;`) moves the commit into <dir>.
cd_target="$(printf '%s' "$command" | sed -nE 's/^[[:space:]]*cd[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:];&|]+)[[:space:]]*(&&|;).*/\1/p')"
if [ -n "$cd_target" ]; then
  cd_dir="$(resolve_dir "$cd_target" "$probe_dir")"
  [ -d "$cd_dir" ] && probe_dir="$cd_dir"
fi

# A `-C <dir>` on the git invocation wins, resolved relative to the above.
c_target="$(printf '%s' "$command" | sed -nE 's/.*git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-C[[:space:]]+("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:];&|]+).*/\2/p')"
if [ -n "$c_target" ]; then
  c_dir="$(resolve_dir "$c_target" "$probe_dir")"
  [ -d "$c_dir" ] && probe_dir="$c_dir"
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
