"""Owned-worktree registry. The only persisted supervisor state.
Writes are atomic (temp file + rename) so a crash never corrupts it."""
import json
import os
from pathlib import Path


def load(registry_path) -> dict:
    p = Path(registry_path)
    if not p.exists():
        return {"worktrees": []}
    return json.loads(p.read_text())


def _save(registry_path, data: dict) -> None:
    p = Path(registry_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(tmp, p)


def add(registry_path, *, issue, path, branch, source, created_at) -> None:
    data = load(registry_path)
    data["worktrees"].append({
        "issue": issue, "path": path, "branch": branch,
        "source": source, "created_at": created_at,
    })
    _save(registry_path, data)


def remove(registry_path, path: str) -> None:
    data = load(registry_path)
    data["worktrees"] = [w for w in data["worktrees"] if w["path"] != path]
    _save(registry_path, data)


def is_owned(registry_path, path: str) -> bool:
    return any(w["path"] == path for w in load(registry_path)["worktrees"])


def issues(registry_path) -> list:
    return [w["issue"] for w in load(registry_path)["worktrees"]]


def issue_for_path(registry_path, path: str):
    return next((w["issue"] for w in load(registry_path)["worktrees"]
                 if w["path"] == path), None)
