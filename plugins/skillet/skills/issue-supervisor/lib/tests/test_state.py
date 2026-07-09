from supervisorlib import state
from supervisorlib.state import WorktreeState


FRESH = 60
COLD = state.STALE_HEARTBEAT_SECONDS + 1


def make(**kw):
    base = dict(
        process_alive=False, has_question_md=False, task_complete=False,
        has_open_pr=False, pr_merged=False, restart_count=0, task_md_present=True,
        heartbeat_age_seconds=None,
    )
    base.update(kw)
    return base


def test_pr_open_takes_precedence():
    assert state.classify(make(has_open_pr=True, process_alive=True)) == WorktreeState.PR_OPEN


def test_blocked_when_task_md_missing():
    assert state.classify(make(task_md_present=False)) == WorktreeState.BLOCKED


def test_needs_input_when_question_present():
    assert state.classify(make(has_question_md=True, process_alive=True)) == WorktreeState.NEEDS_INPUT


def test_question_md_wins_over_open_pr():
    # An escalated (unclean) merge conflict writes question.md on a worktree that
    # also has an open PR. The pending human question must win — otherwise the
    # escalation is swallowed as `pr-open` and never reaches the user.
    facts = make(has_question_md=True, has_open_pr=True, process_alive=True)
    assert state.classify(facts) == WorktreeState.NEEDS_INPUT


def test_blocked_when_restart_cap_reached():
    assert state.classify(make(restart_count=2)) == WorktreeState.BLOCKED


def test_blocked_when_task_complete_but_no_pr():
    assert state.classify(make(task_complete=True)) == WorktreeState.BLOCKED


def test_working_when_process_alive_no_question():
    assert state.classify(make(process_alive=True)) == WorktreeState.WORKING


def test_stalled_when_dead_incomplete_no_question():
    assert state.classify(make(process_alive=False)) == WorktreeState.STALLED


def test_merged_pr_is_never_stalled_even_when_process_dead():
    # the exact bug: a dead session on a merged branch used to restart forever
    assert state.classify(make(pr_merged=True, process_alive=False)) == WorktreeState.MERGED


def test_merged_pr_wins_over_restart_cap_and_done_no_pr():
    facts = make(pr_merged=True, restart_count=99, task_complete=True)
    assert state.classify(facts) == WorktreeState.MERGED
    assert state.blocked_reason(facts) is None


def test_merged_pr_wins_over_stale_task_md_markers():
    # a session permission-blocked from writing task.md leaves a stale `pickup`
    # marker (task_complete=False) or loses the file entirely. Merged state comes
    # from GitHub, so neither can produce a false stall/block.
    assert state.classify(make(pr_merged=True)) == WorktreeState.MERGED
    assert state.classify(make(pr_merged=True, task_md_present=False)) == WorktreeState.MERGED


def test_merged_never_swallows_a_question_or_an_open_follow_up_pr():
    # merged outranks the local task.md markers, but not a pending human question
    # or a follow-up PR already open off the same branch.
    assert state.classify(make(pr_merged=True, has_question_md=True)) == WorktreeState.NEEDS_INPUT
    assert state.classify(make(pr_merged=True, has_open_pr=True)) == WorktreeState.PR_OPEN


def test_live_session_on_merged_branch_stays_working():
    # a running session may be prepping a follow-up PR off the same branch, so it
    # keeps its slot and is never handed to cleanup mid-run
    facts = make(pr_merged=True, process_alive=True)
    assert state.classify(facts) == WorktreeState.WORKING
    assert state.is_in_flight(state.classify(facts)) is True


def test_wedged_session_on_merged_branch_is_merged_not_working():
    # A live session is exempt from MERGED (it may be prepping a follow-up PR), but a
    # cold heartbeat means wedged — it must not hold a slot on an already-shipped branch.
    facts = make(pr_merged=True, process_alive=True, heartbeat_age_seconds=COLD)
    assert state.classify(facts) == WorktreeState.MERGED
    assert state.is_in_flight(state.classify(facts)) is False


def test_live_session_on_merged_branch_never_reports_blocked():
    # a live session is exempt from MERGED, but must not therefore fall through to
    # the blocking rungs — that was the original bug, just with process_alive set.
    for extra in (dict(task_complete=True), dict(restart_count=99), dict(task_md_present=False)):
        facts = make(pr_merged=True, process_alive=True, **extra)
        assert state.classify(facts) == WorktreeState.WORKING
        assert state.blocked_reason(facts) is None


def test_done_no_pr_still_blocks_when_nothing_ever_merged():
    # the genuine escalation must survive the new merged path
    facts = make(task_complete=True, pr_merged=False)
    assert state.classify(facts) == WorktreeState.BLOCKED
    assert state.blocked_reason(facts) == "done_no_pr"


def test_closed_unmerged_pr_does_not_read_as_merged():
    # pr_merged is set only for MERGED PRs; an abandoned/rejected PR leaves it
    # False, so the worktree keeps its ordinary classification.
    assert state.classify(make(pr_merged=False, process_alive=False)) == WorktreeState.STALLED


def test_in_flight_only_for_working_and_stalled():
    assert state.is_in_flight(WorktreeState.WORKING) is True
    assert state.is_in_flight(WorktreeState.STALLED) is True
    assert state.is_in_flight(WorktreeState.NEEDS_INPUT) is False
    assert state.is_in_flight(WorktreeState.PR_OPEN) is False
    assert state.is_in_flight(WorktreeState.MERGED) is False
    assert state.is_in_flight(WorktreeState.BLOCKED) is False


def test_live_session_with_cold_heartbeat_is_stalled():
    # kill -0 says alive; no tool call in 45min says wedged. Stalled frees the slot.
    assert state.classify(make(process_alive=True, heartbeat_age_seconds=COLD)) == WorktreeState.STALLED
    assert state.classify(make(process_alive=True, heartbeat_age_seconds=FRESH)) == WorktreeState.WORKING


def test_is_stale_needs_a_live_pid_and_a_heartbeat_past_the_threshold():
    # None = no evidence (pre-hook worktree, or died before its first tool call);
    # a dead PID is already STALLED; the boundary itself is not yet stale.
    assert state.is_stale(make(process_alive=True, heartbeat_age_seconds=None)) is False
    assert state.classify(make(process_alive=True, heartbeat_age_seconds=None)) == WorktreeState.WORKING
    assert state.is_stale(make(process_alive=False, heartbeat_age_seconds=COLD)) is False
    assert state.is_stale(make(process_alive=True,
                               heartbeat_age_seconds=state.STALE_HEARTBEAT_SECONDS)) is False


def test_cold_heartbeat_does_not_override_question_pr_or_restart_cap():
    cold = dict(process_alive=True, heartbeat_age_seconds=COLD)
    assert state.classify(make(has_question_md=True, **cold)) == WorktreeState.NEEDS_INPUT
    assert state.classify(make(has_open_pr=True, **cold)) == WorktreeState.PR_OPEN
    capped = make(restart_count=2, **cold)  # must not be restarted forever
    assert state.classify(capped) == WorktreeState.BLOCKED
    assert state.blocked_reason(capped) == "restart_cap"


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
