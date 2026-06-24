"""Parse worktree question.md and inbox <issue#>.md files.
'Answered' = the `## Answer` section contains non-placeholder text."""
from pathlib import Path

_PLACEHOLDER = "<!-- empty until the user fills it -->"
_ANSWER_HEADER = "## Answer"


def _answer_section(text: str) -> str:
    if _ANSWER_HEADER not in text:
        return ""
    return text.split(_ANSWER_HEADER, 1)[1].strip()


def is_answered(path) -> bool:
    section = _answer_section(Path(path).read_text())
    return bool(section) and _PLACEHOLDER not in section


def extract_answer(path) -> str:
    return _answer_section(Path(path).read_text())


def question_body(path) -> str:
    """Everything above `## Answer` — for the GitHub issue comment."""
    return Path(path).read_text().split(_ANSWER_HEADER, 1)[0].strip()
