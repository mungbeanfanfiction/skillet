from supervisorlib import signals


def test_write_then_pending_roundtrip(tmp_path):
    signals.write(tmp_path, path="/wt/a", issue=1, created_at="2026-06-25T00:00:00Z")
    got = signals.pending(tmp_path)
    assert got == [{"path": "/wt/a", "issue": 1, "created_at": "2026-06-25T00:00:00Z"}]


def test_pending_empty_when_no_dir(tmp_path):
    assert signals.pending(tmp_path) == []


def test_write_is_idempotent_per_worktree(tmp_path):
    signals.write(tmp_path, path="/wt/a", issue=1, created_at="2026-06-25T00:00:00Z")
    signals.write(tmp_path, path="/wt/a", issue=1, created_at="2026-06-25T01:00:00Z")
    got = signals.pending(tmp_path)
    assert len(got) == 1
    # The later write wins (sentinel overwritten in place).
    assert got[0]["created_at"] == "2026-06-25T01:00:00Z"


def test_distinct_worktrees_get_distinct_sentinels(tmp_path):
    signals.write(tmp_path, path="/wt/a", issue=1, created_at="2026-06-25T00:00:00Z")
    signals.write(tmp_path, path="/wt/b", issue=2, created_at="2026-06-25T00:00:01Z")
    assert {s["path"] for s in signals.pending(tmp_path)} == {"/wt/a", "/wt/b"}


def test_pending_sorted_oldest_first(tmp_path):
    signals.write(tmp_path, path="/wt/b", issue=2, created_at="2026-06-25T02:00:00Z")
    signals.write(tmp_path, path="/wt/a", issue=1, created_at="2026-06-25T01:00:00Z")
    assert [s["issue"] for s in signals.pending(tmp_path)] == [1, 2]


def test_clear_specific_path(tmp_path):
    signals.write(tmp_path, path="/wt/a", issue=1, created_at="2026-06-25T00:00:00Z")
    signals.write(tmp_path, path="/wt/b", issue=2, created_at="2026-06-25T00:00:01Z")
    removed = signals.clear(tmp_path, path="/wt/a")
    assert removed == 1
    assert [s["path"] for s in signals.pending(tmp_path)] == ["/wt/b"]


def test_clear_all(tmp_path):
    signals.write(tmp_path, path="/wt/a", issue=1, created_at="2026-06-25T00:00:00Z")
    signals.write(tmp_path, path="/wt/b", issue=2, created_at="2026-06-25T00:00:01Z")
    assert signals.clear(tmp_path) == 2
    assert signals.pending(tmp_path) == []


def test_clear_missing_path_is_noop(tmp_path):
    assert signals.clear(tmp_path, path="/wt/never") == 0


def test_pending_skips_corrupt_sentinel(tmp_path):
    signals.write(tmp_path, path="/wt/a", issue=1, created_at="2026-06-25T00:00:00Z")
    bad = signals.signals_dir(tmp_path) / "deadbeef.json"
    bad.write_text("{not json")
    got = signals.pending(tmp_path)
    assert [s["path"] for s in got] == ["/wt/a"]
