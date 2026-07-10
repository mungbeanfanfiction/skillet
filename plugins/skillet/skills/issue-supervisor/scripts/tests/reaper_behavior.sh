#!/usr/bin/env bash
# Behavioral test for spawn_capped_session's wall-clock reaper.
# Proves: a session exceeding the cap is killed, AND its child (simulating claude's
# pytest/CI subprocess) dies with it. Uses a fake claude so no real session spawns.
set -uo pipefail

SKILL_SCRIPTS="$1"   # path to issue-supervisor/scripts
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- Fake claude: writes its own pid + a child sleep's pid, then hangs well past the cap.
# The child simulates a pytest/CI subprocess we need the reaper to also kill.
FAKE="$TMP/fake-claude"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
# ignore claude's real args; just spawn a child and hang
sleep 600 &
CHILD=$!
echo "$CHILD" > "$MARKER_CHILD"
echo "$$"      > "$MARKER_SELF"
wait
EOF
chmod +x "$FAKE"

WT="$TMP/wt"; mkdir -p "$WT/.claude"

# Source common.sh with our overrides. common.sh runs git/mkdir at load; give it a repo.
git -C "$TMP" init -q
export CLAUDE_BIN="$FAKE"
export SKILLET_SESSION_TIMEOUT_SECONDS=3     # tiny cap for the test
export MARKER_CHILD="$TMP/child.pid"
export MARKER_SELF="$TMP/self.pid"

cd "$TMP"
# shellcheck disable=SC1090
source "$SKILL_SCRIPTS/common.sh"

spawn_capped_session "$WT" "unused-prompt"
SESSION_PID="$(cat "$WT/.claude/session.pid")"
echo "spawned session pid=$SESSION_PID (cap=${SKILLET_SESSION_TIMEOUT_SECONDS}s)"

# Wait for the fake to record its child.
for _ in $(seq 1 20); do [ -s "$MARKER_CHILD" ] && break; sleep 0.2; done
CHILD_PID="$(cat "$MARKER_CHILD" 2>/dev/null || echo '')"
echo "session child (fake CI subprocess) pid=$CHILD_PID"

# Confirm both alive BEFORE the cap.
kill -0 "$SESSION_PID" 2>/dev/null && echo "PRE: session alive OK" || { echo "FAIL: session not alive pre-cap"; exit 1; }
[ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null && echo "PRE: child alive OK" || { echo "FAIL: child not alive pre-cap"; exit 1; }

# Wait past cap (3s) + SIGTERM + grace. Poll up to ~40s.
echo "waiting for reaper (cap 3s + up to 30s grace)…"
DEADLINE=45; killed_session=0; killed_child=0
for _ in $(seq 1 $((DEADLINE*2))); do
  kill -0 "$SESSION_PID" 2>/dev/null || killed_session=1
  { [ -z "$CHILD_PID" ] || ! kill -0 "$CHILD_PID" 2>/dev/null; } && killed_child=1
  [ "$killed_session" = 1 ] && [ "$killed_child" = 1 ] && break
  sleep 0.5
done

echo
if [ "$killed_session" = 1 ]; then echo "PASS: session reaped"; else echo "FAIL: session survived the cap"; fi
if [ "$killed_child" = 1 ];   then echo "PASS: child reaped (whole tree died)"; else echo "FAIL: child orphaned — process-group reap did not take the tree"; fi

# cleanup any stragglers
kill -KILL "$SESSION_PID" "$CHILD_PID" 2>/dev/null || true

[ "$killed_session" = 1 ] && [ "$killed_child" = 1 ]
