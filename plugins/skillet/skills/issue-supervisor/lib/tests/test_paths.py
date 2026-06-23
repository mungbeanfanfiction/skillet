from pathlib import Path
from supervisorlib import paths


def test_state_dir_is_under_repo_claude(tmp_path):
    assert paths.state_dir(repo_root=tmp_path) == tmp_path / ".claude" / "issue-supervisor"


def test_registry_path_lives_in_state_dir(tmp_path):
    assert paths.registry_path(repo_root=tmp_path) == (
        tmp_path / ".claude" / "issue-supervisor" / "registry.json"
    )


def test_worktrees_dir_is_repo_claude_worktrees(tmp_path):
    assert paths.worktrees_dir(repo_root=tmp_path) == tmp_path / ".claude" / "worktrees"


def test_lock_path_names_the_loop(tmp_path):
    assert paths.lock_path(repo_root=tmp_path, loop="supervisor").name == "supervisor.lock"
    assert paths.lock_path(repo_root=tmp_path, loop="sweeper").name == "sweeper.lock"


def test_ensure_state_dir_creates_it(tmp_path):
    d = paths.ensure_state_dir(repo_root=tmp_path)
    assert d.is_dir()
    assert d == tmp_path / ".claude" / "issue-supervisor"
