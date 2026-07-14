#!/usr/bin/env bash
# Survey claude processes and classify each group as healthy/orphaned/stale/runaway,
# emitting one JSON object per process group. Nothing is killed here — survey only.
#
# Reuses issue-supervisor's common.sh so enumeration and reaping share the SAME
# portable primitives (ps -Ao pid=,pgid= + awk filter — never `ps -g`; group_members;
# the pid/group provenance helpers).
#
# Output: JSON array on stdout, each element:
#   { pid, pgid, class, reason, worktree, cpu, is_self, supervisor_alive }
# class ∈ healthy|orphaned|stale|runaway|self; worktree is the session's --add-dir
# path (null if not a dispatched session).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(cd "$HERE/../.." && pwd)"
COMMON="$SKILLS_DIR/issue-supervisor/scripts/common.sh"
[ -f "$COMMON" ] || { echo "cannot find issue-supervisor common.sh at $COMMON" >&2; exit 1; }
# shellcheck disable=SC1090
source "$COMMON"
# shellcheck disable=SC1090
source "$HERE/self-pgids.sh"

command -v jq >/dev/null || { echo "jq not installed" >&2; exit 1; }

# Force C locale so `ps` prints %cpu with a decimal POINT — a locale that uses a comma
# (`90,0`) would make awk's numeric CPU comparisons fall back to string compare.
export LC_ALL=C

# `ps -o %cpu=` is portable; a process pegging a core reads ~100+.
RUNAWAY_CPU="${SKILLET_RUNAWAY_CPU:-90}"
pid_cpu() { ps -o %cpu= -p "$1" 2>/dev/null | awk 'NR==1{gsub(/ /,"");print ($1==""?0:$1)}'; }

# A live supervisor/sweeper loop holds a FRESH lock dir (see lock.sh); a lock past
# LOCK_TTL_HOURS is a crashed holder's leftover, not a live owner. This is the single
# signal gating "healthy": a group is healthy only if a live loop could be managing it.
LOCK_TTL_HOURS="${LOCK_TTL_HOURS:-6}"
loop_alive() {
  local ttl_min=$(( LOCK_TTL_HOURS * 60 )) l
  for l in "$STATE_DIR/supervisor.lock" "$STATE_DIR/sweeper.lock"; do
    [ -d "$l" ] || continue
    [ -n "$(find "$l" -maxdepth 0 -mmin "-${ttl_min}" 2>/dev/null)" ] && return 0
  done
  return 1
}

# Every ancestor pgid — the invoking `claude -p` session's group is among them and
# must never be a reap candidate (see self-pgids.sh for why the whole chain).
SELF_PGIDS=" $(self_pgids | tr '\n' ' ') "
is_self_pgid() { case "$SELF_PGIDS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# session.pid contents → owning worktree path, for every on-disk worktree. Lets us
# attribute a bare pgid to its --add-dir dir and find that dir's HEARTBEAT.md.
declare -a WT_PIDS=() WT_PATHS=()
if [ -d "$WORKTREES_DIR" ]; then
  for d in "$WORKTREES_DIR"/*/; do
    [ -d "$d" ] || continue
    pf="$d.claude/session.pid"
    [ -f "$pf" ] || continue
    p="$(tr -d ' \n' < "$pf" 2>/dev/null || true)"
    case "$p" in ''|*[!0-9]*) continue ;; esac
    WT_PIDS+=("$p"); WT_PATHS+=("${d%/}")
  done
fi

# The session pid file names the group LEADER (pgid == pid, via set -m), so a member's
# pgid matches a recorded pid.
worktree_for_pgid() {
  local pgid="$1" i
  for i in "${!WT_PIDS[@]}"; do
    [ "${WT_PIDS[$i]}" = "$pgid" ] && { printf '%s' "${WT_PATHS[$i]}"; return; }
  done
}

# Mirrors state.is_stale: a missing heartbeat is NOT stale (returns 1 → unknown).
STALE_HEARTBEAT_SECONDS="${SKILLET_STALE_HEARTBEAT_SECONDS:-900}"
heartbeat_age() {
  local hb="$1/.claude/status/HEARTBEAT.md" mtime now
  [ -f "$hb" ] || return 1
  mtime="$(file_mtime "$hb")" || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  echo $(( now - mtime ))
}

# Candidate process GROUPS to classify (a session + its xdist/MCP children share one
# pgid). Two sources, unioned + deduped:
#   (a) live `claude -p` leaders. Command must START with `[<path>/]claude -p ` — claude
#       in argv[0] position, not matched anywhere in argv (a prompt can contain the
#       literal "…/claude -p"). A space in the binary path is the only miss; fails safe.
#   (b) session.pid pgids whose GROUP still has a live member — the dead-leader leak
#       (claude exited; its workers keep the pgid), invisible to (a).
leader_pgids="$(ps -Ao pgid=,command= 2>/dev/null \
  | awk '{ pgid=$1; sub(/^[ \t]*[0-9]+[ \t]+/,""); if ($0 ~ /^([^ ]*\/)?claude -p /) print pgid }')"

live_wt_pgids=""
for i in "${!WT_PIDS[@]}"; do
  p="${WT_PIDS[$i]}"
  [ -n "$(group_members "$p")" ] && live_wt_pgids="$live_wt_pgids$p"$'\n'
done

SESSION_PGIDS=()
while IFS= read -r pg; do
  [ -n "$pg" ] && SESSION_PGIDS+=("$pg")
done < <(printf '%s\n%s\n' "$leader_pgids" "$live_wt_pgids" | sort -un)

emit_group() {
  local pgid="$1"
  local wt cpu klass reason is_self=false sup=false hbage member maxcpu=0

  wt="$(worktree_for_pgid "$pgid")"

  # Hottest member across the group: a runaway worker pegs a core even when the
  # leader is idle, so classify on the group's max CPU, not the leader's.
  for member in $(group_members "$pgid"); do
    cpu="$(pid_cpu "$member")"
    awk -v a="$cpu" -v b="$maxcpu" 'BEGIN{exit !(a>b)}' && maxcpu="$cpu"
  done

  is_self_pgid "$pgid" && is_self=true
  loop_alive && sup=true

  # First match wins. runaway is checked before healthy so a pegged group owned by a
  # live supervisor still surfaces as a candidate.
  if [ "$is_self" = true ]; then
    klass="self"; reason="invoking session — never reaped"
  elif awk -v c="$maxcpu" -v t="$RUNAWAY_CPU" 'BEGIN{exit !(c>=t)}'; then
    klass="runaway"; reason="group CPU ${maxcpu}% ≥ ${RUNAWAY_CPU}%"
  elif [ -n "$wt" ] && hbage="$(heartbeat_age "$wt")"; then
    if [ "$hbage" -gt "$STALE_HEARTBEAT_SECONDS" ]; then
      klass="stale"; reason="heartbeat ${hbage}s old (> ${STALE_HEARTBEAT_SECONDS}s)"
    elif [ "$sup" = true ]; then
      klass="healthy"; reason="fresh heartbeat, live supervisor"
    else
      klass="orphaned"; reason="fresh heartbeat but no live supervisor"
    fi
  elif [ "$sup" = true ] && [ -n "$wt" ]; then
    klass="healthy"; reason="registered worktree, live supervisor"
  else
    klass="orphaned"
    if [ -z "$wt" ]; then reason="no owning worktree (reparented leftover)"
    else reason="no live supervisor owns this session"; fi
  fi

  jq -nc \
    --argjson pid "$pgid" \
    --argjson pgid "$pgid" \
    --arg class "$klass" \
    --arg reason "$reason" \
    --arg wt "${wt:-}" \
    --arg cpu "$maxcpu" \
    --argjson is_self "$is_self" \
    --argjson sup "$sup" \
    '{pid:$pid, pgid:$pgid, class:$class, reason:$reason,
      worktree:(if $wt=="" then null else $wt end),
      cpu:($cpu|tonumber), is_self:$is_self, supervisor_alive:$sup}'
}

# Guard the values-expansion: on macOS's stock bash 3.2, `"${arr[@]}"` on an EMPTY
# array trips `set -u` ("unbound variable"), which pipefail would turn into a nonzero
# exit on the common "nothing to clean up" path. An empty set → emit `[]` and stop.
if [ "${#SESSION_PGIDS[@]}" -eq 0 ]; then
  echo '[]'
else
  {
    for pgid in "${SESSION_PGIDS[@]}"; do
      case "$pgid" in ''|*[!0-9]*) continue ;; esac
      emit_group "$pgid"
    done
  } | jq -sc '.'
fi
