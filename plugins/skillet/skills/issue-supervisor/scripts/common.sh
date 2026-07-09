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
# observed at ~6 min (explore) to ~50 min (implement), so 45 min covers the legit worst
# case with a tight blast radius. Operator-overridable for a heavy task; 0/empty disables.
export SKILLET_SESSION_TIMEOUT_SECONDS="${SKILLET_SESSION_TIMEOUT_SECONDS:-2700}"

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
# (the order — make ci → make agent-ci → npm test → pytest → documented check — is
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

  cap="${SKILLET_SESSION_TIMEOUT_SECONDS:-0}"
  case "$cap" in (''|0|*[!0-9]*) return ;; esac  # cap disabled/garbage → no timer
  local pidfile="$wt/.claude/session.pid"
  # Detached reaper. Re-reads the pidfile at fire time and confirms the live pid predates
  # it (PID-reuse guard, same check restart.sh uses) before signalling.
  (
    sleep "$cap"
    local cur; cur="$(cat "$pidfile" 2>/dev/null || true)"
    case "$cur" in (''|*[!0-9]*) exit 0 ;; esac
    [ "$cur" = "$pid" ] || exit 0                 # a respawn replaced us; not our job
    kill -0 "$cur" 2>/dev/null || exit 0          # already exited cleanly
    pid_predates_file "$cur" "$pidfile" || exit 0 # recycled pid — do not touch
    # Signal the process GROUP when we own one (pid == pgid via `set -m`), else the pid.
    if kill -0 -- "-$cur" 2>/dev/null; then
      kill -TERM -- "-$cur" 2>/dev/null || true
      sleep 30; kill -KILL -- "-$cur" 2>/dev/null || true
    else
      kill -TERM "$cur" 2>/dev/null || true
      sleep 30; kill -KILL "$cur" 2>/dev/null || true
    fi
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

mkdir -p "$STATE_DIR"
