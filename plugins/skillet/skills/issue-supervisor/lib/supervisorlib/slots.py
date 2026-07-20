"""Slot accounting from ground-truth states each cycle. No shared counter
between loops — both derive from the same state list.

`cap` is required: it comes from `supervisorlib.capacity`, which resolves it from
the host's resources or the user's override. A default here would silently
reinstate the fixed cap this module used to hardcode."""
from supervisorlib.state import WorktreeState, is_in_flight


def free(states: list, *, cap: int, count_stalled: bool = True) -> int:
    """Free slots = cap minus in-flight states.

    count_stalled=False excludes stalled worktrees from the count, for the
    event-driven refill path which skips the restart step (see refill-signals.sh).
    """
    def consumes(s) -> bool:
        if s is WorktreeState.STALLED and not count_stalled:
            return False
        return is_in_flight(s)

    in_flight = sum(1 for s in states if consumes(s))
    return max(0, cap - in_flight)


def is_full(states: list, *, cap: int, count_stalled: bool = True) -> bool:
    return free(states, cap=cap, count_stalled=count_stalled) == 0
