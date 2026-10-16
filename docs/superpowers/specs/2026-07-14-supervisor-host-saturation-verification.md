# issue-supervisor: host-saturation verification (issue #93)

Closes the verification half of the resource-awareness epic (#77). Confirms that a
full supervisor cycle against a large-repo-shaped workload no longer saturates the
host, and captures the before/after evidence.

## What "saturation" was

Each in-flight slot is a full headless `claude` session that runs the target repo's
tests/build. A repo's CI commonly runs `pytest -n auto`, which spawns **one worker
per core**. Under the old fixed cap of 3, the worst case (all 3 slots running CI at
once) was:

```
peak test procs = 3 slots × (1 worker per core) = 3 × cores
```

i.e. ~3× core count in concurrent CPU-bound processes — a sustained load average of
~3× cores that pegs the machine. On a large repo (heavy suite, long CI) every slot
hits that worst case, so the storm is the common case, not the tail.

## What ships now (#88, merged)

Two multiplicative bounds, both on this branch:

1. **Host-aware slot cap** (`supervisorlib.capacity`): the default is the scarcer of
   `cpus // 4` and `RAM_GiB // 6`, clamped to `[1, 3]`.
2. **Per-session xdist worker cap** (`PYTEST_XDIST_AUTO_NUM_WORKERS`, default `3`):
   each session's `-n auto` resolves to at most 3 workers instead of one-per-core.

Peak concurrent test processes is therefore `slot_cap × xdist_workers`, no longer
tied to core count.

## Evidence

Modelled deterministically from the shipped code (`capacity.host_cap` + the xdist
default), across representative host shapes. Reproduce with:

```
cd plugins/skillet/skills/issue-supervisor/lib
python3 - <<'PY'
from supervisorlib import capacity
XDIST = 3  # PYTEST_XDIST_AUTO_NUM_WORKERS default
for name, cpus, ram in [
    ("8-core/8 GiB laptop", 8, 8), ("8-core/16 GiB laptop", 8, 16),
    ("10-core/32 GiB (M1 Pro)", 10, 32), ("16-core/32 GiB desktop", 16, 32),
    ("16-core/64 GiB workstation", 16, 64), ("64-core/256 GiB server", 64, 256),
]:
    cap = capacity.host_cap(cpus, ram); peak = cap * XDIST
    print(f"{name:<28} cap={cap} peak_test_procs={peak} cores={cpus} "
          f"{'OVER-SUBSCRIBED' if peak > cpus else 'ok'}")
PY
```

| host | slot_cap | peak test procs (cap×3) | cores | vs cores |
|------|---------:|------------------------:|------:|----------|
| 8-core / 8 GiB laptop      | 1 | 3 | 8  | ok (0.4×) |
| 8-core / 16 GiB laptop     | 2 | 6 | 8  | ok (0.8×) |
| 10-core / 32 GiB (M1 Pro)  | 2 | 6 | 10 | ok (0.6×) |
| 16-core / 32 GiB desktop   | 3 | 9 | 16 | ok (0.6×) |
| 16-core / 64 GiB workstation | 3 | 9 | 16 | ok (0.6×) |
| 64-core / 256 GiB server   | 3 | 9 | 64 | ok (0.1×) |

**Before (fixed cap 3, xdist = cores):** peak test procs = `3 × cores` on every
host — a load of ~3× cores (24 procs on an 8-core laptop, 48 on a 16-core desktop).

**After (#88):** peak test procs = `cap × 3` never exceeds core count on any shape
above — the largest ratio is 0.8× on an 8-core / 16 GiB laptop. The machine keeps
headroom for foreground work through a full cycle.

The 8-core / 8 GiB laptop (this verification host) resolves to `cap=1`, the exact
case the old fixed 3 over-subscribed 3×; it now runs a single session with ≤3 test
workers. The `capacity` unit suite (`tests/test_capacity.py`, 8 tests) covers the
derivation, the clamp, the unknown-resource fallback, and the override.

## Independent runaway backstop

Orthogonal to the CPU bound, a per-session wall-clock cap
(`SKILLET_SESSION_TIMEOUT_SECONDS`, default 3600s) reaps any single spawn — and its
whole process group, including xdist workers — that outlives the ceiling, even after
the supervisor itself has exited. So a hung or runaway session cannot burn a core
indefinitely between survey cycles.

## Not in scope here

Cross-slot serialization of heavy test/build steps and `nice`/`ionice` scheduling
priority are tracked separately under #91 (PR #96). The slot cap + xdist cap already
bound the CPU multiplier; the first lever for a hot host is
`SKILLET_SUPERVISOR_MAX_SLOTS=1`.
