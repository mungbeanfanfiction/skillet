---
name: commit
description: Create a git commit with a slop review first. Stages the change, runs /check-slop on the staged diff by default (opt out with --no-slop-check), offers to fix what it finds, then writes a Conventional Commit message matching the repo's history. Refuses to commit on main/master/trunk. Never pushes. Use when asked to commit changes.
argument-hint: "[-m \"message\"] [--no-slop-check] [--noninteractive]"
model: sonnet
---

# Commit

Commit the current work, after checking it for duplication and missed reuse.
The slop check runs every time unless the caller opts out. It's cheaper to
catch a duplicated helper before it's committed than to find it in review.

## When invoked

- **`-m "message"`** -- use this subject (and body, if given) instead of
  drafting one. Still check it against the repo's commit style.
- **`--no-slop-check`** -- skip step 3. Use for commits with nothing to review:
  a release bump, a revert, a lockfile update, a merge.
- **`--noninteractive`** -- for callers like `/issue-supervisor`. Never prompt.
  Run the slop check, include its findings in the output, and commit anyway.
  Don't apply `--fix` unattended.

## Workflow

### 1. Check the branch

```bash
git symbolic-ref --quiet --short HEAD
```

If it's `main`, `master`, or `trunk`, stop and suggest `/create-worktree`. The
`block-commit-on-main` hook denies it anyway.

### 2. Stage

If something is already staged, commit exactly that. Don't add more.

If nothing is staged, read `git status --porcelain` and stage the changes that
belong to this work. Leave out anything that looks like a secret (`.env*`,
`*.pem`, `*.key`, credential files), build output, or scratch files, and say
what you left out. Stage by path, not `git add -A`.

If there's nothing to commit, say so and stop.

### 3. Slop check

Unless `--no-slop-check` was passed, run `/check-slop --staged --json`.

- **Clean:** continue.
- **Findings, interactive:** show the human summary and ask: fix them, commit
  anyway, or stop. To fix, run `/check-slop --staged --fix` for the drop-ins and
  make the rest by hand, re-stage the touched files, and run the check once
  more. Don't loop past that; commit or stop on the user's call.
- **Findings, `--noninteractive`:** keep the summary for step 6 and continue.

The staged diff may also hold comments or debug logs worth trimming. That's
`/check-verbosity`'s job at PR time; don't run it here.

### 4. Write the message

Read `git log --oneline -15` and match the repo's style. Default to
[Conventional Commits](https://www.conventionalcommits.org/):
`type(scope): subject`, with `feat`, `fix`, `refactor`, `test`, `docs`, `chore`,
`style`, or `perf`. In repos that release with semantic-release, the type
decides the version bump, so pick it on purpose: `feat` for new behavior,
`fix` for a bug, `chore`/`refactor` for neither.

- Subject: imperative, lowercase after the colon, no trailing period, under ~70
  characters. Say what the change does.
- Body: only when the why isn't obvious from the subject. A few lines, wrapped
  at 72. Follow `/deslop`.
- Reference an issue (`#123`) if the branch or conversation names one.
- Keep any trailers the environment asks for.

### 5. Commit

```bash
git commit -F - <<'EOF'
<subject>

<body>
EOF
```

If a pre-commit hook fails, fix what it reports, re-stage, and commit again.
Don't pass `--no-verify` and don't `--amend` a commit that's already made.

### 6. Report

One line for the commit, one for the slop check:

```
Committed a1b2c3d feat(orders): add refund endpoint
Slop check: clean
```

With open findings (from "commit anyway" or `--noninteractive`):

```
Committed a1b2c3d feat(orders): add refund endpoint
Slop check: 2 open -- src/orders/format.py:9 dup of src/money.py:40; tests/test_orders.py:14 use `user` fixture
```

## Do not

- Don't push.
- Don't commit on the default branch.
- Don't skip the slop check unless `--no-slop-check` was passed.
- Don't amend, rebase, or rewrite existing commits.
