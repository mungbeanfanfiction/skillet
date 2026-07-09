"""Worktree state classification. Order of checks encodes the spec's
precedence rules — the first matching check wins."""
from enum import Enum


class WorktreeState(str, Enum):
    WORKING = "working"
    NEEDS_INPUT = "needs-input"
    STALLED = "stalled"
    PR_OPEN = "pr-open"
    MERGED = "merged"  # terminal: the branch's PR shipped — safe to clean up
    BLOCKED = "blocked"
    FOREIGN = "foreign"  # not owned by the loop — report-only, never classified/touched


RESTART_CAP = 2

# A session that has not touched a single tool in this long is hung, not thinking.
# Generous enough to cover a long CI run or a code-reviewer subagent, short enough
# that a wedged session frees its slot within one supervisor cycle.
STALE_HEARTBEAT_SECONDS = 45 * 60


def is_stale(facts: dict) -> bool:
    """True when a live PID has stopped making progress. `kill -0` proves a process
    exists, not that it is doing anything; a wedged session would otherwise report
    `working` forever and hold a slot. A missing heartbeat (`None`) is NOT stale —
    the worktree may predate the hook, and `process_alive` already tells the truth."""
    if not facts.get("process_alive"):
        return False
    age = facts.get("heartbeat_age_seconds")
    return age is not None and age > STALE_HEARTBEAT_SECONDS


def classify(facts: dict) -> WorktreeState:
    """facts keys: process_alive, has_question_md, task_complete, has_open_pr,
    pr_merged, restart_count, task_md_present, heartbeat_age_seconds. Returns the
    single authoritative state."""
    # A pending human question wins over everything answerable only by a person —
    # including an open PR. An escalated (unclean) merge conflict writes
    # question.md on a worktree that ALSO has an open PR; checking has_open_pr
    # first would swallow it as `pr-open` and the question would never surface.
    if facts["has_question_md"]:
        return WorktreeState.NEEDS_INPUT
    if facts["has_open_pr"]:
        return WorktreeState.PR_OPEN
    # Sourced from GitHub, so it must outrank every local `task.md` marker below:
    # a stale `done` marker or a spent restart budget would otherwise restart
    # finished work and bury real escalations behind false `done_no_pr` entries.
    # A live session is still `working` — likely prepping a follow-up PR — unless its
    # heartbeat went cold, in which case it is wedged and the merged branch is terminal.
    if facts.get("pr_merged"):
        if facts["process_alive"] and not is_stale(facts):
            return WorktreeState.WORKING
        return WorktreeState.MERGED
    if not facts["task_md_present"]:
        return WorktreeState.BLOCKED
    if facts["restart_count"] >= RESTART_CAP:
        return WorktreeState.BLOCKED
    if facts["task_complete"]:
        return WorktreeState.BLOCKED  # marked done but no PR → needs a human
    # A hung session is as dead as an exited one for slot purposes: STALLED routes it
    # to restart.sh, which kills the wedged PID before respawning, and the restart cap
    # still promotes a repeat offender to BLOCKED rather than looping forever.
    if facts["process_alive"] and not is_stale(facts):
        return WorktreeState.WORKING
    return WorktreeState.STALLED


def blocked_reason(facts: dict):
    """Why a worktree is BLOCKED, or None if it isn't. Mirrors classify()'s
    precedence so the reason always matches the verdict. Lets the report
    distinguish registry/disk drift from a genuine give-up without guessing:
      - task_md_missing : registry points at a worktree with no task.md (drift)
      - restart_cap     : hit the restart budget — a real, repeated failure
      - done_no_pr      : marked done but never opened a PR — needs a human

    `done_no_pr` is unambiguous: a merged PR outranks the markers that lead here,
    so reaching it means the session marked itself done with no PR at all.
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
