"""Host-aware concurrency cap for dispatched sessions.

Each in-flight slot is a full headless `claude` session that fans out subagents
and runs the target repo's tests/build, so a slot costs real CPU and RAM. A fixed
cap of 3 saturates a laptop when the target repo's per-task work is expensive
(see issue #77). Derive the default from host capacity instead, and let the user
override it outright.
"""
import os

ENV_VAR = "SKILLET_SUPERVISOR_MAX_SLOTS"

# One slot ≈ one headless session + its subagents + a test/build run. These
# divisors are a deliberately conservative budget, not a measurement: they leave
# the host enough headroom to stay responsive while the sessions work.
CPUS_PER_SLOT = 4
GIB_PER_SLOT = 6

MIN_CAP = 1
MAX_CAP = 3  # the historical fixed cap; a big host gets no more than it used to


def _total_ram_gib():
    """Total physical RAM in GiB, or None where sysconf can't tell us.

    Deliberately total, not available: `SC_PHYS_PAGES` is the one memory figure
    stdlib exposes on both macOS and Linux, and host capacity — not this
    instant's free pages — is the right basis for a default.
    """
    try:
        return (os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")) / 2**30
    except (ValueError, OSError, AttributeError):
        return None


def host_cap(cpus, ram_gib) -> int:
    """The cap the given host resources support, clamped to [MIN_CAP, MAX_CAP].

    A falsy (unknown) CPU count or RAM size drops that budget rather than
    assuming a value, so a host we can't introspect falls back to the historical
    MAX_CAP instead of throttling to 1 for the wrong reason.
    """
    budgets = [MAX_CAP]
    if cpus:
        budgets.append(cpus // CPUS_PER_SLOT)
    if ram_gib:
        budgets.append(int(ram_gib // GIB_PER_SLOT))
    return max(MIN_CAP, min(budgets))


def default_cap() -> int:
    """`host_cap` applied to THIS host's resources."""
    return host_cap(os.cpu_count(), _total_ram_gib())


def resolve_cap(env=None) -> int:
    """The effective cap: an explicit override, else the host-derived default.

    The override is honoured beyond MAX_CAP — a user with a big machine who asks
    for 8 slots means it. A non-numeric or non-positive value is ignored rather
    than raising: a typo'd env var must not take the supervisor's cycle down.
    """
    raw = (env if env is not None else os.environ).get(ENV_VAR, "").strip()
    try:
        # Parse rather than pre-check: `str.isdigit()` accepts Unicode digits like
        # "²" that `int()` then rejects, and an escaped ValueError here aborts the
        # whole survey cycle via survey.sh's ERR trap.
        n = int(raw)
    except ValueError:
        return default_cap()
    return n if n > 0 else default_cap()
