#!/usr/bin/env bash
# Restart a stalled OWNED worktree: assert ownership, increment restart count,
# respawn detached. Refuses if a question is pending. Usage: restart.sh <wt> <issue>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WT="$1"; ISSUE="$2"; TASK="$WT/.claude/task.md"

# Defense-in-depth: only act on registered (owned) worktrees.
[ "$(is_owned "$WT")" = true ] || { echo "refusing: $WT is not owned"; exit 1; }
[ -f "$TASK" ] || { echo "no task.md at $WT — refusing restart"; exit 1; }
[ -f "$WT/.claude/question.md" ] && { echo "question pending — not restarting"; exit 0; }

# A `stalled` worktree can now mean "hung", not just "exited": a live PID whose
# heartbeat went cold classifies as stalled. Reap it, or the respawn below would
# race a second claude against the first in the same worktree.
PID_FILE="$WT/.claude/session.pid"
if [ -f "$PID_FILE" ]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  case "$OLD_PID" in
    ''|*[!0-9]*) : ;;
    *)
      # Never signal a bare PID: the survey ran earlier, so the session may have exited
      # and the OS recycled its PID. (Matching the worktree path in argv fails — `ps`
      # truncates at 3072 bytes, past where `--add-dir` lands behind the ~4KB prompt.)
      if kill -0 "$OLD_PID" 2>/dev/null && pid_predates_file "$OLD_PID" "$PID_FILE"; then
        kill -TERM "$OLD_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5; do kill -0 "$OLD_PID" 2>/dev/null || break; sleep 1; done
        kill -KILL "$OLD_PID" 2>/dev/null || true
        echo "reaped hung session pid $OLD_PID at $WT"
      fi
      ;;
  esac
fi

# Drop the cold heartbeat, else a survey landing before the respawn's first tool call
# reads the dead session's timestamp and restarts the healthy one. Absent = not stale.
rm -f "$WT/.claude/status/HEARTBEAT.md"

CUR="$(awk '/## Restart count/{getline; print $1; exit}' "$TASK" 2>/dev/null || echo 0)"
NEW=$(( ${CUR:-0} + 1 ))
python3 - "$TASK" "$NEW" <<'PY'
import sys, re
task, new = sys.argv[1], sys.argv[2]
text = open(task).read()
text = re.sub(r'(## Restart count\n)\d+', rf'\g<1>{new}', text, count=1)
open(task, 'w').write(text)
PY

PROMPT="$(python3 - "$LIB_DIR" "$ISSUE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import spawn
print(spawn.restart_prompt(issue=sys.argv[2]))
PY
)"
CLAUDE="$(resolve_claude)"
cd "$WT"
nohup "$CLAUDE" -p "$PROMPT" --permission-mode acceptEdits --add-dir "$WT" \
  > "$WT/.claude/session.log" 2>&1 &
echo $! > "$WT/.claude/session.pid"
echo "restarted #$ISSUE → $WT (restart #$NEW, pid $(cat "$WT/.claude/session.pid"))"
