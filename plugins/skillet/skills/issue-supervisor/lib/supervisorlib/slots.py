"""Slot accounting from ground-truth states each cycle. No shared counter
between loops — both derive from the same state list."""
from supervisorlib.state import is_in_flight


def free(states: list, *, cap: int = 3) -> int:
    in_flight = sum(1 for s in states if is_in_flight(s))
    return max(0, cap - in_flight)


def is_full(states: list, *, cap: int = 3) -> bool:
    return free(states, cap=cap) == 0
