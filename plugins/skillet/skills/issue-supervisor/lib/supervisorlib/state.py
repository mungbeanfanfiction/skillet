"""Worktree state classification. Order of checks encodes the spec's
precedence rules — the first matching check wins."""
from enum import Enum


class WorktreeState(str, Enum):
    WORKING = "working"
    NEEDS_INPUT = "needs-input"
    STALLED = "stalled"
    PR_OPEN = "pr-open"
    BLOCKED = "blocked"
    FOREIGN = "foreign"  # not owned by the loop — report-only, never classified/touched


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


def blocked_reason(facts: dict):
    """Why a worktree is BLOCKED, or None if it isn't. Mirrors classify()'s
    precedence so the reason always matches the verdict. Lets the report
    distinguish registry/disk drift from a genuine give-up without guessing:
      - task_md_missing : registry points at a worktree with no task.md (drift)
      - restart_cap     : hit the restart budget — a real, repeated failure
      - done_no_pr      : marked done but never opened a PR — needs a human
    """
    if classify(facts) is not WorktreeState.BLOCKED:
        return None
    if not facts["task_md_present"]:
        return "task_md_missing"
    if facts["restart_count"] >= RESTART_CAP:
        return "restart_cap"
    # classify() returned BLOCKED and the two above didn't match → done-but-no-PR.
    return "done_no_pr"


def is_in_flight(s: WorktreeState) -> bool:
    return s in (WorktreeState.WORKING, WorktreeState.STALLED)
