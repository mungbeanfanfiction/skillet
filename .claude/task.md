# Task — issue #72
**Goal:** issue-supervisor: don't restart/stall worktrees whose PR already merged
**Source:** label
**Labels:** auto,bug,backend,p1
**Acceptance criteria:** see issue #72 body.

## Pipeline stage
open-pr

## Restart count
0

## Progress log
- dispatched
- triage: actionable. Assumptions: (a) state named MERGED; (b) only merged (not closed-unmerged) PRs are terminal — an abandoned/rejected PR keeps its old classification; (c) MERGED is checked before has_question_md, since a merged branch makes any pending question moot; (d) MERGED is not in-flight, so it frees a slot.
- work: added WorktreeState.MERGED (top of classify), pr_merged survey fact from `gh pr list --head <branch> --state merged`, cleanup_candidate in survey entry, oversize-diff suppressed for merged. Tests + SKILL.md updated. 152 lines, npm test green.
- review: 2 rounds of pr-review-toolkit:code-reviewer. Round 1: no high/medium; one LOW — a live session on a merged branch classified MERGED, freeing its slot and getting cleanup_candidate mid-run. Fixed by guarding the merged rung on `not process_alive`. Round 2: no findings at any severity.
- ci: `npm test` exit 0 (19 node + 125 pytest). survey.sh passes `bash -n`. 165 changed lines vs origin/main.
- review r3: reworked precedence after finding my own r1 fix reintroduced the bug for LIVE sessions (guarding the merged rung on `not process_alive` let it fall through to the blocking rungs, so live+merged+stale-done-marker => blocked/done_no_pr). Final order: question -> open_pr -> merged(working if alive else merged) -> blocking rungs. Reviewer brute-forced all 128 fact combos: 0 merged worktrees can be blocked/stalled; non-merged classification byte-identical to original. r3 clean (one LOW, pre-existing + out of scope: merged work shadowed by needs-input/pr-open never gets cleanup_candidate).
- ci: `npm test` exit 0 (19 node + 125 pytest); survey.sh passes `bash -n`.
