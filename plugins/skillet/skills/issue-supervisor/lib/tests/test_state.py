from supervisorlib import state
from supervisorlib.state import WorktreeState


def make(**kw):
    base = dict(
        process_alive=False, has_question_md=False, task_complete=False,
        has_open_pr=False, restart_count=0, task_md_present=True,
    )
    base.update(kw)
    return base


def test_pr_open_takes_precedence():
    assert state.classify(make(has_open_pr=True, process_alive=True)) == WorktreeState.PR_OPEN


def test_blocked_when_task_md_missing():
    assert state.classify(make(task_md_present=False)) == WorktreeState.BLOCKED


def test_needs_input_when_question_present():
    assert state.classify(make(has_question_md=True, process_alive=True)) == WorktreeState.NEEDS_INPUT


def test_blocked_when_restart_cap_reached():
    assert state.classify(make(restart_count=2)) == WorktreeState.BLOCKED


def test_blocked_when_task_complete_but_no_pr():
    assert state.classify(make(task_complete=True)) == WorktreeState.BLOCKED


def test_working_when_process_alive_no_question():
    assert state.classify(make(process_alive=True)) == WorktreeState.WORKING


def test_stalled_when_dead_incomplete_no_question():
    assert state.classify(make(process_alive=False)) == WorktreeState.STALLED


def test_in_flight_only_for_working_and_stalled():
    assert state.is_in_flight(WorktreeState.WORKING) is True
    assert state.is_in_flight(WorktreeState.STALLED) is True
    assert state.is_in_flight(WorktreeState.NEEDS_INPUT) is False
    assert state.is_in_flight(WorktreeState.PR_OPEN) is False
    assert state.is_in_flight(WorktreeState.BLOCKED) is False


def test_blocked_reason_none_when_not_blocked():
    assert state.blocked_reason(make(process_alive=True)) is None          # working
    assert state.blocked_reason(make()) is None                            # stalled
    assert state.blocked_reason(make(has_question_md=True)) is None         # needs-input


def test_blocked_reason_task_md_missing():
    # registry points at a worktree whose task.md vanished → possible drift
    assert state.blocked_reason(make(task_md_present=False)) == "task_md_missing"


def test_blocked_reason_restart_cap():
    assert state.blocked_reason(make(restart_count=2)) == "restart_cap"


def test_blocked_reason_done_no_pr():
    assert state.blocked_reason(make(task_complete=True)) == "done_no_pr"


def test_blocked_reason_precedence_matches_classify():
    # task_md_missing wins over restart_cap (same order as classify's checks)
    facts = make(task_md_present=False, restart_count=2, task_complete=True)
    assert state.classify(facts) == WorktreeState.BLOCKED
    assert state.blocked_reason(facts) == "task_md_missing"
