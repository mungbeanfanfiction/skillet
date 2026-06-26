"""Build the claude spawn argv + the prompts a dispatched/restarted/resumed
session runs. The per-issue pipeline reuses skillet's `review-fix` skill for
the review/auto-fix loop instead of calling /code-review directly."""

PIPELINE = """\
ROUTING (do this first): read the `**Labels:**` line in `.claude/task.md`. If it
includes `explore`, this is an investigation, not an implementation — run the
`explore-issue` skill for this issue number (it creates its own findings spec,
opens a draft PR, and comments on the issue), then write `done` under
`## Pipeline stage` and STOP. Do NOT run the implement pipeline below. Otherwise,
run the implement pipeline:

Run this pipeline for the task, logging each completed stage to the
`## Pipeline stage` section of `.claude/task.md`:
1. pickup — read `.claude/task.md` + any existing diff.
2. triage — confirm the work is actionable as scoped. Minor ambiguity: make a
   DOCUMENTED best guess and note the assumption. If it is a genuine DESIGN
   question (API shape, product behavior, irreversible/ambiguous choice) use the
   escape hatch below. If there is no safe guess and it is not a design question,
   stop and write the reason to the `## Progress log`.
3. work — implement the change. Keep the changeset SMALL: a single PR must change
   no more than 400 lines (added + deleted) vs the base branch. Check your size as
   you go with `git diff --numstat origin/<base>...HEAD -- . ':(exclude)**/*.lock' ':(exclude)**/*.freezed.dart' ':(exclude)**/*.g.dart' | awk '$1!="-"&&$2!="-"{s+=$1+$2}END{print s+0}'`
   (same excludes open-pr's gate uses, so your self-check matches the number that blocks you).
   If the work cannot fit under 400 lines, split it into separate, logically
   focused PRs (e.g. data model, then API, then UI; or refactor separately from
   new behavior) — land the smallest/most-foundational chunk first and follow up
   with the rest, rather than shipping one oversized PR. The `open-pr` skill
   HARD-BLOCKS PRs over 400 lines, so plan for this up front.
4. review — review the working diff with a cap of 3 rounds. Each round: dispatch
   the `pr-review-toolkit:code-reviewer` SUBAGENT (via the Agent/Task tool — a
   headless `claude -p` session CANNOT invoke the `/code-review` slash command, so
   do NOT try; use the subagent), pointing it at your uncommitted changes
   (`git diff`). Apply fixes for the high/medium findings it reports, then re-run.
   Exit when a round returns no high/medium findings, or after 3 rounds. If it is
   still not clean after 3 rounds, stop and summarize the outstanding findings in
   the progress log — do NOT open a PR.
5. ci — detect and run the repo's check command (try in order: `make ci`,
   `make agent-ci`, `npm test`/`npm run test`, `pytest`, or a check documented in
   CLAUDE.md/README; if none, record "no check command found" and proceed). It
   must pass; fix and re-run, or stop and report if un-greenable.
6. open a DRAFT PR with the `open-pr` skill, then write `done` under
   `## Pipeline stage`.
7. notify — as the LAST step, signal the supervisor that this slot is now free so
   it can refill promptly instead of waiting for the next ~5h poll. Run the
   plugin's `issue-supervisor/scripts/notify-completion.sh` (best-effort; append
   `|| true`). Do this whenever the session ends a slot — after opening the PR in
   step 6, AND on any clean early EXIT that frees the slot (skip-and-log, or the
   design-question escape hatch below). It is safe to call more than once.

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


# PR-watch follow-up. Reuses the same detached-session mechanism as dispatch:
# the supervisor spawns this prompt INTO the PR's existing worktree (the branch is
# already checked out there) when a PR has new comments and/or a fresh conflict.
# `reasons` is a comma-separated subset of {comments, conflict}.
def pr_address_prompt(*, issue, pr, reasons: str) -> str:
    return f"""You are addressing follow-up on PR #{pr} (task #{issue}) in its \
existing worktree. The branch is already checked out here. Signals to handle: \
{reasons}.

Handle EACH listed signal, then STOP — do not re-run the full implement pipeline:

- If `comments` is listed: run the `check-pr-comments` skill for PR #{pr} to see \
the unaddressed feedback, then address it in this worktree — make the requested \
code changes and/or reply to the threads as appropriate, commit, and push to \
this PR's branch. Reply to or resolve threads you've handled so they aren't \
resurfaced next pass.
- If `conflict` is listed: run the `resolve-conflicts` skill for PR #{pr}. It \
detects the conflict state, conservatively resolves only safe (mechanical) \
conflicts, and pushes — or reports clearly when a conflict needs human judgment. \
If it escalates, leave the branch untouched and note it in `.claude/task.md`'s \
`## Progress log`; do NOT force a risky resolution.

After handling the signals, append a one-line note to the `## Progress log` in \
`.claude/task.md` describing what you did, and STOP. Do NOT open a new PR (this \
PR already exists), do NOT change `## Pipeline stage`, never merge, never push to \
the base branch, never run git restore/checkout/clean/reset.

DESIGN-QUESTION ESCAPE HATCH: if addressing the feedback needs a decision only \
the user can make, write `.claude/question.md` (the question, 2-4 options with \
your recommendation, context) and EXIT cleanly. Do not guess on design questions."""
