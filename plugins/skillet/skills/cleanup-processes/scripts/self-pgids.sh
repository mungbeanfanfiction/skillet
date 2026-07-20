#!/usr/bin/env bash
# self_pgids: print the pgid of every ancestor of the current process, deduped. Source; don't execute.
#
# The whole ancestor chain, not just `$$`'s pgid: Claude Code runs each Bash call in its
# own group, so the invoking `claude -p` session is an ancestor group several hops up.
# Reaping by pgid without excluding all of them would kill the session running this skill.
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
