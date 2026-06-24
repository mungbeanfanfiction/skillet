from supervisorlib import queue_source

CHECKLIST = """# Tasks
- [ ] First task
- [x] Already done task
- [ ] Second task with `code`
  - [ ] nested unchecked (still a task)
not a task line
* [ ] alt-bullet task
"""


def test_unchecked_items_parsed_in_order(tmp_path):
    f = tmp_path / "queue.md"; f.write_text(CHECKLIST)
    items = queue_source.unchecked_items(f)
    assert items == [
        "First task",
        "Second task with `code`",
        "nested unchecked (still a task)",
        "alt-bullet task",
    ]


def test_checked_items_excluded(tmp_path):
    f = tmp_path / "queue.md"; f.write_text(CHECKLIST)
    assert "Already done task" not in queue_source.unchecked_items(f)


def test_empty_file_yields_no_items(tmp_path):
    f = tmp_path / "queue.md"; f.write_text("# Nothing here\n")
    assert queue_source.unchecked_items(f) == []


def test_slug_for_item_is_filesystem_safe():
    assert queue_source.slug("Fix the Login Button!") == "fix-the-login-button"
    assert queue_source.slug("a/b\\c:d") == "a-b-c-d"
