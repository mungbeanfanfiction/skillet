"""Render GitHub references (PRs) as URLs and markdown links.

The supervisor's concise per-cycle digest mentions PR numbers (e.g. the
`pr-watch:` line). A bare `#43` is not clickable in the terminal/markdown the
digest renders into, so these helpers turn a PR number + repo slug into a proper
GitHub link. Pure string formatting — no network, no `gh` — so the shell layer
can stamp a `pr_url` onto each acted-on PR's JSON and the SKILL can render the
markdown link in its report.

`repo` is GitHub's `nameWithOwner` slug (e.g. `owner/name`), exactly what
`detect_repo` (common.sh → `gh repo view --json nameWithOwner`) returns.
"""


def pr_url(number: "int | str", repo: str) -> str:
    """The canonical web URL for a PR: https://github.com/<repo>/pull/<number>.

    `number` may be an int or a numeric string. Raises ValueError on a missing
    repo or a non-numeric number rather than emitting a broken link.
    """
    repo = (repo or "").strip().strip("/")
    if not repo:
        raise ValueError("repo (owner/name) is required to build a PR URL")
    n = str(number).lstrip("#").strip()
    if not n.isdigit():
        raise ValueError(f"PR number must be numeric, got {number!r}")
    return f"https://github.com/{repo}/pull/{n}"


def pr_link(number: "int | str", repo: str) -> str:
    """A markdown link for a PR: `[#<number>](<url>)`.

    This is what the digest prints so `#43` renders as a clickable GitHub link
    instead of bare text.
    """
    n = str(number).lstrip("#").strip()
    return f"[#{n}]({pr_url(n, repo)})"
