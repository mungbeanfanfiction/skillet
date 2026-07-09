from supervisorlib import survey
from supervisorlib.state import WorktreeState as S


def test_assemble_produces_states_and_free_slots():
    worktree_facts = [
        {"issue": 1, "path": "/wt/1", "branch": "auto-1", "owned": True,
         "facts": {"process_alive": True, "has_question_md": False, "task_complete": False,
                   "has_open_pr": False, "restart_count": 0, "task_md_present": True}},
        {"issue": 2, "path": "/wt/2", "branch": "auto-2", "owned": True,
         "facts": {"process_alive": False, "has_question_md": True, "task_complete": False,
                   "has_open_pr": False, "restart_count": 0, "task_md_present": True}},
    ]
    # Pin the cap: the default is host-derived, so a bare call would make the
    # free_slots assertion depend on the machine running the suite.
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[{"number": 7}], cap=3)
    by_issue = {w["issue"]: w for w in result["worktrees"]}
    assert by_issue[1]["state"] == S.WORKING.value
    assert by_issue[2]["state"] == S.NEEDS_INPUT.value
    assert result["free_slots"] == 2
    assert result["slot_cap"] == 3
    assert result["eligible_issues"] == [7]


def test_foreign_worktrees_never_consume_a_slot():
    worktree_facts = [
        {"issue": None, "path": "/wt/foreign", "branch": "fix/x", "owned": False,
         "facts": {"process_alive": False, "has_question_md": False, "task_complete": False,
                   "has_open_pr": False, "restart_count": 0, "task_md_present": False}},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[], cap=3)
    assert result["worktrees"][0]["owned"] is False
    assert result["free_slots"] == 3


def test_blocked_owned_worktree_includes_reason():
    worktree_facts = [
        {"issue": 5, "path": "/wt/5", "branch": "auto-5", "owned": True,
         "facts": {"process_alive": False, "has_question_md": False, "task_complete": False,
                   "has_open_pr": False, "restart_count": 0, "task_md_present": False}},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    w = result["worktrees"][0]
    assert w["state"] == S.BLOCKED.value
    assert w["blocked_reason"] == "task_md_missing"


def test_non_blocked_worktree_has_no_blocked_reason():
    worktree_facts = [
        {"issue": 6, "path": "/wt/6", "branch": "auto-6", "owned": True,
         "facts": {"process_alive": True, "has_question_md": False, "task_complete": False,
                   "has_open_pr": False, "restart_count": 0, "task_md_present": True}},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    assert result["worktrees"][0].get("blocked_reason") is None


def _facts(**over):
    base = {"process_alive": True, "has_question_md": False, "task_complete": False,
            "has_open_pr": False, "pr_merged": False, "restart_count": 0,
            "task_md_present": True, "diff_changed_lines": 0,
            "heartbeat_age_seconds": None}
    base.update(over)
    return base


def test_owned_pre_pr_worktree_over_400_lines_is_flagged_oversize():
    worktree_facts = [
        {"issue": 8, "path": "/wt/8", "branch": "auto-8", "owned": True,
         "facts": _facts(diff_changed_lines=612)},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    w = result["worktrees"][0]
    assert w["oversize_diff"] is True
    assert w["diff_changed_lines"] == 612


def test_worktree_at_or_under_400_lines_is_not_flagged():
    worktree_facts = [
        {"issue": 9, "path": "/wt/9", "branch": "auto-9", "owned": True,
         "facts": _facts(diff_changed_lines=400)},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    assert "oversize_diff" not in result["worktrees"][0]


def test_oversize_diff_not_flagged_once_a_pr_is_open():
    # past the open-pr gate — the cap already had its chance to block; don't nag.
    worktree_facts = [
        {"issue": 10, "path": "/wt/10", "branch": "auto-10", "owned": True,
         "facts": _facts(diff_changed_lines=900, has_open_pr=True)},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    assert "oversize_diff" not in result["worktrees"][0]


def test_foreign_worktree_is_never_flagged_oversize():
    worktree_facts = [
        {"issue": None, "path": "/wt/foreign", "branch": "feat-x", "owned": False,
         "facts": _facts(diff_changed_lines=999)},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    assert "oversize_diff" not in result["worktrees"][0]


def test_merged_worktree_is_a_cleanup_candidate_and_frees_its_slot():
    worktree_facts = [
        {"issue": 47, "path": "/wt/47", "branch": "auto-47", "owned": True,
         "facts": _facts(pr_merged=True, process_alive=False, restart_count=2)},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[], cap=3)
    w = result["worktrees"][0]
    assert w["state"] == S.MERGED.value
    assert w["cleanup_candidate"] is True
    assert "blocked_reason" not in w
    assert result["free_slots"] == 3


def test_non_merged_worktree_is_not_a_cleanup_candidate():
    worktree_facts = [
        {"issue": 48, "path": "/wt/48", "branch": "auto-48", "owned": True,
         "facts": _facts()},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    assert "cleanup_candidate" not in result["worktrees"][0]


def test_merged_worktree_is_not_flagged_oversize():
    # it already shipped; a "needs split" nag on merged work is noise
    worktree_facts = [
        {"issue": 49, "path": "/wt/49", "branch": "auto-49", "owned": True,
         "facts": _facts(pr_merged=True, diff_changed_lines=900)},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    assert "oversize_diff" not in result["worktrees"][0]


def test_owned_worktree_with_escalated_conflict_is_flagged():
    # An unclean conflict that resolve-conflicts escalated must surface in the
    # survey JSON so the supervisor prints a digest line in its own cycle. Such a
    # worktree also has an open PR + question.md → classifies as needs-input.
    worktree_facts = [
        {"issue": 11, "path": "/wt/11", "branch": "auto-11", "owned": True,
         "facts": _facts(conflict_escalated=True, has_open_pr=True, has_question_md=True)},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    w = result["worktrees"][0]
    assert w["conflict_escalated"] is True
    assert w["state"] == S.NEEDS_INPUT.value


def test_worktree_without_escalation_has_no_conflict_flag():
    worktree_facts = [
        {"issue": 12, "path": "/wt/12", "branch": "auto-12", "owned": True,
         "facts": _facts()},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    assert "conflict_escalated" not in result["worktrees"][0]


def test_foreign_worktree_is_never_flagged_escalated():
    worktree_facts = [
        {"issue": None, "path": "/wt/foreign", "branch": "feat-x", "owned": False,
         "facts": _facts(conflict_escalated=True)},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    assert "conflict_escalated" not in result["worktrees"][0]


COLD = 61 * 60


def test_stale_live_session_is_flagged_and_frees_its_slot():
    worktree_facts = [
        {"issue": 13, "path": "/wt/13", "branch": "auto-13", "owned": True,
         "facts": _facts(process_alive=True, heartbeat_age_seconds=COLD,
                         last_step="Bash (stage: ci)", exit_reason=None)},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    w = result["worktrees"][0]
    assert w["state"] == S.STALLED.value
    assert w["stale_heartbeat"] is True
    assert w["heartbeat_age_seconds"] == COLD
    assert w["last_step"] == "Bash (stage: ci)"
    # STALLED is still in-flight (it gets restarted), so the slot count is unchanged.
    assert result["free_slots"] == 2


def test_stale_flag_only_on_stalled_never_on_working_or_pr_open():
    # A `pr-open` worktree waiting on CI makes no tool calls, so its heartbeat goes
    # cold while it is perfectly healthy — it must not be reported as a dead session.
    for facts in (_facts(process_alive=True, heartbeat_age_seconds=30),
                  _facts(process_alive=True, heartbeat_age_seconds=COLD, has_open_pr=True),
                  _facts(process_alive=True, heartbeat_age_seconds=COLD, has_question_md=True)):
        w = survey.assemble(worktree_facts=[
            {"issue": 14, "path": "/wt/14", "branch": "auto-14", "owned": True, "facts": facts},
        ], eligible_issues=[])["worktrees"][0]
        assert "stale_heartbeat" not in w
        assert "last_step" not in w


def test_dead_session_reports_last_step_and_exit_reason_without_stale_flag():
    worktree_facts = [
        {"issue": 15, "path": "/wt/15", "branch": "auto-15", "owned": True,
         "facts": _facts(process_alive=False, heartbeat_age_seconds=COLD,
                         last_step="Edit (stage: work)", exit_reason="other")},
    ]
    w = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])["worktrees"][0]
    assert w["state"] == S.STALLED.value
    assert "stale_heartbeat" not in w  # it exited; it didn't hang
    assert w["last_step"] == "Edit (stage: work)"
    assert w["exit_reason"] == "other"


def test_foreign_worktrees_get_foreign_state_not_blocked():
    # state classification is only meaningful for OWNED worktrees; a foreign
    # worktree (someone's real in-progress work, no task.md) must not be reported
    # as `blocked` — it gets the dedicated `foreign` state.
    worktree_facts = [
        {"issue": None, "path": "/wt/foreign", "branch": "feat-x", "owned": False,
         "facts": {"process_alive": False, "has_question_md": False, "task_complete": False,
                   "has_open_pr": False, "restart_count": 0, "task_md_present": False}},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    assert result["worktrees"][0]["state"] == S.FOREIGN.value
