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

REPO_ROOT="$(git rev-parse --show-toplevel)"
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

# Print the repo's check command, or empty string if none detected.
detect_ci_cmd() {
  if [ -f "$REPO_ROOT/Makefile" ] && grep -qE '^ci:' "$REPO_ROOT/Makefile"; then echo "make ci"; return; fi
  if [ -f "$REPO_ROOT/Makefile" ] && grep -qE '^agent-ci:' "$REPO_ROOT/Makefile"; then echo "make agent-ci"; return; fi
  if [ -f "$REPO_ROOT/package.json" ] && grep -q '"test"' "$REPO_ROOT/package.json"; then echo "npm test"; return; fi
  if [ -f "$REPO_ROOT/pytest.ini" ] || [ -f "$REPO_ROOT/pyproject.toml" ]; then echo "pytest"; return; fi
  echo ""
}

py() { python3 -c "import sys; sys.path.insert(0,'$LIB_DIR'); $1"; }

mkdir -p "$STATE_DIR"
