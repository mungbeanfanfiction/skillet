"""Worktree state classification. Order of checks encodes the spec's
precedence rules — the first matching check wins."""
from enum import Enum


class WorktreeState(str, Enum):
    WORKING = "working"
    NEEDS_INPUT = "needs-input"
    STALLED = "stalled"
    PR_OPEN = "pr-open"
    BLOCKED = "blocked"


RESTART_CAP = 2


def classify(facts: dict) -> WorktreeState:
    """facts keys: process_alive, has_question_md, task_complete, has_open_pr,
    restart_count, task_md_present. Returns the single authoritative state."""
    if facts["has_open_pr"]:
        return WorktreeState.PR_OPEN
    if not facts["task_md_present"]:
        return WorktreeState.BLOCKED
    if facts["has_question_md"]:
        return WorktreeState.NEEDS_INPUT
    if facts["restart_count"] >= RESTART_CAP:
        return WorktreeState.BLOCKED
    if facts["task_complete"]:
        return WorktreeState.BLOCKED  # marked done but no PR → needs a human
    if facts["process_alive"]:
        return WorktreeState.WORKING
    return WorktreeState.STALLED


def is_in_flight(s: WorktreeState) -> bool:
    return s in (WorktreeState.WORKING, WorktreeState.STALLED)
