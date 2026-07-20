#!/usr/bin/env bash
# Regression test for block-commit-on-main.sh's directory resolution:
# `cd <dir> &&`, `git -C <dir>`, and the combination of both must all be
# judged by the TARGET directory's branch, not the hook process's cwd.
set -euo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/block-commit-on-main.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# main_repo: a repo on branch "main" (hook's own cwd starts here)
git init -q -b main "$WORK/main_repo"
git -C "$WORK/main_repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# feature_repo: a separate repo checked out on a feature branch
git init -q -b main "$WORK/feature_repo"
git -C "$WORK/feature_repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WORK/feature_repo" checkout -q -b my-feature

run_hook() {
  local command="$1"
  local cwd="$2"
  (cd "$cwd" && jq -n --arg cmd "$command" '{tool_name: "Bash", tool_input: {command: $cmd}}' | "$HOOK")
}

pass=0
fail=0

check_denied() {
  local desc="$1" out="$2"
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
    echo "ok - $desc"
    pass=$((pass + 1))
  else
    echo "FAIL - $desc (expected deny, got: $out)"
    fail=$((fail + 1))
  fi
}

check_allowed() {
  local desc="$1" out="$2"
  if [ -z "$out" ]; then
    echo "ok - $desc"
    pass=$((pass + 1))
  else
    echo "FAIL - $desc (expected allow/empty, got: $out)"
    fail=$((fail + 1))
  fi
}

# Committing directly on main (hook's own cwd) is still blocked.
out="$(run_hook 'git commit -m x' "$WORK/main_repo")"
check_denied "plain commit on main is blocked" "$out"

# Old-style `git -C <dir> commit` targeting a feature branch is still allowed.
out="$(run_hook "git -C $WORK/feature_repo commit -m x" "$WORK/main_repo")"
check_allowed "git -C targeting feature branch is allowed" "$out"

# `git -C <dir> commit` targeting main is still blocked from anywhere.
out="$(run_hook "git -C $WORK/main_repo commit -m x" "$WORK/feature_repo")"
check_denied "git -C targeting main is blocked" "$out"

# The bug this test guards: `cd <worktree> && git commit` must be judged
# by the worktree's branch, not the hook's own cwd (which is main_repo).
out="$(run_hook "cd $WORK/feature_repo && git commit -m x" "$WORK/main_repo")"
check_allowed "cd-prefixed commit into feature worktree is allowed" "$out"

out="$(run_hook "cd $WORK/main_repo && git commit -m x" "$WORK/feature_repo")"
check_denied "cd-prefixed commit into main worktree is blocked" "$out"

# cd with a relative -C afterwards resolves relative to the cd target.
out="$(run_hook "cd $WORK && git -C feature_repo commit -m x" "$WORK/main_repo")"
check_allowed "cd + relative -C resolves relative to cd target" "$out"

echo "---"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
