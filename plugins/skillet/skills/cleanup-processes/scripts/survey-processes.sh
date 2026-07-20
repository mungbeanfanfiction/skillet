#!/usr/bin/env bash
# Survey claude processes, classifying each group as healthy/orphaned/stale/runaway/self.
# Survey only — nothing is killed here. Reuses issue-supervisor's common.sh for portable
# primitives. Output: JSON array, one object per group:
#   { pid, pgid, class, reason, worktree, cpu, is_self, supervisor_alive }
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

# C locale so ps prints %cpu with a decimal POINT — a comma (`90,0`) breaks awk's numeric compare.
export LC_ALL=C

RUNAWAY_CPU="${SKILLET_RUNAWAY_CPU:-90}"
pid_cpu() { ps -o %cpu= -p "$1" 2>/dev/null | awk 'NR==1{gsub(/ /,"");print ($1==""?0:$1)}'; }

# A live supervisor/sweeper holds a FRESH lock dir; one past LOCK_TTL_HOURS is a crashed
# leftover. This is the sole signal gating "healthy".
LOCK_TTL_HOURS="${LOCK_TTL_HOURS:-6}"
loop_alive() {
  local ttl_min=$(( LOCK_TTL_HOURS * 60 )) l
  for l in "$STATE_DIR/supervisor.lock" "$STATE_DIR/sweeper.lock"; do
    [ -d "$l" ] || continue
    [ -n "$(find "$l" -maxdepth 0 -mmin "-${ttl_min}" 2>/dev/null)" ] && return 0
  done
  return 1
}

# Ancestor pgids never get reaped (see self-pgids.sh).
SELF_PGIDS=" $(self_pgids | tr '\n' ' ') "
is_self_pgid() { case "$SELF_PGIDS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# session.pid contents → owning worktree path, to attribute a pgid to its dir and heartbeat.
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

# session.pid names the group LEADER (pgid == pid), so a member's pgid matches a recorded pid.
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

# Candidate GROUPS, two sources unioned + deduped:
#   (a) live `claude -p` leaders — command must START with `[<path>/]claude -p ` (argv[0]
#       position, not anywhere in argv, since a prompt can contain that literal).
#   (b) session.pid pgids whose group still has a live member — the dead-leader leak
#       (claude exited, workers keep the pgid), invisible to (a).
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

  # Classify on the group's max CPU: a runaway worker pegs a core while the leader is idle.
  for member in $(group_members "$pgid"); do
    cpu="$(pid_cpu "$member")"
    awk -v a="$cpu" -v b="$maxcpu" 'BEGIN{exit !(a>b)}' && maxcpu="$cpu"
  done

  is_self_pgid "$pgid" && is_self=true
  loop_alive && sup=true

  # First match wins; runaway before healthy so a pegged group under a live supervisor
  # still surfaces as a candidate.
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

# On bash 3.2, `"${arr[@]}"` on an EMPTY array trips `set -u`; guard the empty case → `[]`.
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
