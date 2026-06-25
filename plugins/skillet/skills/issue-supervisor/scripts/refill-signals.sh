#!/usr/bin/env bash
# Event-driven refill: consume pending completion sentinels and emit a fresh
# survey so the supervisor can refill freed slots NOW, between ~5h polls.
#
# Concurrency contract: this acquires `supervisor.lock` just like the periodic
# cycle. If a cycle (or another refill) holds it, this prints {"skipped":"busy"}
# and exits 0 — the running cycle is the backstop. On success the lock is left
# HELD and the survey JSON is printed with `pending_signals`/`signals_seen` added.
# Ownership of the held lock then passes to the caller (SKILL.md §6), which must
# release it via `lock.sh release` after refilling. Consumed sentinels are cleared
# here so a re-trigger won't redo the same slot.
#
# A sentinel is only a hint to look now — `pending_signals` is informational; the
# refill decision is driven entirely by the survey's `free_slots`, exactly as the
# periodic cycle. So a stale/spurious sentinel costs one survey, never a misfire.
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS_DIR/common.sh"
require_tools

# No pending signals → nothing to do, and don't disturb the lock.
SEEN="$(python3 - "$LIB_DIR" "$STATE_DIR" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import signals
print(len(signals.pending(sys.argv[2])))
PY
)"
if [ "$SEEN" = "0" ]; then
  echo '{"skipped": "no_signals"}'; exit 0
fi

# Respect the lock — back off if a cycle is already running.
if [ "$(bash "$SCRIPTS_DIR/lock.sh" acquire)" != "acquired" ]; then
  echo '{"skipped": "busy"}'; exit 0
fi

# From here a failure must release the lock, or it would wedge the loop until the
# 6h stale-reclaim. Release on any unexpected error before re-raising.
trap 'bash "$SCRIPTS_DIR/lock.sh" release' ERR

SURVEY="$(bash "$SCRIPTS_DIR/survey.sh")"
# A surveying error means we cannot safely act — release the lock and surface it.
if echo "$SURVEY" | jq -e 'has("error")' >/dev/null 2>&1; then
  bash "$SCRIPTS_DIR/lock.sh" release
  echo "$SURVEY"; exit 0
fi

# Clear the consumed sentinels before the caller dispatches. Dispatch only adds
# work, so clearing first cannot drop a still-needed slot, and it stops a crash
# mid-dispatch from re-triggering the slot we just filled.
PENDING="$(python3 - "$LIB_DIR" "$STATE_DIR" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import signals
state_dir = sys.argv[2]
pend = signals.pending(state_dir)
signals.clear(state_dir)
print(json.dumps(pend))
PY
)"

# Emit survey + signal context for the skill's refill step. Lock stays HELD.
echo "$SURVEY" | jq --argjson p "$PENDING" \
  '. + {pending_signals: $p, signals_seen: ($p | length)}'
