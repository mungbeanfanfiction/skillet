import pytest

from supervisorlib import links


# --- pr_url ------------------------------------------------------------------

def test_pr_url_basic():
    assert links.pr_url(42, "owner/name") == "https://github.com/owner/name/pull/42"


def test_pr_url_accepts_string_number():
    assert links.pr_url("42", "owner/name") == "https://github.com/owner/name/pull/42"


def test_pr_url_strips_leading_hash():
    assert links.pr_url("#42", "owner/name") == "https://github.com/owner/name/pull/42"


def test_pr_url_trims_repo_slashes_and_space():
    assert links.pr_url(7, " /owner/name/ ") == "https://github.com/owner/name/pull/7"


def test_pr_url_rejects_empty_repo():
    with pytest.raises(ValueError):
        links.pr_url(42, "")


def test_pr_url_rejects_non_numeric():
    with pytest.raises(ValueError):
        links.pr_url("forty-two", "owner/name")


# --- pr_link -----------------------------------------------------------------

def test_pr_link_markdown():
    assert links.pr_link(43, "owner/name") == "[#43](https://github.com/owner/name/pull/43)"


def test_pr_link_strips_leading_hash():
    assert links.pr_link("#45", "owner/name") == "[#45](https://github.com/owner/name/pull/45)"


def test_pr_link_propagates_validation_errors():
    # pr_link delegates validation to pr_url; a bad repo/number must still raise
    with pytest.raises(ValueError):
        links.pr_link(42, "")
    with pytest.raises(ValueError):
        links.pr_link("nope", "owner/name")


def test_pr_link_real_world_slug():
    # the acceptance-criteria example shape
    assert links.pr_link(42, "mungbeanfanfiction/skillet") == (
        "[#42](https://github.com/mungbeanfanfiction/skillet/pull/42)"
    )
