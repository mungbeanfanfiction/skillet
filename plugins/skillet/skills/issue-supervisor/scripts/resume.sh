#!/usr/bin/env bash
# Resume an OWNED worktree after an ANSWERED design question. Unlike restart.sh,
# this does NOT burn the restart budget — answering a question is not a stall.
# Usage: resume.sh <worktree-path> <issue>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WT="$1"; ISSUE="$2"; TASK="$WT/.claude/task.md"

owned="$(py "from supervisorlib import registry; print('true' if registry.is_owned('$REGISTRY','$WT') else 'false')")"
[ "$owned" = true ] || { echo "refusing: $WT is not owned"; exit 1; }
[ -f "$TASK" ] || { echo "no task.md at $WT — refusing resume"; exit 1; }

# Clear the question marker so the worktree leaves needs-input.
rm -f "$WT/.claude/question.md"

PROMPT="$(py "from supervisorlib import spawn; print(spawn.resume_prompt(issue='$ISSUE'))")"
cd "$WT"
nohup claude -p "$PROMPT" --permission-mode acceptEdits --add-dir "$WT" \
  > "$WT/.claude/session.log" 2>&1 &
echo $! > "$WT/.claude/session.pid"
echo "resumed #$ISSUE → $WT (pid $(cat "$WT/.claude/session.pid"))"
