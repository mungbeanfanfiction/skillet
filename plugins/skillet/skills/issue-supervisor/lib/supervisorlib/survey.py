"""Assemble the ground-truth survey JSON the SKILL.md consumes each cycle.
Foreign worktrees are reported but never counted toward slots."""
from supervisorlib import state as state_mod, slots


def assemble(*, worktree_facts: list, eligible_issues: list) -> dict:
    worktrees = []
    in_flight_states = []
    for w in worktree_facts:
        st = state_mod.classify(w["facts"])
        worktrees.append({
            "issue": w["issue"], "path": w["path"], "branch": w["branch"],
            "owned": w["owned"], "state": st.value,
        })
        if w["owned"]:
            in_flight_states.append(st)
    return {
        "worktrees": worktrees,
        "free_slots": slots.free(in_flight_states, cap=3),
        "eligible_issues": [i["number"] for i in eligible_issues],
    }
