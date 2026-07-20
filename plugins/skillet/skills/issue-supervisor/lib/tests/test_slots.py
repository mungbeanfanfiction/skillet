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


def test_stalled_consumes_a_slot_in_full_cycle():
    assert slots.free([S.WORKING, S.STALLED], cap=CAP) == 1


def test_stalled_frees_a_slot_in_refill_path():
    assert slots.free([S.WORKING, S.STALLED], cap=CAP, count_stalled=False) == 2


def test_only_stalled_is_affected_by_count_stalled():
    states = [S.WORKING, S.NEEDS_INPUT, S.PR_OPEN]
    assert slots.free(states, cap=CAP, count_stalled=False) == 2
    assert slots.free(states, cap=CAP, count_stalled=True) == 2


def test_is_full_respects_count_stalled():
    states = [S.WORKING, S.STALLED, S.WORKING]
    assert slots.is_full(states, cap=CAP) is True
    assert slots.is_full(states, cap=CAP, count_stalled=False) is False
