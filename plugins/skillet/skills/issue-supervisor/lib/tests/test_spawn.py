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


def test_dispatch_prompt_tells_sessions_to_put_imports_at_file_tops():
    # dispatched sessions must place imports at the top of the file, not inside
    # functions; a would-be circular import is a signal to extract shared code
    # into a separate module rather than hide the import in a function.
    p = spawn.dispatch_prompt(issue=1)
    low = p.lower()
    assert "import" in low
    assert "top of its file" in low  # unique to the directive ("stop" also has "top")
    assert "circular" in low
    # restarted/resumed sessions carry the same guidance (they reuse PIPELINE).
    assert "circular" in spawn.restart_prompt(issue=1).lower()
    assert "circular" in spawn.resume_prompt(issue=1).lower()


def test_ci_step_prefers_agent_ci_before_plain_ci():
    # A repo's `agent-ci`/`agent-test` target is the lighter, quieter CI path meant
    # for automated runs; the session must try it BEFORE the heavier `make ci`, which
    # often shells out to a full-core `pytest -n auto` and helps peg the machine.
    p = spawn.dispatch_prompt(issue=1)
    assert "make agent-ci" in p
    assert p.index("make agent-ci") < p.index("make ci")


def test_ci_step_caps_fix_and_rerun_at_3_rounds():
    # An un-greenable suite must not re-run forever: the CI stage caps fixing at 3
    # rounds (like the review stage) then stops and reports, rather than looping the
    # full — often multi-worker — test run without bound and burning CPU.
    p = spawn.dispatch_prompt(issue=1)
    ci = p[p.index("5. ci"):p.index("6.")]
    assert "3 rounds" in ci
    low = ci.lower()
    assert "stop" in low
    assert "do not open a pr" in low


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


def test_pr_address_prompt_escalates_conflicts_via_question_md_and_marker():
    # An unclean (non-auto-resolvable) conflict must reach the user, not dead-end
    # in the progress log: the session writes question.md (→ sweeper/inbox/GH
    # comment) AND emits the CONFLICT-ESCALATED marker the survey scans for.
    p = spawn.pr_address_prompt(issue=489, pr=42, reasons="conflict")
    assert "CONFLICT-ESCALATED" in p
    assert "question.md" in p
    assert "needs-input" in p


def test_pr_address_prompt_does_not_open_a_new_pr_or_touch_base():
    p = spawn.pr_address_prompt(issue=1, pr=2, reasons="comments")
    # this is follow-up on an EXISTING PR — it must not open another or restart the pipeline
    assert "Do NOT open a new PR" in p
    assert "never push to the base branch" in p
    # the design-question escape hatch is preserved for follow-up work too
    assert "question.md" in p


ALL_PROMPTS = [
    spawn.dispatch_prompt(issue=1),
    spawn.restart_prompt(issue=1),
    spawn.resume_prompt(issue=1),
    spawn.pr_address_prompt(issue=1, pr=2, reasons="comments,conflict"),
]


def test_every_prompt_that_asks_for_question_md_explains_how_to_write_it():
    # #82: Edit/Write are gated on `.claude/**` and the gate can't be approved in a
    # headless session. A prompt that asks for question.md without naming the Bash
    # path invites the session to conclude the escape hatch is unavailable and
    # escalate via a PR comment, which nothing in the supervisor reads.
    for p in ALL_PROMPTS:
        assert "question.md" in p
        assert "write-runtime-state.sh" in p
        assert "Bash" in p


def test_prompts_forbid_the_pr_comment_escalation_fallback():
    assert "NOT an acceptable substitute" in spawn.pr_address_prompt(
        issue=1, pr=2, reasons="conflict")
    for p in ALL_PROMPTS:
        assert "NEVER fall back to a PR comment" in p


def test_pipeline_keeps_its_literal_awk_braces():
    # RUNTIME_STATE_RULE is concatenated onto PIPELINE, never `.format()`-ed into it:
    # the size-check snippet contains `END{print s+0}`, which format() would eat.
    assert "END{print s+0}" in spawn.PIPELINE
