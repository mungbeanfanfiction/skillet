#!/usr/bin/env bash
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

export LC_ALL=C  # ps must print %cpu with a decimal point, not a locale comma

RUNAWAY_CPU="${SKILLET_RUNAWAY_CPU:-90}"
pid_cpu() { ps -o %cpu= -p "$1" 2>/dev/null | awk 'NR==1{gsub(/ /,"");print ($1==""?0:$1)}'; }

LOCK_TTL_HOURS="${LOCK_TTL_HOURS:-6}"
loop_alive() {
  local ttl_min=$(( LOCK_TTL_HOURS * 60 )) l
  for l in "$STATE_DIR/supervisor.lock" "$STATE_DIR/sweeper.lock"; do
    [ -d "$l" ] || continue
    [ -n "$(find "$l" -maxdepth 0 -mmin "-${ttl_min}" 2>/dev/null)" ] && return 0
  done
  return 1
}

SELF_PGIDS=" $(self_pgids | tr '\n' ' ') "
is_self_pgid() { case "$SELF_PGIDS" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

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

worktree_for_pgid() {
  local pgid="$1" i
  for i in "${!WT_PIDS[@]}"; do
    [ "${WT_PIDS[$i]}" = "$pgid" ] && { printf '%s' "${WT_PATHS[$i]}"; return; }
  done
}

STALE_HEARTBEAT_SECONDS="${SKILLET_STALE_HEARTBEAT_SECONDS:-900}"
heartbeat_age() {
  local hb="$1/.claude/status/HEARTBEAT.md" mtime now
  [ -f "$hb" ] || return 1
  mtime="$(file_mtime "$hb")" || return 1
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  echo $(( now - mtime ))
}

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

  for member in $(group_members "$pgid"); do
    cpu="$(pid_cpu "$member")"
    awk -v a="$cpu" -v b="$maxcpu" 'BEGIN{exit !(a>b)}' && maxcpu="$cpu"
  done

  is_self_pgid "$pgid" && is_self=true
  loop_alive && sup=true

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

if [ "${#SESSION_PGIDS[@]}" -eq 0 ]; then  # bash 3.2: "${arr[@]}" on empty array trips set -u
  echo '[]'
else
  {
    for pgid in "${SESSION_PGIDS[@]}"; do
      case "$pgid" in ''|*[!0-9]*) continue ;; esac
      emit_group "$pgid"
    done
  } | jq -sc '.'
fi
