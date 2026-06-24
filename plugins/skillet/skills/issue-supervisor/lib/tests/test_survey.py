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
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[{"number": 7}])
    by_issue = {w["issue"]: w for w in result["worktrees"]}
    assert by_issue[1]["state"] == S.WORKING.value
    assert by_issue[2]["state"] == S.NEEDS_INPUT.value
    assert result["free_slots"] == 2
    assert result["eligible_issues"] == [7]


def test_foreign_worktrees_never_consume_a_slot():
    worktree_facts = [
        {"issue": None, "path": "/wt/foreign", "branch": "fix/x", "owned": False,
         "facts": {"process_alive": False, "has_question_md": False, "task_complete": False,
                   "has_open_pr": False, "restart_count": 0, "task_md_present": False}},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
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
