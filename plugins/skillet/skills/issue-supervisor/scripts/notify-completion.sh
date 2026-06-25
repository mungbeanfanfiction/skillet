#!/usr/bin/env bash
# Drop a completion sentinel so the supervisor refills this worktree's freed slot
# promptly instead of waiting for the next ~5h poll. A finishing dispatched
# session calls this at the very end of its pipeline (after marking the stage
# `done` / opening its draft PR).
#
# Best-effort by construction: signalling completion must NEVER fail the session
# that is finishing. `_notify` runs `set -euo pipefail` so any failing stage
# aborts it (no false "signalled" on a half-done run), and this wrapper always
# exits 0, so the guarantee does not depend on callers remembering `|| true`
# (they still pass it, as defence in depth).
# Usage: notify-completion.sh [<worktree-path>]   (defaults to the current worktree)

_notify() {
  set -euo pipefail
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

  # Default to the worktree we're running in. `--show-toplevel` is correct HERE
  # (unlike common.sh's state anchoring) because we want THIS session's worktree.
  local wt; wt="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  wt="$(cd "$wt" && pwd)"

  # Only signal for worktrees the supervisor owns. A foreign worktree finishing is
  # not the supervisor's slot to refill, and we never act on un-owned worktrees.
  if [ "$(is_owned "$wt")" != true ]; then
    echo "skip: $wt is not an owned worktree — no completion signal"; return 0
  fi

  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Issue derived from the registry (argv, never interpolated into a literal).
  python3 - "$LIB_DIR" "$REGISTRY" "$STATE_DIR" "$wt" "$now" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import registry, signals
reg, state_dir, wt, now = sys.argv[2:6]
issue = registry.issue_for_path(reg, wt)
signals.write(state_dir, path=wt, issue=issue, created_at=now)
PY
  echo "signalled completion for $wt"
}

# Run as a standalone subshell statement so `set -e` stays active INSIDE it (it is
# disabled in a subshell used as the left operand of `||`/`&&`), then read its
# status. Either way we exit 0 — signalling must never break the caller.
( _notify "$@" )
rc=$?
[ "$rc" -eq 0 ] || echo "notify-completion: skipped (best-effort, non-fatal)" >&2
exit 0
