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
