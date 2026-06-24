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


def test_dispatch_prompt_routes_explore_issues_to_explore_skill():
    # routing preamble ships in every prompt so `explore`-labeled tasks divert to /explore-issue.
    p = spawn.dispatch_prompt(issue=489)
    assert "explore-issue" in p
    assert "explore" in p.lower()


def test_restart_and_resume_prompts_also_carry_explore_routing():
    # a restarted/resumed explore session must still route correctly.
    assert "explore-issue" in spawn.restart_prompt(issue=1)
    assert "explore-issue" in spawn.resume_prompt(issue=1)


def test_restart_prompt_says_resume_from_stage():
    p = spawn.restart_prompt(issue=489)
    assert "resume" in p.lower()
    assert ".claude/task.md" in p


def test_resume_prompt_mentions_the_answer():
    p = spawn.resume_prompt(issue=489)
    assert "answer" in p.lower()
    assert "489" in p
