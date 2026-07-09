"""Assemble the ground-truth survey JSON the SKILL.md consumes each cycle.
Foreign worktrees are reported but never counted toward slots."""
from supervisorlib import state as state_mod, slots
from supervisorlib.state import WorktreeState

# PRs over this many changed lines (added + deleted) are blocked by open-pr; the
# supervisor flags owned worktrees that cross it pre-PR so it can prompt a split
# before the work balloons further. Keep in sync with open-pr's cap.
PR_LINE_LIMIT = 400


def _oversize_diff(facts: dict) -> bool:
    """True when an owned, pre-PR worktree's diff exceeds the PR line limit.
    Advisory only — does not affect classify(); a worktree whose PR is already
    open or merged is past this gate and is not flagged."""
    if facts.get("has_open_pr") or facts.get("pr_merged"):
        return False
    return facts.get("diff_changed_lines", 0) > PR_LINE_LIMIT


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
        # A merged PR is terminal: the work shipped and the worktree is dead
        # weight. Mark it so the report can hand it to /cleanup-worktrees rather
        # than restart it or escalate it to a human.
        if st is WorktreeState.MERGED:
            entry["cleanup_candidate"] = True
        # Flag owned worktrees whose pre-PR diff has outgrown the 400-line cap so
        # the supervisor can prompt a split before they reach open-pr (which would
        # hard-block them). Foreign worktrees are never flagged.
        if w["owned"] and _oversize_diff(w["facts"]):
            entry["oversize_diff"] = True
            entry["diff_changed_lines"] = w["facts"].get("diff_changed_lines", 0)
        # An unclean merge conflict that resolve-conflicts escalated, surfaced
        # here so the supervisor gets a digest line in its own cycle — before the
        # question-sweeper runs. Marker is written by the PR-watch session (spawn.py).
        if w["owned"] and w["facts"].get("conflict_escalated"):
            entry["conflict_escalated"] = True
        worktrees.append(entry)
    return {
        "worktrees": worktrees,
        "free_slots": slots.free(in_flight_states, cap=3),
        "eligible_issues": [i["number"] for i in eligible_issues],
    }
