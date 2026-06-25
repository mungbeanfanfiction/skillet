#!/usr/bin/env bash
# Shared supervisor-lock helper. The periodic ~5h cycle and the event-driven
# refill (refill-signals.sh) both go through here so they cannot race: whoever
# holds the lock runs; the other backs off. Source for the helpers, or invoke
# directly: `lock.sh acquire` / `lock.sh release`.
#
# The lock is a DIRECTORY (`supervisor.lock/`), because `mkdir` is atomic on
# POSIX — two cold acquirers cannot both create it, unlike a test-then-write on a
# regular file. Staleness is decided purely by the lock dir's age: this helper is
# invoked as a SHORT-LIVED subprocess (`bash lock.sh acquire`), so its own PID
# dies the moment it returns and cannot stand in for the long-running holder —
# PID-liveness checks are therefore meaningless here, and age (mtime) is the only
# sound signal. The holder must release explicitly; a crashed holder is recovered
# when the lock ages past LOCK_TTL_HOURS.
#
# acquire: succeeds if the lock is absent or older than LOCK_TTL_HOURS (default
#   6h). Prints "acquired"/exit 0 on success, "busy"/exit 1 otherwise.
# release: remove the lock (idempotent).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

LOCK="$STATE_DIR/supervisor.lock"
LOCK_TTL_HOURS="${LOCK_TTL_HOURS:-6}"

# Is the lock dir at $1 stale (older than the TTL)? `find -mmin -N` matches files
# YOUNGER than N minutes, so an empty result means it is at/over the TTL → stale.
_dir_is_stale() {
  local ttl_min=$(( LOCK_TTL_HOURS * 60 ))
  [ -z "$(find "$1" -maxdepth 0 -mmin "-${ttl_min}" 2>/dev/null)" ]
}

_stamp() { date -u +%Y-%m-%dT%H:%M:%SZ > "$LOCK/meta"; }

lock_acquire() {
  if mkdir "$LOCK" 2>/dev/null; then
    _stamp; echo "acquired"; return 0
  fi
  # Lock exists. Reclaim only if it is stale, and serialize the reclaim through a
  # SECOND atomic mkdir on a reclaim-marker dir: only one racer can create it, so
  # only one reclaimer ever runs `rm`+`mkdir`. This makes mkdir (not the fragile
  # mv/rename of a directory) the single point of mutual exclusion. Everyone who
  # loses the reclaim marker — or sees a fresh lock — reports busy.
  if _dir_is_stale "$LOCK"; then
    local marker="$LOCK.reclaim"
    if mkdir "$marker" 2>/dev/null; then
      # Sole reclaimer. Re-check under the marker: the lock may have been released
      # and re-taken (now fresh) since our staleness check above. Success is gated
      # on our OWN mkdir winning — a cold racer can slip in during the rm→mkdir gap
      # and create $LOCK first, in which case it holds and we report busy.
      local won=false
      if _dir_is_stale "$LOCK"; then
        rm -rf "$LOCK"
        if mkdir "$LOCK" 2>/dev/null; then _stamp; won=true; fi
      fi
      rmdir "$marker"
      if [ "$won" = true ]; then echo "acquired"; return 0; fi
    fi
  fi
  echo "busy"; return 1
}

lock_release() {
  rm -rf "$LOCK"
}

# Allow direct CLI use as well as sourcing.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    acquire) lock_acquire ;;
    release) lock_release ;;
    *) echo "usage: lock.sh {acquire|release}" >&2; exit 2 ;;
  esac
fi
