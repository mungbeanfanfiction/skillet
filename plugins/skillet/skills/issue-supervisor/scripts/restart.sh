#!/usr/bin/env bash
# Restart a stalled OWNED worktree: assert ownership, increment restart count,
# respawn detached. Refuses if a question is pending. Usage: restart.sh <wt> <issue>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WT="$1"; ISSUE="$2"; TASK="$WT/.claude/task.md"

# Defense-in-depth: only act on registered (owned) worktrees.
owned="$(py "from supervisorlib import registry; print('true' if registry.is_owned('$REGISTRY','$WT') else 'false')")"
[ "$owned" = true ] || { echo "refusing: $WT is not owned"; exit 1; }
[ -f "$TASK" ] || { echo "no task.md at $WT — refusing restart"; exit 1; }
[ -f "$WT/.claude/question.md" ] && { echo "question pending — not restarting"; exit 0; }

CUR="$(awk '/## Restart count/{getline; print $1; exit}' "$TASK" 2>/dev/null || echo 0)"
NEW=$(( ${CUR:-0} + 1 ))
python3 - "$TASK" "$NEW" <<'PY'
import sys, re
task, new = sys.argv[1], sys.argv[2]
text = open(task).read()
text = re.sub(r'(## Restart count\n)\d+', rf'\g<1>{new}', text, count=1)
open(task, 'w').write(text)
PY

PROMPT="$(py "from supervisorlib import spawn; print(spawn.restart_prompt(issue='$ISSUE'))")"
CLAUDE="$(resolve_claude)"
cd "$WT"
nohup "$CLAUDE" -p "$PROMPT" --permission-mode acceptEdits --add-dir "$WT" \
  > "$WT/.claude/session.log" 2>&1 &
echo $! > "$WT/.claude/session.pid"
echo "restarted #$ISSUE → $WT (restart #$NEW, pid $(cat "$WT/.claude/session.pid"))"
