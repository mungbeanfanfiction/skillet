from supervisorlib import runreport


def test_render_has_three_sections():
    md = runreport.render(
        date="2026-06-23",
        shipped=[{"title": "Fix login", "pr_url": "http://pr/1", "summary": "2 fixes"}],
        skipped=[{"title": "Vague task", "reason": "no safe guess"}],
        flagged=[{"title": "Caching", "note": "needs human review"}],
    )
    assert "# Run report — 2026-06-23" in md
    assert "## Shipped" in md and "Fix login" in md and "http://pr/1" in md
    assert "## Skipped" in md and "no safe guess" in md
    assert "## Needs your attention" in md and "Caching" in md


def test_render_empty_sections_show_none():
    md = runreport.render(date="2026-06-23", shipped=[], skipped=[], flagged=[])
    assert "_none_" in md
