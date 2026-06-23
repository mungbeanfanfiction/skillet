#!/usr/bin/env bash
# Dispatch one task: worktree off latest origin/<base>, task.md, register, spawn.
# Usage: dispatch.sh <issue-or-id> <title> <slug> <source>   (source: label|file)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_tools

ISSUE="$1"; TITLE="$2"; SLUG="$3"; SOURCE="${4:-label}"
REPO="$(detect_repo)"; BASE="$(detect_base)"
BRANCH="auto-${ISSUE}-${SLUG}"
WT="$WORKTREES_DIR/$BRANCH"

# Assign the issue to the current user (label source only).
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
git -C "$REPO_ROOT" ls-files --others --ignored --exclude-standard \
  | grep -E '(^|/)\.env(\.|$)' | while read -r rel; do
    mkdir -p "$WT/$(dirname "$rel")"; ln -sfn "$REPO_ROOT/$rel" "$WT/$rel" 2>/dev/null || true
  done

mkdir -p "$WT/.claude"
cat > "$WT/.claude/task.md" <<EOF
# Task — issue #${ISSUE}
**Goal:** ${TITLE}
**Source:** ${SOURCE}
**Acceptance criteria:** see issue #${ISSUE} body.

## Pipeline stage
pickup

## Restart count
0

## Progress log
- dispatched
EOF

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
py "from supervisorlib import registry; registry.add('$REGISTRY', issue='$ISSUE' if not '$ISSUE'.isdigit() else int('$ISSUE'), path='$WT', branch='$BRANCH', source='$SOURCE', created_at='$NOW')"

PROMPT="$(py "from supervisorlib import spawn; print(spawn.dispatch_prompt(issue='$ISSUE'))")"
cd "$WT"
nohup claude -p "$PROMPT" --permission-mode acceptEdits --add-dir "$WT" \
  > "$WT/.claude/session.log" 2>&1 &
echo $! > "$WT/.claude/session.pid"
echo "dispatched #$ISSUE → $WT (pid $(cat "$WT/.claude/session.pid"))"
