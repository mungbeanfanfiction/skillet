#!/usr/bin/env bash
# Skillet heartbeat hook (writer). PostToolUse + SessionEnd; linked worktrees only.
#
# Overwrites .claude/status/HEARTBEAT.md so its mtime proves the session did
# something recently — `kill -0` says a PID exists, not that it is progressing, so a
# hung session is otherwise invisible. The body records the last tool + pipeline
# stage, which survive a hard kill because the hook, not the agent, writes them: a
# dying agent cannot be relied on to narrate its own death. Always exits 0.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/status-common.sh"

command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)"
[ -n "$input" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || exit 0
[ -d "$cwd" ] || exit 0

git_dir="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
toplevel="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
common_dir="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || exit 0

# Linked worktrees only: their git dir lives under <common>/worktrees/<name>. The
# main checkout's does not, and no dispatched work runs there.
case "$git_dir" in
  */worktrees/*) : ;;
  *) exit 0 ;;
esac

status_self_exclude "$common_dir"

event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"

# The pipeline stage the session last logged to task.md — the coarse "where was it"
# that pairs with the fine-grained tool name.
stage=""
task="$toplevel/.claude/task.md"
[ -f "$task" ] && stage="$(awk '/^## Pipeline stage/{getline; print $1; exit}' "$task" 2>/dev/null)"

# SessionEnd carries the reason the session stopped (`clear`, `logout`, `other`, …).
# Absent on PostToolUse, which is the point: a HEARTBEAT.md with no exit reason and
# a stale timestamp means the session died without ever reaching SessionEnd.
exit_reason="$(printf '%s' "$input" | jq -r '.reason // empty' 2>/dev/null)"

status_dir="$toplevel/.claude/status"
mkdir -p "$status_dir" || exit 0
{
  echo "# heartbeat"
  echo
  echo "- updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- event: ${event:-unknown}"
  echo "- last step: ${tool:-none} (stage: ${stage:-unknown})"
  [ -n "$exit_reason" ] && echo "- exit reason: $exit_reason"
} >"$status_dir/HEARTBEAT.md" 2>/dev/null

exit 0
