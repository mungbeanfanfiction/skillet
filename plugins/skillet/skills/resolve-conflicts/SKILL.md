---
name: resolve-conflicts
description: Resolve merge conflicts on a PR (or the current branch) by bringing it up to date with its base branch. Detects the conflicting state first, auto-resolves only safe conflicts, and leaves the branch cleanly pushable — or reports clearly when a conflict needs human judgment. Standalone; also consumable by /issue-supervisor. Use when a PR is blocked by merge conflicts after the base branch moved.
argument-hint: "[pr-number]"
---

# Resolve Conflicts Skill

Bring a PR branch up to date with its base branch and resolve any merge
conflicts, leaving the branch in a clean, pushable state. **The point of this
skill is to be conservative**: it auto-resolves only mechanical, low-risk
conflicts and reports clearly whenever a conflict needs human judgment, rather
than forcing a bad resolution.

Standalone and repo-agnostic: it derives the repo and base branch from the PR
itself. It is invocable on its own and is also consumed by `/issue-supervisor`
(#36) — nothing here depends on the supervisor.

## When Invoked

Parse the argument:

- A **number** → the PR to resolve.
- **Omitted** → infer the PR from the current branch:
  ```bash
  gh pr view --json number,headRefName,baseRefName,url --jq '.number'
  ```
  If there is no PR for the current branch, stop and report that.

Resolve these fields up front and reuse them throughout (never hardcode `main`):

```bash
gh pr view <pr-number> --json number,url,state,isDraft,headRefName,baseRefName,mergeStateStatus,reviewDecision
```

- `headRefName` — the PR branch (what you operate on).
- `baseRefName` — the base branch to bring it up to date with.
- `mergeStateStatus` — the conflict signal (see below).
- `reviewDecision` — used to decide between rebase and merge.

If `state != "OPEN"`, stop: a merged/closed PR has nothing to resolve.

## Step 1 — Detect the conflicting state (required, before acting)

Never start a rebase or merge speculatively. Confirm the PR is actually
conflicting first. `mergeStateStatus` is the source of truth:

| `mergeStateStatus` | Meaning | Action |
|---|---|---|
| `DIRTY` | Merge conflicts with the base | Proceed to resolve |
| `BEHIND` | Behind base but no conflicts | Update onto base (no conflict resolution needed); push rules are identical to `DIRTY` |
| `BLOCKED` / `UNSTABLE` | Failing checks or required reviews, **not** a conflict | Report; this skill does not act |
| `CLEAN` / `HAS_HOOKS` | Mergeable | Report "no conflicts — nothing to do" and stop |
| `UNKNOWN` | GitHub hasn't computed mergeability yet | Wait briefly and re-query once; if still `UNKNOWN`, report and stop |

`mergeStateStatus` can read `UNKNOWN` immediately after the base branch moves —
GitHub computes mergeability asynchronously. Re-query once after a short pause
before concluding anything.

Only `DIRTY` (and `BEHIND`, for a no-conflict update) warrant proceeding. A
`BEHIND` branch is not special once you proceed: it goes through the same Step 3
(rebase vs merge) and the same Step 5 push rules as `DIRTY`. The only difference
is that Step 4 finds no conflicts to resolve. In particular, a `BEHIND` branch
updated by **rebase** still has rewritten commits and still needs a
`--force-with-lease` push — "behind" never means a plain `git push` will work
after a rebase.

## Step 2 — Get a local checkout of the branch

Work in a local checkout of `headRefName`. If you're already on it in a
worktree, use that. Otherwise check it out, then sync both refs:

```bash
git fetch origin   # updates origin/<base> and origin/<head> via the configured refspec
git checkout <headRefName>
git pull --ff-only origin <headRefName>   # ensure local matches remote head
```

Use a bare `git fetch origin` (not `git fetch origin <base> <head>`): the latter
populates `FETCH_HEAD` but does not reliably update the `origin/<base>`
remote-tracking ref that Step 3's `git rebase origin/<baseRefName>` depends on.

If `git pull --ff-only` fails (local and remote head have diverged), **stop and
escalate** — the local branch has commits not on the remote, and resolving
conflicts on top of that risks losing or duplicating work. This is a human
judgment call.

## Step 3 — Choose rebase vs merge

The integration strategy depends on whether the PR has an approved review:

- **No approved review** (`reviewDecision != "APPROVED"`) → **rebase** onto the
  base. Cleaner history; this is the default.
- **Has an approved review** (`reviewDecision == "APPROVED"`) → **merge** the
  base in. Rebasing rewrites history and **invalidates the existing approval**;
  a merge commit preserves it. Prefer not to cost the author a re-review.

```bash
# default (no approval): rebase
git rebase origin/<baseRefName>

# approved PR: merge base in instead
git merge --no-ff origin/<baseRefName>
```

## Step 4 — Resolve conflicts: safe vs escalate

When the rebase/merge stops on conflicts, inspect **every** conflicted file
before touching anything:

```bash
git diff --name-only --diff-filter=U
```

**Auto-resolve only if EVERY conflicted file is in the safe list below.** If
even one file falls outside it, do not cherry-pick — abort and escalate the
whole operation (see Step 6).

### Safe to auto-resolve

- **Lock files** (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`,
  `Cargo.lock`, `poetry.lock`, `Gemfile.lock`, etc.) → take the base version,
  then regenerate from the merged manifest:
  ```bash
  git checkout --theirs <lockfile>   # 'theirs' == base during rebase
  # then re-run the install so the lock reflects BOTH sides' manifest changes:
  npm install   # or yarn / pnpm install / cargo build / poetry lock — match the ecosystem
  git add <lockfile>
  ```
  **Do not stage the base lockfile as-is.** The base version does not reflect
  the PR's manifest changes — you must regenerate. After running the install,
  confirm it actually rewrote the lockfile (`git status --porcelain <lockfile>`
  should show it as modified). If the install command is a no-op, errors, or you
  can't identify the right ecosystem command, **escalate** (Step 6) rather than
  committing a stale lockfile — a lockfile that omits the PR's dependencies is a
  silently broken resolution that the Step 5 checks won't catch.
  > **Note on `--ours`/`--theirs` orientation:** during a `rebase`, *your*
  > commits are replayed **on top of** the base, so `--theirs` refers to the
  > **base** branch and `--ours` to the PR branch. During a `merge` the
  > orientation is reversed (`--ours` is the PR branch you're on, `--theirs` is
  > the base being merged in). Always confirm orientation before using either.
- **Generated files** (anything produced by a codegen/build step —
  `*.g.dart`, `*.freezed.dart`, generated clients, compiled schemas) →
  re-run the generator after resolving the inputs, then stage the result.
  Never hand-edit a generated file.
- **Import-only conflicts** — both sides *added* different imports at the top of
  a file with **no deletions and no other hunks in the file**. Take both sets of
  imports (union), de-duplicate, and stage.

### Escalate — do NOT auto-resolve

- **Any logic file**: function bodies, conditionals, class/type definitions,
  config with behavioral meaning. These need human judgment.
- **Any shared library or public-API path**.
- **More than 3 conflicted files** in total.
- **Any conflict you're not certain is mechanical** — when in doubt, escalate.
  A wrong auto-resolution is worse than an unresolved conflict.

After resolving the safe set, continue the operation — but **only if it actually
paused on conflicts**. If the rebase/merge in Step 3 completed cleanly (no
conflicts), there is nothing in progress and `--continue` will error; skip
straight to Step 5.

```bash
git rebase --continue   # or: git merge --continue
```

Repeat Step 4 for each subsequent conflicted commit a rebase surfaces.

## Step 5 — Verify and leave pushable

After the rebase/merge completes with no remaining conflicts:

1. Confirm a clean tree and no conflict markers left behind:
   ```bash
   git diff --check                       # flags leftover <<<<<<< / ======= / >>>>>>>
   git status --porcelain                 # should be empty
   ```
2. If the repo has a quick check command (`make ci`, `npm test`, `pytest` — see
   CLAUDE.md/README), run it to confirm the resolution didn't break the build.
   If it fails, **do not push** — escalate with the failure.
3. Push. **The push rule follows the strategy you chose in Step 3, not the
   `DIRTY`-vs-`BEHIND` distinction:**
   - If you **merged** (the approved-PR path) → `git push`. A merge adds a new
     commit on top of your branch, so the push fast-forwards. No force needed.
   - If you **rebased** (the default, unapproved path) → the branch's commits
     were rewritten, so the remote will reject a plain push. Use a
     **lease-guarded** force-push, never a bare `--force`:
     ```bash
     git push --force-with-lease
     ```
     `--force-with-lease` aborts if the remote moved since you fetched,
     protecting against clobbering someone else's push. If it is rejected,
     **stop and escalate** — do not retry with `--force`.

Report success with the PR URL and a one-line summary of what was resolved
(which files, rebase vs merge, whether anything was regenerated).

## Step 6 — Escalate cleanly (don't force a bad resolution)

When a conflict needs human judgment, **abort to a clean state** so you never
leave a half-resolved branch behind:

```bash
git rebase --abort    # or: git merge --abort
```

Then report clearly, including:

- The PR number/URL and its base branch.
- The list of conflicted files and **which one(s)** triggered the escalation
  (e.g. "`src/auth/session.ts` is a logic file").
- That the branch was left **untouched** (aborted), so it's safe for a human to
  pick up.

Optionally leave a note on the PR for the author:

```bash
gh pr comment <pr-number> --body "Merge conflicts with \`<baseRefName>\` need manual resolution: <files>. Auto-resolution was skipped to avoid a risky merge."
```

## Hard Rules (never violate)

- **Detect before acting.** Always confirm `mergeStateStatus == DIRTY` (or
  `BEHIND` for a no-conflict update) before starting a rebase/merge.
- **Never auto-resolve a logic file.** Lock files, generated files, and
  import-only union conflicts are the *only* safe categories.
- **Never `git push --force`.** Rebase pushes use `--force-with-lease`; if it's
  rejected, escalate.
- **Never abandon a half-resolved branch.** On escalation, always
  `git rebase/merge --abort` first.
- **Never resolve across more than 3 conflicted files** automatically — escalate.
- **Don't hardcode the base branch** — always use the PR's `baseRefName`.
- **Don't act on `BLOCKED`/`UNSTABLE`** — those are check/review failures, not
  conflicts, and out of scope here.

## Common Mistakes

- **Confusing `--ours`/`--theirs`**: the orientation flips between rebase and
  merge. Re-read the note in Step 4 every time.
- **Plain `git push` after a rebase**: rejected as non-fast-forward. Use
  `--force-with-lease`.
- **Treating `BLOCKED`/`UNSTABLE` as a conflict**: those mean failing checks or
  pending reviews, not a merge conflict. Report and stop.
- **Resolving on a diverged local branch**: if `git pull --ff-only` fails, the
  local head has commits the remote doesn't — escalate instead of resolving.
- **Hand-editing a lock file or generated file**: regenerate it from the merged
  inputs instead.
- **Acting while `mergeStateStatus == UNKNOWN`**: GitHub hasn't computed
  mergeability yet — re-query once before concluding.
