#!/usr/bin/env bash
# Regression test for issue #100: restart.sh must refuse to restart a worktree
# that has already hit the restart cap (classify() routes it to BLOCKED, not
# STALLED). Without this guard, a caller that mis-invokes restart.sh on a capped
# worktree would keep respawning it forever — the slot still frees correctly
# (BLOCKED is never in-flight), but the "dead" worktree leaks live sessions.
set -uo pipefail

SKILL_SCRIPTS="$1"   # path to issue-supervisor/scripts
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q

WT="$TMP/wt"; mkdir -p "$WT/.claude"
git -C "$WT" init -q 2>/dev/null || true

# RESTART_CAP is 2 (supervisorlib/state.py) — pre-set the worktree's task.md to
# already be AT the cap, as if two restarts already happened.
cat > "$WT/.claude/task.md" <<'EOF'
# Task — issue #999
## Pipeline stage
pickup

## Restart count
2

## Progress log
- dispatched
EOF

cd "$TMP"
# shellcheck disable=SC1090
source "$SKILL_SCRIPTS/common.sh"

# Register the worktree as owned so is_owned passes.
python3 - "$LIB_DIR" "$REGISTRY" "$WT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import registry
registry.add(sys.argv[2], issue=999, path=sys.argv[3], branch="auto-999-x",
             source="label", created_at="2026-01-01T00:00:00Z")
PY

OUT="$(bash "$SKILL_SCRIPTS/restart.sh" "$WT" 999 2>&1)"
RC=$?
echo "$OUT"

# Restart count must be unchanged (no respawn attempted).
NEW_COUNT="$(awk '/## Restart count/{getline; print $1; exit}' "$WT/.claude/task.md")"

if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qi "restart cap" && [ "$NEW_COUNT" = "2" ] && [ ! -f "$WT/.claude/session.pid" ]; then
  echo "PASS: restart.sh refused to restart a worktree already at the restart cap"
  exit 0
else
  echo "FAIL: restart.sh did not refuse (rc=$RC, restart_count=$NEW_COUNT, session.pid exists=$([ -f "$WT/.claude/session.pid" ] && echo yes || echo no))"
  exit 1
fi
