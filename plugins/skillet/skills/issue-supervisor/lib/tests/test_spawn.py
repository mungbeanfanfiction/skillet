from supervisorlib import spawn


def test_build_argv_has_print_and_permission_flags():
    argv = spawn.build_argv(prompt="do the thing", worktree="/wt/1")
    assert argv[0] == "claude"
    assert argv[argv.index("-p") + 1] == "do the thing"
    assert argv[argv.index("--permission-mode") + 1] == "acceptEdits"
    assert argv[argv.index("--add-dir") + 1] == "/wt/1"


def test_dispatch_prompt_references_task_md_review_fix_and_escape_hatch():
    p = spawn.dispatch_prompt(issue=489)
    assert "489" in p
    assert ".claude/task.md" in p
    assert "review-fix" in p
    assert "question.md" in p


def test_restart_prompt_says_resume_from_stage():
    p = spawn.restart_prompt(issue=489)
    assert "resume" in p.lower()
    assert ".claude/task.md" in p


def test_resume_prompt_mentions_the_answer():
    p = spawn.resume_prompt(issue=489)
    assert "answer" in p.lower()
    assert "489" in p
