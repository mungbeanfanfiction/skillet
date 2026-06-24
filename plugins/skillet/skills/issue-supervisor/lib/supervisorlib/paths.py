"""Resolve runtime-state paths in the TARGET repo's .claude/ dir.

The plugin install dir is code-only and treated read-only; all mutable
supervisor state lives under <repo_root>/.claude/issue-supervisor/. Callers
pass repo_root (from `git rev-parse --show-toplevel`) so these stay pure."""
from pathlib import Path

_SUBDIR = "issue-supervisor"


def state_dir(*, repo_root) -> Path:
    return Path(repo_root) / ".claude" / _SUBDIR


def registry_path(*, repo_root) -> Path:
    return state_dir(repo_root=repo_root) / "registry.json"


def worktrees_dir(*, repo_root) -> Path:
    return Path(repo_root) / ".claude" / "worktrees"


def lock_path(*, repo_root, loop: str) -> Path:
    return state_dir(repo_root=repo_root) / f"{loop}.lock"


def ensure_state_dir(*, repo_root) -> Path:
    d = state_dir(repo_root=repo_root)
    d.mkdir(parents=True, exist_ok=True)
    return d
