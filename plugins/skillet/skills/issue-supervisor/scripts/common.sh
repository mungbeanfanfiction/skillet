#!/usr/bin/env bash
# Shared helpers for supervisor scripts. Source this; do not execute.
# Resolves repo-agnostic context (REPO, BASE), runtime-state dir, and lib dir.
set -euo pipefail

# Resolve relative to THIS file so it works regardless of where the plugin is
# installed (callers live in scripts/, the lib is one dir up).
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$COMMON_DIR/.." && pwd)"
LIB_DIR="$SKILL_DIR/lib"

# This block is the single source of truth for runtime-state locations (registry,
# locks, dispatched worktrees). The shell owns these because every consumer is a
# script that needs them as bash vars; there is intentionally no paths.py.
#
# Anchor to the MAIN worktree, never the current one. `--show-toplevel` returns
# whatever worktree the loop happens to run from, which would (a) nest dispatched
# worktrees and (b) — worse — put runtime state (registry/locks) under a different
# path per cwd, so the supervisor would lose track of worktrees it owns. The main
# checkout is the parent of the shared .git common dir, stable from any worktree.
REPO_ROOT="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd)"
STATE_DIR="$REPO_ROOT/.claude/issue-supervisor"
REGISTRY="$STATE_DIR/registry.json"
WORKTREES_DIR="$REPO_ROOT/.claude/worktrees"
# Loop concurrency locks live alongside the registry: $STATE_DIR/{supervisor,sweeper}.lock

# Cap pytest-xdist parallelism for every dispatched session. A repo's CI often runs
# `pytest -n auto`, which spawns one worker PER CORE — fine for a single run that owns
# the machine, ruinous when N concurrent sessions each do it (N × cores processes on
# `cores` cores → the load-40-on-8-cores storm). xdist reads this env var in place of
# the core count when resolving `-n auto`, so exporting it here (sourced by dispatch/
# restart/resume before their `nohup claude` spawn) makes every session — and its CI
# child — inherit the cap. Respects an explicit operator override.
export PYTEST_XDIST_AUTO_NUM_WORKERS="${PYTEST_XDIST_AUTO_NUM_WORKERS:-3}"

# Hard wall-clock ceiling for ONE dispatched session spawn (seconds). The supervisor's
# heartbeat-based stall reap (state.is_stale + restart.sh) only fires DURING a survey
# cycle — once the supervisor exits, a detached `nohup claude -p` session that hangs or
# runs away has nothing watching it. This cap kills the run independently of the
# supervisor: even if it (and everything else) is gone, a detached bash timer reaps the
# session. It bounds a single spawn (RESTART_CAP already bounds respawns); real runs were
# observed at ~6 min (explore) to ~50 min (implement), so 60 min sits comfortably above the
# legit worst case while still bounding a runaway far tighter than the old effectively-
# unbounded behavior. Operator-overridable for a heavier task; `0` or empty disables it.
# `-` not `:-`: an explicitly-empty override (`SKILLET_SESSION_TIMEOUT_SECONDS=`) must
# survive to the disable branch, not be silently reset to the default.
export SKILLET_SESSION_TIMEOUT_SECONDS="${SKILLET_SESSION_TIMEOUT_SECONDS-3600}"

fail() { printf '{"error": %s}\n' "$(jq -Rn --arg m "$1" '$m')"; exit 1; }

require_tools() {
  command -v gh >/dev/null || fail "gh not installed"
  command -v jq >/dev/null || fail "jq not installed"
  command -v git >/dev/null || fail "git not installed"
}

# Repo-agnostic identifiers (no hard-coded owner/name/branch).
detect_repo() { gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || fail "gh repo view failed"; }
detect_base() { gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main"; }

# NOTE: the repo's CI command is detected by the dispatched SESSION at runtime
# (the order — make agent-ci → make ci → npm test → pytest → documented check — is
# in spawn.PIPELINE), not here, so there is no detect_ci_cmd() helper. Add one
# only if a script ever needs to run CI directly.

py() { python3 -c "import sys; sys.path.insert(0,'$LIB_DIR'); $1"; }

# Ownership check for a worktree path. The path is passed as argv (NOT
# interpolated into a Python literal), so a quote in the path — possible when the
# user's checkout lives under e.g. /Users/o'brien — cannot break or inject.
# Prints "true" / "false".
is_owned() {
  python3 - "$LIB_DIR" "$REGISTRY" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import registry
print("true" if registry.is_owned(sys.argv[2], sys.argv[3]) else "false")
PY
}

# Resolve the claude executable for detached (nohup) spawns. `claude` is often a
# shell ALIAS (e.g. -> ~/.claude/local/claude), which does NOT survive into the
# non-interactive subshell nohup runs, so we cannot rely on bare `claude`.
# Order: explicit $CLAUDE_BIN override → PATH lookup → the standard local install.
resolve_claude() {
  if [ -n "${CLAUDE_BIN:-}" ] && [ -x "$CLAUDE_BIN" ]; then echo "$CLAUDE_BIN"; return; fi
  local p; p="$(command -v claude 2>/dev/null || true)"
  if [ -n "$p" ]; then echo "$p"; return; fi
  if [ -x "$HOME/.claude/local/claude" ]; then echo "$HOME/.claude/local/claude"; return; fi
  fail "claude executable not found (set CLAUDE_BIN or install the CLI)"
}

# Spawn a dispatched session DETACHED, under a pure-bash wall-clock cap, from $PWD
# (callers cd into the worktree first). Usage: spawn_capped_session <wt> <prompt>.
# Writes the session pid to <wt>/.claude/session.pid and logs to session.log, exactly as
# the previous inline `nohup … &` did — so restart.sh's pid-based reap is unchanged.
#
# The cap is a SECOND detached process (a sleep-then-kill timer), not `timeout(1)`:
# macOS ships no `timeout`, and the whole point of this ceiling is to hold when nothing
# else is alive — depending on an optional binary would reintroduce the very gap it
# closes. The timer runs in a backgrounded subshell that is disowned so it outlives this
# script, sleeps the cap, then SIGTERMs the session's process GROUP (kill -TERM -PGID) to
# take the whole tree — claude, its CI child, xdist workers — followed by SIGKILL after a
# 30s grace. It guards on pid_predates_file so a recycled pid is never signalled. A
# session that finishes early leaves a harmless timer that finds the pid gone and no-ops.
spawn_capped_session() {
  local wt="$1" prompt="$2" claude pid cap
  claude="$(resolve_claude)"
  # Give the session its OWN process group (pgid == its pid) so the reaper can signal the
  # whole tree — claude, its CI child, xdist workers — by group, not just the bare pid
  # (which would orphan the children, the exact leak this cap exists to stop). `setsid`
  # would do this but is absent on macOS; enabling bash job control (`set -m`) makes the
  # next backgrounded job a group leader instead, and works everywhere bash does. Scoped
  # to this function so we don't flip job control for the whole sourcing script.
  local had_m=1; [[ $- == *m* ]] || had_m=0
  set -m
  nohup "$claude" -p "$prompt" --permission-mode acceptEdits --add-dir "$wt" \
    > "$wt/.claude/session.log" 2>&1 &
  pid=$!
  [ "$had_m" = 1 ] || set +m
  echo "$pid" > "$wt/.claude/session.pid"

  # The export above already resolved default-vs-override (and preserved an empty override),
  # so just read it. Empty / 0 / non-numeric → no timer (cap disabled).
  cap="${SKILLET_SESSION_TIMEOUT_SECONDS:-}"
  case "$cap" in (''|0|*[!0-9]*) return ;; esac
  local pidfile="$wt/.claude/session.pid"
  # Detached reaper. Polls in short intervals up to the cap rather than one blind full-cap
  # sleep, so a session that finishes early (most do — explore runs ~6 min vs a 60-min cap)
  # frees this timer within ~15s instead of leaving an hour-long sleep parked.
  # It exits the instant the session is gone or a respawn overwrote the pidfile (not our
  # job); only a session that outlives the whole cap gets reaped. reap_pid does the group
  # kill + reuse guards, shared with restart.sh so the two reap paths can never drift.
  (
    local waited=0 step=15 cur
    while [ "$waited" -lt "$cap" ]; do
      [ $((cap - waited)) -lt "$step" ] && step=$((cap - waited))
      sleep "$step"; waited=$((waited + step))
      read -r cur < "$pidfile" 2>/dev/null || cur=       # `read` builtin, no per-tick fork
      [ "$cur" = "$pid" ] || exit 0               # respawn overwrote the pidfile → not our job
      # Exit early only when the whole TREE is gone (leader AND any xdist children). Checking
      # the group, not the bare leader pid, is deliberate: claude can exit while a runaway
      # worker keeps burning CPU in the group — that must still hit the cap, not slip out here.
      kill -0 -- "-$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null || exit 0
    done
    # Reap only if the pidfile STILL names us — a respawn racing the cap boundary must not be
    # reaped (reap_pid's own provenance guard also covers this; this is the cheap belt).
    read -r cur < "$pidfile" 2>/dev/null || cur=
    [ "$cur" = "$pid" ] && reap_pid "$pid" "$pidfile"   # outlived the cap → reap the tree
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# Epoch mtime of $1. GNU form FIRST: GNU `stat -f` means "filesystem status" and
# prints an info block to STDOUT before exiting 1, so a BSD-first chain would have `||`
# append the real mtime to that garbage. BSD `stat -c` fails cleanly, so only this
# order works on both. Same idea below: BSD `date -j` fails cleanly on GNU.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

pid_started() {
  local raw
  raw="$(ps -o lstart= -p "$1" 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 1
  date -j -f '%a %b %e %T %Y' "$raw" +%s 2>/dev/null || date -d "$raw" +%s 2>/dev/null
}

# True when live pid $1 started no later than $2's mtime, i.e. it plausibly wrote that
# file. Guards `kill` against PID reuse: a recycled PID necessarily started AFTER the
# pid file was written. Fails closed on any unreadable timestamp.
pid_predates_file() {
  local started mtime
  started="$(pid_started "$1")" || return 1
  mtime="$(file_mtime "$2")" || return 1
  case "$started$mtime" in (*[!0-9]*|'') return 1 ;; esac
  [ -n "$started" ] && [ "$started" -le "$mtime" ]
}

# Live PIDs whose process GROUP id == $1, one per line. Post-filters `ps -Ao pid=,pgid=`
# on the pgid column rather than using `ps -g`: on macOS/BSD `-g` selects by process group,
# but on Linux/procps `-g` selects by SESSION id — and since sessions get `set -m` (new
# group) not `setsid` (new session), pgid != sid there, so `ps -g $pgid` would return the
# wrong (usually empty) set and the dead-leader reap would silently no-op on Linux. The
# column filter means the same thing on both.
group_members() { ps -Ao pid=,pgid= 2>/dev/null | awk -v g="$1" '$2==g{print $1}'; }

# True when process group $1 has at least one live member that started no later than $2's
# mtime. The group-level analogue of pid_predates_file, and the key to reaping a
# dead-leader-live-children tree: once the leader (claude) exits, pid_predates_file can't
# validate it (ps can't read a dead pid's start time), but the group's surviving xdist
# workers still carry the original pgid. A member predating the pidfile proves the group is
# NOT a recycled pgid (whose members would all have started AFTER the file was written), so
# the FIRST such member is sufficient — no need to scan for the oldest. Fails closed
# (returns 1) if the group is empty or no member predates, so we never signal a recycled pgid.
group_predates_file() {
  local pgid="$1" pidfile="$2" mtime p started
  mtime="$(file_mtime "$pidfile")" || return 1
  case "$mtime" in (''|*[!0-9]*) return 1 ;; esac
  for p in $(group_members "$pgid"); do
    started="$(pid_started "$p")" || continue
    case "$started" in (''|*[!0-9]*) continue ;; esac
    [ "$started" -le "$mtime" ] && return 0    # one predating member proves the group is ours
  done
  return 1
}

# Reap the process TREE of a dispatched session: pid $1, the pidfile $2 it was read from,
# and an optional TERM→KILL grace in seconds $3 (default 30). Sessions are spawned as
# process-group leaders (pgid == pid, via `set -m` in spawn_capped_session), so signalling
# the GROUP `-$pid` takes claude AND its CI child + xdist workers — killing only the bare
# pid orphans those children, the exact leak this exists to stop. Both the wall-clock reaper
# and restart.sh's stall-reap call this, so the two reap paths can never drift; restart.sh
# passes a short grace because it runs SYNCHRONOUSLY on the survey's critical path.
#
# Safety: never signals an unrelated (recycled) pid/pgid — validates provenance by START
# TIME (a recycled pid/group started AFTER the pidfile was written). It does NOT require the
# leader to be alive (dead-leader-live-children); when the leader is gone, group_predates_file
# validates a surviving group member instead. Provenance is re-checked before the delayed
# SIGKILL (the grace is a reuse window). Best-effort: every kill is `|| true`.
reap_pid() {
  local pid="$1" pidfile="$2" grace="${3:-30}" i target grouped=
  case "$pid" in (''|*[!0-9]*) return 0 ;; esac

  # One escalation, two possible targets. Prefer the whole GROUP (`-$pid`) when it's live
  # and ours (provenance may come from a surviving member if the leader already exited);
  # else fall back to the bare pid for a legacy pre-`set -m` session, whose provenance is
  # the LIVE leader only. `grouped` records which so the pre-KILL recheck re-runs the SAME
  # predicate the target was chosen with — a group-inclusive recheck on a bare target could
  # pass on an unrelated recycled pgid, defeating the reuse guard.
  if kill -0 -- "-$pid" 2>/dev/null && _group_provenance_ok "$pid" "$pidfile"; then
    target="-$pid"; grouped=1                         # signal the process group
  elif kill -0 "$pid" 2>/dev/null && pid_predates_file "$pid" "$pidfile"; then
    target="$pid"                                     # legacy: bare-pid, live leader only
  else
    return 0                                          # nothing ours to reap
  fi

  kill -TERM -- "$target" 2>/dev/null || true
  # Numeric while-loop, not a seq expansion: seq counting 1..0 emits "1 0" (2 iterations),
  # so a caller passing grace=0 (meaning immediate KILL, no wait) would get a 2s grace.
  i=0; while [ "$i" -lt "$grace" ]; do kill -0 -- "$target" 2>/dev/null || return 0; sleep 1; i=$((i+1)); done
  # Re-validate before the delayed KILL — the grace is a reuse window — with the SAME
  # predicate as entry: group provenance for a group target, pid-only for a bare target.
  if [ -n "$grouped" ]; then _group_provenance_ok "$pid" "$pidfile" || return 0
  else pid_predates_file "$pid" "$pidfile" || return 0; fi
  kill -KILL -- "$target" 2>/dev/null || true
}

# Group-target provenance for reap_pid: the (possibly dead) leader pid predates the pidfile,
# OR a surviving group member does. Either proves this GROUP is the original session's.
_group_provenance_ok() { pid_predates_file "$1" "$2" || group_predates_file "$1" "$2"; }

mkdir -p "$STATE_DIR"
