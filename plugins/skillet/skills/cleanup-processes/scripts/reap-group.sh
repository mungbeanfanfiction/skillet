#!/usr/bin/env bash
# Reap ONE claude process group by pgid. Group-aware (TERM→KILL the whole `-pgid`) so
# the session, its xdist workers, and MCP servers go down together with no orphans.
# Usage: reap-group.sh <pgid> [grace-seconds]
#
# Prefers issue-supervisor's reap_pid when the group's session.pid file is on disk:
# that path carries the full PID-reuse provenance guards (start-time vs pidfile mtime).
# When there is no pidfile (a truly orphaned leftover with no worktree), fall back to a
# direct group TERM→KILL — there is no pidfile to validate against, but the caller only
# ever reaches this path for a group the survey already classified as a reap candidate,
# and we still refuse to signal our own tree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(cd "$HERE/../.." && pwd)"
COMMON="$SKILLS_DIR/issue-supervisor/scripts/common.sh"
[ -f "$COMMON" ] || { echo "cannot find issue-supervisor common.sh at $COMMON" >&2; exit 1; }
# shellcheck disable=SC1090
source "$COMMON"
# shellcheck disable=SC1090
source "$HERE/self-pgids.sh"

PGID="${1:-}"; GRACE="${2:-30}"
case "$PGID" in ''|*[!0-9]*) echo "usage: reap-group.sh <pgid> [grace]" >&2; exit 2 ;; esac

# Never reap our own process tree — the invoking `claude -p` session is an ancestor,
# so guard against EVERY ancestor pgid, not just our immediate group.
SELF_PGIDS=" $(self_pgids | tr '\n' ' ') "
case "$SELF_PGIDS" in *" $PGID "*) echo "refusing: $PGID is a self/ancestor group" >&2; exit 1 ;; esac

# Find this group's session.pid (the group leader's pid == pgid) among on-disk worktrees.
PIDFILE=""
if [ -d "$WORKTREES_DIR" ]; then
  for d in "$WORKTREES_DIR"/*/; do
    [ -d "$d" ] || continue           # no-match glob stays literal → skip
    pf="$d.claude/session.pid"
    [ -f "$pf" ] || continue
    p="$(tr -d ' \n' < "$pf" 2>/dev/null || true)"
    [ "$p" = "$PGID" ] && { PIDFILE="$pf"; break; }
  done
fi

if [ -n "$PIDFILE" ]; then
  reap_pid "$PGID" "$PIDFILE" "$GRACE"   # full provenance-guarded group reap
  echo "reaped group $PGID via reap_pid ($PIDFILE)"
  exit 0
fi

# Pidfile-less orphan: no pidfile to prove provenance, so guard the survey→reap PID-reuse
# window by re-confirming the GROUP still hosts a `claude` process (a recycled pgid would
# host unrelated commands, none named claude) — re-checked before the delayed KILL too.
# Only live-leader groups reach here (a dead-leader group has a pidfile → reap_pid above),
# so the live leader is the claude member we expect. Match is start-anchored like the
# survey; a spaced binary path is the sole miss.
export LC_ALL=C
group_has_claude() {
  local m
  for m in $(group_members "$1"); do
    ps -o command= -p "$m" 2>/dev/null | awk '{ exit !($0 ~ /^([^ ]*\/)?claude( |$)/) }' && return 0
  done
  return 1
}

group_has_claude "$PGID" || { echo "group $PGID no longer a claude session — refusing"; exit 0; }
kill -TERM -- "-$PGID" 2>/dev/null || true
i=0
while [ "$i" -lt "$GRACE" ]; do
  kill -0 -- "-$PGID" 2>/dev/null || { echo "reaped group $PGID (TERM)"; exit 0; }
  sleep 1; i=$((i+1))
done
group_has_claude "$PGID" || { echo "group $PGID no longer a claude session — not KILLing"; exit 0; }
kill -KILL -- "-$PGID" 2>/dev/null || true
echo "reaped group $PGID (KILL after ${GRACE}s grace)"
