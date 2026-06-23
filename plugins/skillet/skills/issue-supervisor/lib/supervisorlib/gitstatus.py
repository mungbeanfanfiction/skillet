"""Pure parsers for git output. Subprocess calls live in the shell layer;
these take already-captured stdout so they are unit-testable."""


def classify_porcelain(porcelain: str) -> str:
    """`git status --porcelain` output → 'clean' | 'uncommitted'."""
    return "clean" if porcelain.strip() == "" else "uncommitted"


def ahead_count(rev_list_count: str) -> int:
    """`git rev-list --count @{u}..HEAD` output → int (0 if empty/no upstream)."""
    s = rev_list_count.strip()
    return int(s) if s.isdigit() else 0
