"""Completion-signal sentinels — the event channel that lets a finishing
dispatched session tell the supervisor "a slot is free now" so the freed slot is
refilled promptly instead of waiting for the next ~5h poll.

A signal is a tiny JSON file under `<state_dir>/signals/`. A finishing session
drops one naming its own worktree; a lightweight lock-guarded refill pass (and
the periodic cycle, as a backstop) consumes them. Writes are atomic (temp file +
rename) so a crash mid-write never leaves a half-written sentinel for a reader.

The supervisor does not trust a sentinel as proof a slot is free — it always
re-derives state from `survey.sh`. A sentinel is only a *prompt to look now*;
ground truth still comes from the survey. So a stale or spurious sentinel costs
at most one extra survey, never a wrong dispatch.
"""
import hashlib
import json
import os
from pathlib import Path


def signals_dir(state_dir) -> Path:
    return Path(state_dir) / "signals"


def _sentinel_name(path: str) -> str:
    # Hash the worktree path so the filename is filesystem-safe regardless of the
    # path's characters, and so repeated signals for the same worktree collapse to
    # one file (idempotent — a session that re-runs notify can't pile up sentinels).
    digest = hashlib.sha256(path.encode("utf-8")).hexdigest()[:16]
    return f"{digest}.json"


def write(state_dir, *, path: str, issue, created_at) -> Path:
    """Drop a completion sentinel for the worktree at `path`. Idempotent per
    worktree (same path → same filename, overwritten atomically)."""
    d = signals_dir(state_dir)
    d.mkdir(parents=True, exist_ok=True)
    target = d / _sentinel_name(path)
    payload = {"path": path, "issue": issue, "created_at": created_at}
    tmp = target.with_suffix(target.suffix + ".tmp")
    tmp.write_text(json.dumps(payload))
    os.replace(tmp, target)
    return target


def pending(state_dir) -> list:
    """All pending completion signals, oldest sentinel first by created_at.
    Skips unreadable/partial sentinels rather than raising — a corrupt sentinel
    must never wedge the consumer; the periodic survey is the backstop."""
    d = signals_dir(state_dir)
    if not d.exists():
        return []
    out = []
    for f in sorted(d.glob("*.json")):
        try:
            out.append(json.loads(f.read_text()))
        except (OSError, ValueError):
            continue
    out.sort(key=lambda s: s.get("created_at", ""))
    return out


def clear(state_dir, *, path: str = None) -> int:
    """Remove consumed sentinels. With `path`, clear only that worktree's
    sentinel; without it, clear all. Returns the number removed."""
    d = signals_dir(state_dir)
    if not d.exists():
        return 0
    if path is not None:
        targets = [d / _sentinel_name(path)]
    else:
        targets = list(d.glob("*.json"))
    removed = 0
    for t in targets:
        try:
            t.unlink()
            removed += 1
        except FileNotFoundError:
            continue
    return removed
