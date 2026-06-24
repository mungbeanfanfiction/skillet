#!/usr/bin/env bash
# Shared helpers for supervisor scripts. Source this; do not execute.
# Resolves repo-agnostic context (REPO, BASE), runtime-state dir, and lib dir.
set -euo pipefail

# LIB_DIR resolves relative to THIS file, so it works regardless of where the
# plugin is installed. Scripts that source common.sh are in scripts/, so the
# lib is one dir up.
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$COMMON_DIR/.." && pwd)"
LIB_DIR="$SKILL_DIR/lib"

# Anchor to the MAIN worktree, never the current one. `--show-toplevel` returns
# whatever worktree the loop happens to run from, which would (a) nest dispatched
# worktrees and (b) — worse — put runtime state (registry/locks) under a different
# path per cwd, so the supervisor would lose track of worktrees it owns. The main
# checkout is the parent of the shared .git common dir, stable from any worktree.
REPO_ROOT="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd)"
STATE_DIR="$REPO_ROOT/.claude/issue-supervisor"
REGISTRY="$STATE_DIR/registry.json"
WORKTREES_DIR="$REPO_ROOT/.claude/worktrees"

fail() { printf '{"error": %s}\n' "$(jq -Rn --arg m "$1" '$m')"; exit 1; }

require_tools() {
  command -v gh >/dev/null || fail "gh not installed"
  command -v jq >/dev/null || fail "jq not installed"
  command -v git >/dev/null || fail "git not installed"
}

# Repo-agnostic identifiers (no hard-coded owner/name/branch).
detect_repo() { gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || fail "gh repo view failed"; }
detect_base() { gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main"; }

# NOTE: the repo's CI command is detected by the dispatched SESSION at runtime
# (the order — make ci → make agent-ci → npm test → pytest → documented check — is
# in spawn.PIPELINE), not here, so there is no detect_ci_cmd() helper. Add one
# only if a script ever needs to run CI directly.

py() { python3 -c "import sys; sys.path.insert(0,'$LIB_DIR'); $1"; }

# Ownership check for a worktree path. The path is passed as argv (NOT
# interpolated into a Python literal), so a quote in the path — possible when the
# user's checkout lives under e.g. /Users/o'brien — cannot break or inject.
# Prints "true" / "false".
is_owned() {
  python3 - "$LIB_DIR" "$REGISTRY" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import registry
print("true" if registry.is_owned(sys.argv[2], sys.argv[3]) else "false")
PY
}

# Resolve the claude executable for detached (nohup) spawns. `claude` is often a
# shell ALIAS (e.g. -> ~/.claude/local/claude), which does NOT survive into the
# non-interactive subshell nohup runs, so we cannot rely on bare `claude`.
# Order: explicit $CLAUDE_BIN override → PATH lookup → the standard local install.
resolve_claude() {
  if [ -n "${CLAUDE_BIN:-}" ] && [ -x "$CLAUDE_BIN" ]; then echo "$CLAUDE_BIN"; return; fi
  local p; p="$(command -v claude 2>/dev/null || true)"
  if [ -n "$p" ]; then echo "$p"; return; fi
  if [ -x "$HOME/.claude/local/claude" ]; then echo "$HOME/.claude/local/claude"; return; fi
  fail "claude executable not found (set CLAUDE_BIN or install the CLI)"
}

mkdir -p "$STATE_DIR"
