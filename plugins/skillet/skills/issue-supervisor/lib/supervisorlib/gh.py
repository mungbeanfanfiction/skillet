"""Pure filters over `gh` JSON. Subprocess invocation lives in the shell
layer; these take parsed JSON so they're unit-testable without network."""

GATE_LABEL = "auto"
EPIC_LABEL = "epic"
EXPLORE_LABEL = "explore"


def _label_names(issue: dict) -> set:
    return {lbl["name"] for lbl in issue.get("labels", [])}


def is_explore(issue: dict) -> bool:
    """True iff the issue carries the `explore` label. The per-issue pipeline
    routes these to the explore-issue skill instead of the implement path."""
    return EXPLORE_LABEL in _label_names(issue)


def eligible_issues(issues: list, *, owned_issue_numbers: list) -> list:
    owned = set(owned_issue_numbers)
    out = [
        i for i in issues
        if GATE_LABEL in _label_names(i)
        and EPIC_LABEL not in _label_names(i)
        and i["number"] not in owned
    ]
    return sorted(out, key=lambda i: i["number"])


def open_pr_branches(prs: list) -> set:
    return {pr["headRefName"] for pr in prs}
