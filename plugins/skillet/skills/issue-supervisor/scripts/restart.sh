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
  # reap_pid signals the whole process GROUP (not just the bare pid), so the hung session's
  # CI child + xdist workers die with it — killing only OLD_PID would orphan exactly the
  # runaway children this reap exists to stop. It also guards against PID reuse (the survey
  # ran earlier, so OLD_PID may have exited and the OS recycled it) via pid_predates_file,
  # and no-ops on a non-numeric/dead/recycled pid. Shared with spawn_capped_session's
  # wall-clock reaper so the two reap paths stay identical.
  # Only log a reap when something was actually alive to kill — reap_pid always returns 0
  # (even for a dead/recycled/empty pid), so gating the message on its exit status would
  # print "reaped" on every ordinary exited-session restart. Check liveness up front instead.
  WAS_ALIVE=false
  case "$OLD_PID" in
    ''|*[!0-9]*) : ;;
    *) if kill -0 -- "-$OLD_PID" 2>/dev/null || kill -0 "$OLD_PID" 2>/dev/null; then WAS_ALIVE=true; fi ;;
  esac
  # Short grace: restart.sh runs SYNCHRONOUSLY on the survey's critical path, so a 5s
  # TERM→KILL window (matching the old reap) avoids stalling the cycle up to 30s per hung
  # worktree. The detached wall-clock reaper keeps the longer default grace.
  reap_pid "$OLD_PID" "$PID_FILE" 5
  [ "$WAS_ALIVE" = true ] && echo "reaped hung session pid $OLD_PID at $WT"
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
cd "$WT"
spawn_capped_session "$WT" "$PROMPT"   # detached, under the per-session wall-clock cap
echo "restarted #$ISSUE → $WT (restart #$NEW, pid $(cat "$WT/.claude/session.pid"))"
