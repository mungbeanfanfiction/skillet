---
name: review-fix
description: Review a PR with /code-review and automatically fix high and medium severity findings without asking, looping until clean. Unsafe-to-automate findings are posted as inline PR comments instead. Use to auto-improve a PR unattended.
argument-hint: "[pr-number] [effort]"
---

# Review-Fix Skill

Run code review on a PR and automatically apply fixes for serious findings
without requiring authorization, so the PR is iterated on and improved before a
human looks at it.

This skill never prompts for permission on the fixes it applies — that is the
point. Nothing is silently dropped: every finding is fixed, commented, or
logged.

## When Invoked

Parse the arguments:

- A **number** → the PR to review. If omitted, infer the PR from the current
  branch:
  ```bash
  gh pr view --json number,headRefName,url --jq '.number'
  ```
  If there is no PR for the current branch, stop and report that.
- An **effort** word (`low` / `medium` / `high` / `max`) → code-review effort.
  Default `medium` (fewer, high-confidence findings — best for unattended runs).
  Never use `ultra` here: it is billed and user-triggered and cannot be
  auto-launched from a skill.

Work from the worktree/branch that the PR was opened from.

## Workflow

### The review/fix loop

Repeat for at most **3 rounds**:

#### 1. Review

Run code review against the PR, scoped to that PR's diff:

```bash
/code-review medium <pr-number>
```

(Use the provided effort word in place of `medium` if one was passed.)

Collect the findings with their severities.

#### 2. Partition findings by severity

- **High + Medium** → fix candidates.
- **Low** → log only; never auto-fix.

#### 3. Triage each fix candidate

For each high/medium finding, decide whether it is **safe to auto-fix**:

- **Safe** — clear, mechanical, behavior-preserving (e.g. a missing null
  guard, an obvious off-by-one, dead code, a typo'd identifier). Apply the fix
  to the working tree.
- **Unsafe** — needs a judgment call or could change behavior (e.g. "this
  caching strategy may be wrong", an API contract change, anything ambiguous).
  Do **not** modify code. Post the finding as an inline PR comment for the
  human:
  ```bash
  /code-review medium <pr-number> --comment
  ```
  or post a targeted comment via `gh pr comment <pr-number> --body "..."`.
  Record it in the summary.

#### 4. Commit and push applied fixes

If any fixes were applied this round:

```bash
git add -A
git commit -m "fix: address code-review findings (round N)"
git push
```

Then continue to the next round (this catches issues the fixes introduced).

#### 5. Stop condition

Stop when a round produces **no new high/medium findings**, or after the **3rd
round**, whichever comes first.

## Report

Output a short summary:

- Rounds run.
- Fixes applied (brief description each).
- Findings posted as PR comments for human review (the unsafe pile).
- Low-severity findings logged.
