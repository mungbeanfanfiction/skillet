#!/usr/bin/env bash
# self_pgids: print the process-group id of every ancestor of the current process,
# one per line, deduped. Source this; do not execute.
#
# Why the whole ancestor chain, not just our own pgid: Claude Code runs each Bash
# tool call in its OWN process group (a fresh zsh -c), so `$$`'s pgid does NOT match
# the invoking `claude -p` session's pgid — that session is an ANCESTOR several hops
# up. Reaping by pgid would then kill the very session that launched this skill. By
# collecting every ancestor's pgid we guarantee the invoking session's group is always
# recognized as self and excluded from reaping.
self_pgids() {
  local pid="$$" seen=" " line ppid pgid guard=0
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$guard" -lt 64 ]; do
    line="$(ps -o ppid=,pgid= -p "$pid" 2>/dev/null)" || break
    [ -n "$line" ] || break
    ppid="$(echo "$line" | awk '{print $1}')"
    pgid="$(echo "$line" | awk '{print $2}')"
    case "$pgid" in
      ''|*[!0-9]*) : ;;
      *) case "$seen" in *" $pgid "*) : ;; *) echo "$pgid"; seen="$seen$pgid " ;; esac ;;
    esac
    pid="$ppid"
    guard=$((guard + 1))
  done
}
