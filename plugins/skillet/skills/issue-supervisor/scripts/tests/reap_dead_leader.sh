#!/usr/bin/env bash
# Regression test for the "dead leader, live children" gap (review finding #3).
# A common runaway is: claude (the group leader) exits, but its pytest-xdist workers
# keep burning CPU in the same process group. reap_pid must still sweep the group by
# signalling `-$pid` even though the leader pid is dead — NOT bail on a leader liveness
# check. Proves reap_pid kills a surviving group member after the leader has exited.
set -uo pipefail

SKILL_SCRIPTS="$1"   # path to issue-supervisor/scripts
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q
cd "$TMP"
# shellcheck disable=SC1090
source "$SKILL_SCRIPTS/common.sh"

PIDFILE="$TMP/session.pid"
CHILD_MARK="$TMP/child.pid"

# Launch a group leader (own group via set -m) that spawns a long-lived child, records
# both, writes the leader pid to the pidfile, then EXITS immediately — leaving the child
# alive in the leader's process group (the dead-leader-live-children scenario).
set -m
bash -c '
  sleep 600 &
  echo $! > "'"$CHILD_MARK"'"
  echo $$ > "'"$PIDFILE"'"
  # leader exits right away; child keeps running in this group
' &
LEADER=$!
set +m

# Wait for the child to be recorded and the leader to have exited.
for _ in $(seq 1 25); do [ -s "$CHILD_MARK" ] && ! kill -0 "$LEADER" 2>/dev/null && break; sleep 0.2; done
CHILD="$(cat "$CHILD_MARK" 2>/dev/null || echo '')"

echo "leader pid=$LEADER (expected dead), child pid=$CHILD (expected alive)"
kill -0 "$LEADER" 2>/dev/null && { echo "SKIP: leader still alive, test setup race"; exit 0; }
[ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null || { echo "SKIP: child not alive, test setup race"; exit 0; }
echo "PRE: leader dead, child alive in the group — the exact runaway shape"

# reap_pid must sweep the group and kill the surviving child despite the dead leader.
reap_pid "$LEADER" "$PIDFILE"

killed=0
for _ in $(seq 1 10); do kill -0 "$CHILD" 2>/dev/null || { killed=1; break; }; sleep 0.5; done
echo
if [ "$killed" = 1 ]; then echo "PASS: surviving child reaped via group kill after leader death"; else echo "FAIL: child survived — reap_pid bailed on the dead leader"; fi
kill -KILL "$CHILD" 2>/dev/null || true
[ "$killed" = 1 ]
