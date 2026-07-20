from supervisorlib import slots
from supervisorlib.state import WorktreeState as S

CAP = 3


def test_free_counts_only_in_flight():
    assert slots.free([S.WORKING, S.NEEDS_INPUT, S.PR_OPEN], cap=CAP) == 2


def test_free_zero_when_full():
    assert slots.free([S.WORKING, S.STALLED, S.WORKING], cap=CAP) == 0


def test_free_never_negative():
    assert slots.free([S.WORKING] * 5, cap=CAP) == 0


def test_is_full():
    assert slots.is_full([S.WORKING, S.STALLED, S.WORKING], cap=CAP) is True
    assert slots.is_full([S.WORKING], cap=CAP) is False


def test_pr_open_and_blocked_never_hold_a_slot_even_at_full_backlog():
    # Issue #100: a worktree awaiting human PR review, or one that permanently hit
    # its restart cap, must never read as "slots full" and block dispatch of ready
    # backlog work. Neither PR_OPEN nor BLOCKED is in-flight, so a cap of 3 stays
    # fully free no matter how many of each accumulate.
    states = [S.PR_OPEN, S.PR_OPEN, S.BLOCKED, S.BLOCKED, S.NEEDS_INPUT, S.MERGED]
    assert slots.free(states, cap=CAP) == CAP
    assert slots.is_full(states, cap=CAP) is False
