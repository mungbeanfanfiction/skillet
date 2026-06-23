#!/usr/bin/env bash
# Resume an OWNED worktree after an ANSWERED design question. Unlike restart.sh,
# this does NOT burn the restart budget — answering a question is not a stall.
# Usage: resume.sh <worktree-path> <issue>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WT="$1"; ISSUE="$2"; TASK="$WT/.claude/task.md"

[ "$(is_owned "$WT")" = true ] || { echo "refusing: $WT is not owned"; exit 1; }
[ -f "$TASK" ] || { echo "no task.md at $WT — refusing resume"; exit 1; }

# Clear the question marker so the worktree leaves needs-input.
rm -f "$WT/.claude/question.md"

PROMPT="$(python3 - "$LIB_DIR" "$ISSUE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import spawn
print(spawn.resume_prompt(issue=sys.argv[2]))
PY
)"
CLAUDE="$(resolve_claude)"
cd "$WT"
nohup "$CLAUDE" -p "$PROMPT" --permission-mode acceptEdits --add-dir "$WT" \
  > "$WT/.claude/session.log" 2>&1 &
echo $! > "$WT/.claude/session.pid"
echo "resumed #$ISSUE → $WT (pid $(cat "$WT/.claude/session.pid"))"
