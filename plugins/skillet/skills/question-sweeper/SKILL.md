---
name: question-sweeper
description: Sweep worktrees for sessions parked on design questions, queue them to a local inbox + GitHub comment, and re-dispatch once the user answers. Repo-agnostic. Use when running the ~1h question-sweeper loop.
---

# question-sweeper

The light ~1h loop. Manages the design-question lifecycle only. Never dispatches
fresh work or restarts mechanical stalls.

## 0. Lock
Acquire `<repo>/.claude/issue-supervisor/sweeper.lock` (create; if it exists and is
<2h old, exit). Remove at the end.

## 1. Sweep
Run `scripts/sweep.sh`. If `{"error": ...}`, report and STOP.

## 2. Newly-raised questions (`raised` array)
For each `{issue, path}`:
- Copy `path/.claude/question.md` (body above `## Answer`) into
  `docs/superpowers/questions/<issue>.md`, keeping an empty `## Answer` section.
- Apply the label: `gh issue edit <issue> --add-label needs-input`.
- Post the question as a comment: `gh issue comment <issue> --body "<question body>"`.
  (File-source tasks have no GitHub issue — record them in the run-report instead.)
The worktree's slot is now free (survey counts `needs-input` as not-in-flight), so
the 5h loop will refill it.

## 3. Answered questions (`answered` array)
For each issue number, recompute free slots by running the supervisor's
`scripts/survey.sh` and reading `free_slots`:
- If `free_slots > 0`:
  - Append the answer to the worktree's `.claude/task.md` progress log.
  - Remove the label: `gh issue edit <issue> --remove-label needs-input`.
  - Re-dispatch with the supervisor's **`scripts/resume.sh <worktree-path> <issue>`**
    (NOT restart.sh — answering must not burn the restart budget; resume.sh also
    clears question.md).
- If `free_slots == 0`: leave answered-and-queued; report it. It re-dispatches on a
  later sweep when a slot opens.

## 4. Report + reschedule
Print: questions newly raised, awaiting answer, answers detected + re-dispatched,
answered-but-queued. Release lock. /loop reschedules ~1h.

## Hard rules
Never answer a question on the user's behalf. Never restart a mechanical stall
(that's the 5h loop). Shares the owned-worktree registry; never touches foreign
worktrees.
