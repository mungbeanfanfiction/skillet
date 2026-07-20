#!/usr/bin/env bash
# Reap ONE claude process group by pgid — group-aware TERM→KILL of the whole `-pgid`, so
# the session, xdist workers, and MCP servers go down together with no orphans.
# Usage: reap-group.sh <pgid> [grace-seconds]
#
# Prefers reap_pid when the group's session.pid is on disk (it carries PID-reuse provenance
# guards); with no pidfile, falls back to a direct group TERM→KILL.
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

# Never reap our own tree — guard every ancestor pgid (see self-pgids.sh), not just ours.
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
  reap_pid "$PGID" "$PIDFILE" "$GRACE"
  echo "reaped group $PGID via reap_pid ($PIDFILE)"
  exit 0
fi

# Pidfile-less orphan: no provenance to validate, so guard the PID-reuse window by
# re-confirming the group still hosts a `claude` process (re-checked before the KILL too).
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
