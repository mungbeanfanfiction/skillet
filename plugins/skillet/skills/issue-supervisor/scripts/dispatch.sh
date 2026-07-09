#!/usr/bin/env bash
# Dispatch one task: worktree off latest origin/<base>, task.md, register, spawn.
# Usage: dispatch.sh <issue-or-id> <title> <slug> <source> [labels]
#   source: label|file   labels: comma-separated (e.g. "auto,explore"); used by
#   the session's pipeline to route `explore` issues to the explore-issue skill.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_tools

ISSUE="$1"; TITLE="$2"; SLUG="$3"; SOURCE="${4:-label}"; LABELS="${5:-}"
REPO="$(detect_repo)"; BASE="$(detect_base)"
BRANCH="auto-${ISSUE}-${SLUG}"
WT="$WORKTREES_DIR/$BRANCH"

# Assign only for label-sourced tasks: file-sourced ones use a synthetic id with no GH issue behind it.
if [ "$SOURCE" = "label" ]; then
  gh issue edit "$ISSUE" --repo "$REPO" --add-assignee @me >/dev/null 2>&1 || true
fi

# Branch off LATEST origin/<base>; skip on collision.
git -C "$REPO_ROOT" fetch origin "$BASE" >/dev/null 2>&1 || fail "git fetch failed"
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "skip: branch $BRANCH exists"; exit 0
fi
git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WT" "origin/$BASE" >/dev/null

# Symlink gitignored env-like files from the main repo (best-effort).
# `|| true` on grep: a no-match exit (1) must not abort the script under pipefail
# when the repo has no .env files.
git -C "$REPO_ROOT" ls-files --others --ignored --exclude-standard \
  | { grep -E '(^|/)\.env(\.|$)' || true; } | while read -r rel; do
    mkdir -p "$WT/$(dirname "$rel")"; ln -sfn "$REPO_ROOT/$rel" "$WT/$rel" 2>/dev/null || true
  done

mkdir -p "$WT/.claude"
cat > "$WT/.claude/task.md" <<EOF
# Task — issue #${ISSUE}
**Goal:** ${TITLE}
**Source:** ${SOURCE}
**Labels:** ${LABELS}
**Acceptance criteria:** see issue #${ISSUE} body.

## Pipeline stage
pickup

## Restart count
0

## Progress log
- dispatched
EOF

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Values passed as argv (never interpolated into a Python literal) so quotes in
# the path/title/etc. cannot break or inject.
python3 - "$LIB_DIR" "$REGISTRY" "$ISSUE" "$WT" "$BRANCH" "$SOURCE" "$NOW" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import registry
reg, issue_raw, path, branch, source, created = sys.argv[2:8]
issue = int(issue_raw) if issue_raw.isdigit() else issue_raw
registry.add(reg, issue=issue, path=path, branch=branch, source=source, created_at=created)
PY

PROMPT="$(python3 - "$LIB_DIR" "$ISSUE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import spawn
print(spawn.dispatch_prompt(issue=sys.argv[2]))
PY
)"
cd "$WT"
spawn_capped_session "$WT" "$PROMPT"   # detached, under the per-session wall-clock cap
echo "dispatched #$ISSUE → $WT (pid $(cat "$WT/.claude/session.pid"))"
