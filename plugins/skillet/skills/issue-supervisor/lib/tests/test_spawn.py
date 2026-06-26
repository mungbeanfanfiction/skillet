from supervisorlib import spawn


def test_build_argv_has_print_and_permission_flags():
    argv = spawn.build_argv(prompt="do the thing", worktree="/wt/1")
    assert argv[0] == "claude"
    assert argv[argv.index("-p") + 1] == "do the thing"
    assert argv[argv.index("--permission-mode") + 1] == "acceptEdits"
    assert argv[argv.index("--add-dir") + 1] == "/wt/1"


def test_dispatch_prompt_references_task_md_and_escape_hatch():
    p = spawn.dispatch_prompt(issue=489)
    assert "489" in p
    assert ".claude/task.md" in p
    assert "question.md" in p


def test_review_step_uses_a_subagent_not_a_slash_command():
    # A headless `claude -p` session CANNOT invoke slash commands (/code-review),
    # so the review step must dispatch the code-reviewer SUBAGENT (Agent/Task tool,
    # which headless sessions can use) instead of "run the review-fix skill".
    p = spawn.dispatch_prompt(issue=1)
    assert "code-reviewer" in p           # the dispatchable subagent
    assert "subagent" in p.lower()
    # the OLD broken mechanism must be gone: don't tell the session to run the
    # review-fix skill (which itself invokes the /code-review slash command).
    assert "review-fix" not in p


def test_dispatch_prompt_carries_the_400_line_pr_constraint():
    # every dispatched session must be told to keep each PR under 400 lines and to
    # split larger work — open-pr hard-blocks oversized PRs, so the agent has to
    # plan for it up front.
    p = spawn.dispatch_prompt(issue=1)
    assert "400" in p
    assert "split" in p.lower()


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


def test_pr_address_prompt_names_the_two_subskills_and_signals():
    p = spawn.pr_address_prompt(issue=489, pr=42, reasons="comments,conflict")
    # consumes BOTH sub-skills by name (#34 resolve-conflicts, #35 check-pr-comments)
    assert "check-pr-comments" in p
    assert "resolve-conflicts" in p
    # carries the PR + issue identity and the signals to handle
    assert "42" in p
    assert "489" in p
    assert "comments,conflict" in p


def test_pr_address_prompt_does_not_open_a_new_pr_or_touch_base():
    p = spawn.pr_address_prompt(issue=1, pr=2, reasons="comments")
    # this is follow-up on an EXISTING PR — it must not open another or restart the pipeline
    assert "Do NOT open a new PR" in p
    assert "never push to the base branch" in p
    # the design-question escape hatch is preserved for follow-up work too
    assert "question.md" in p
