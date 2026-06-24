"""Markdown-checklist queue parser. Unchecked `- [ ]` / `* [ ]` lines (any
indent) become tasks, in document order. File tasks skip GitHub-issue-specific
machinery (assignment, decomposition, issue comments)."""
import re
from pathlib import Path

_UNCHECKED = re.compile(r"^\s*[-*]\s+\[ \]\s+(.*\S)\s*$")
_NONWORD = re.compile(r"[^a-z0-9]+")


def unchecked_items(path) -> list:
    out = []
    for line in Path(path).read_text().splitlines():
        m = _UNCHECKED.match(line)
        if m:
            out.append(m.group(1))
    return out


def slug(text: str) -> str:
    s = _NONWORD.sub("-", text.lower()).strip("-")
    return s
