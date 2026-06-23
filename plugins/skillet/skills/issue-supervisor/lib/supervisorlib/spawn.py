"""Build the claude spawn argv + the prompts a dispatched/restarted/resumed
session runs. The per-issue pipeline reuses skillet's `review-fix` skill for
the review/auto-fix loop instead of calling /code-review directly."""

PIPELINE = """\
Run this pipeline for the task, logging each completed stage to the
`## Pipeline stage` section of `.claude/task.md`:
1. pickup — read `.claude/task.md` + any existing diff.
2. triage — confirm the work is actionable as scoped. Minor ambiguity: make a
   DOCUMENTED best guess and note the assumption. If it is a genuine DESIGN
   question (API shape, product behavior, irreversible/ambiguous choice) use the
   escape hatch below. If there is no safe guess and it is not a design question,
   stop and write the reason to the `## Progress log`.
3. work — implement the change.
4. review — run the `review-fix` skill on the working changes (it loops
   /code-review + auto-fixes high/medium findings, cap 3 rounds). If it leaves
   unsafe findings, they become PR comments; if it cannot get clean, stop and
   summarize in the progress log — do NOT open a PR.
5. ci — detect and run the repo's check command (try in order: `make ci`,
   `make agent-ci`, `npm test`/`npm run test`, `pytest`, or a check documented in
   CLAUDE.md/README; if none, record "no check command found" and proceed). It
   must pass; fix and re-run, or stop and report if un-greenable.
6. open a DRAFT PR with the `open-pr` skill, then write `done` under
   `## Pipeline stage`.

DESIGN-QUESTION ESCAPE HATCH (any stage): if you need a decision only the user
can make, write `.claude/question.md` (the question, 2-4 options with your
recommendation, context) and EXIT cleanly. Do not guess on design questions.
Never merge, never push to the base branch, never run git
restore/checkout/clean/reset.
"""


def build_argv(*, prompt: str, worktree: str) -> list:
    return ["claude", "-p", prompt,
            "--permission-mode", "acceptEdits", "--add-dir", worktree]


def dispatch_prompt(*, issue) -> str:
    return f"You are working task #{issue} in this worktree.\n\n{PIPELINE}"


def restart_prompt(*, issue) -> str:
    return (
        f"You are resuming task #{issue} in this worktree. Read `.claude/task.md` "
        f"and the working diff, then resume the pipeline from the last completed "
        f"stage under `## Pipeline stage`.\n\n{PIPELINE}"
    )


def resume_prompt(*, issue) -> str:
    return (
        f"You are resuming task #{issue} after the user ANSWERED your design "
        f"question. Read the latest `## Progress log` entry in `.claude/task.md` "
        f"for the answer, then continue the pipeline from where you parked.\n\n"
        f"{PIPELINE}"
    )
