"""Assemble the ground-truth survey JSON the SKILL.md consumes each cycle.
Foreign worktrees are reported but never counted toward slots."""
from supervisorlib import state as state_mod, slots
from supervisorlib.state import WorktreeState


def assemble(*, worktree_facts: list, eligible_issues: list) -> dict:
    worktrees = []
    in_flight_states = []
    for w in worktree_facts:
        # State classification only has meaning for OWNED worktrees. A foreign
        # worktree (someone's real in-progress work, no task.md) would otherwise
        # classify as `blocked` and read as alarming in the report; give it the
        # dedicated `foreign` state instead.
        if not w["owned"]:
            st = WorktreeState.FOREIGN
        else:
            st = state_mod.classify(w["facts"])
            in_flight_states.append(st)
        entry = {
            "issue": w["issue"], "path": w["path"], "branch": w["branch"],
            "owned": w["owned"], "state": st.value,
        }
        # Surface WHY an owned worktree is blocked so the report can act without
        # guessing (drift vs restart-cap vs done-no-PR).
        if st is WorktreeState.BLOCKED:
            entry["blocked_reason"] = state_mod.blocked_reason(w["facts"])
        worktrees.append(entry)
    return {
        "worktrees": worktrees,
        "free_slots": slots.free(in_flight_states, cap=3),
        "eligible_issues": [i["number"] for i in eligible_issues],
    }
