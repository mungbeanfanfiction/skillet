from supervisorlib import registry


def test_load_missing_file_returns_empty(tmp_path):
    assert registry.load(tmp_path / "registry.json") == {"worktrees": []}


def test_add_then_load_roundtrip(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=489, path="/wt/auto-489", branch="auto-489",
                 source="label", created_at="2026-06-23T10:00:00Z")
    reg = registry.load(p)
    assert reg["worktrees"][0]["issue"] == 489
    assert reg["worktrees"][0]["source"] == "label"


def test_is_owned_true_for_registered_path(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=1, path="/wt/a", branch="a", source="label", created_at="t")
    assert registry.is_owned(p, "/wt/a") is True
    assert registry.is_owned(p, "/wt/other") is False


def test_remove_by_path(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=1, path="/wt/a", branch="a", source="label", created_at="t")
    registry.remove(p, "/wt/a")
    assert registry.load(p) == {"worktrees": []}


def test_issues_lists_registered_numbers(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=1, path="/wt/a", branch="a", source="label", created_at="t")
    registry.add(p, issue=2, path="/wt/b", branch="b", source="file", created_at="t")
    assert sorted(registry.issues(p)) == [1, 2]


def test_issue_for_path_returns_number_or_none(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=7, path="/wt/a", branch="a", source="label", created_at="t")
    assert registry.issue_for_path(p, "/wt/a") == 7
    assert registry.issue_for_path(p, "/wt/missing") is None


def test_add_is_atomic_no_partial_file(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=1, path="/wt/a", branch="a", source="label", created_at="t")
    assert p.exists()
    assert not (tmp_path / "registry.json.tmp").exists()
