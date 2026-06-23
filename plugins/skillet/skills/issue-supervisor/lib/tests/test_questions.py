from supervisorlib import questions

UNANSWERED = """# Question — issue #5
Should clubs be public?

## Options
1. public — simpler
2. gated — safer (recommended)

## Context
working on issue 5

## Answer
<!-- empty until the user fills it -->
"""

ANSWERED = UNANSWERED.replace("<!-- empty until the user fills it -->", "go with gated")


def test_is_answered_false_for_placeholder(tmp_path):
    f = tmp_path / "5.md"; f.write_text(UNANSWERED)
    assert questions.is_answered(f) is False


def test_is_answered_true_when_filled(tmp_path):
    f = tmp_path / "5.md"; f.write_text(ANSWERED)
    assert questions.is_answered(f) is True


def test_extract_answer_returns_text(tmp_path):
    f = tmp_path / "5.md"; f.write_text(ANSWERED)
    assert questions.extract_answer(f) == "go with gated"


def test_question_body_strips_answer_section(tmp_path):
    f = tmp_path / "5.md"; f.write_text(UNANSWERED)
    body = questions.question_body(f)
    assert "Should clubs be public?" in body
    assert "Answer" not in body
