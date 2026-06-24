---
name: pr-fleet-manager
description: Monitor, triage, and autonomously manage your open GitHub pull requests in the current repo — checking CI status, retrying flaky checks, surfacing review comments, rebasing safe conflicts, and printing a status digest. Does NOT auto-merge PRs or apply review suggestions. Use to run the PR-watching loop.
argument-hint: ""
---

# PR Fleet Manager

Autonomous loop that watches every open PR you authored in the **current repo**,
takes safe mechanical actions, and surfaces everything else for human judgment.
**Always start in observation mode for at least one cycle before taking any action.**

Repo-agnostic and single-repo: it derives the repo from the current checkout
(`gh repo view`) and watches PRs you authored there. No cross-org search, no
Slack — the digest prints to the terminal.

## Launch Sequence (Required)

```
1. Get GitHub username from `gh auth status` (look for "Logged in to github.com account <username>")
2. List open PRs you authored: gh pr list --author <username> --state open --json number,title,isDraft,labels,createdAt
3. Run ONE observation cycle — report what you WOULD do, but don't act
4. Ask approval for all action categories — always show all of them, regardless of current state (permissions apply to future cycles too)
5. Ask the user how frequently they'd like the loop to run (suggest 10m as default) using AskUserQuestion with options: 5 minutes, 10 minutes, 30 minutes, 1 hour, custom
6. Start the loop using the `loop` skill: `/loop <interval> /pr-fleet-manager`
```

Never skip step 3. It calibrates your judgment before you act on their behalf.

**Observation cycle approval prompt** — always show all categories using `AskUserQuestion` with `multiSelect: true`:

```
question: "Which autonomous actions should I enable for this session?"
header: "Approve actions"
multiSelect: true
options:
  - label: "CI retry"
    description: "Retry once when a failure looks infra-related (ETIMEDOUT, rate limit, timed out, etc.)"
  - label: "Rebase"
    description: "Rebase when dirty and all conflicted files are safe (lock files, generated files, import-only)"
```

**CRITICAL:** Use the GitHub username (login) from `gh auth status`, NOT email or display name. They are different — `gh auth status` shows both; always use the account login, not the email.

## Scope Rule

**Default: open PRs where you are the author, in the current repo.**
- Exclude: PRs with "do not merge" / "wip" label, PRs you've already touched in the last 30 min
- Ask before monitoring: PRs where you are reviewer (not author)

**Draft PRs — monitor CI only:**
- **Include** draft PRs in scope for CI failure detection — report any failing CI check in "Needs Your Attention"
- **Exclude** draft PRs from: review wait tracking, rebase, review comment surfacing
- In the digest, label draft PR entries with `[draft]` so they're visually distinct

## Tool Strategy

| Task | Tool |
|------|------|
| Get GitHub username | `gh auth status` → extract "Logged in to github.com account <username>" |
| Identify the repo | `gh repo view --json nameWithOwner --jq .nameWithOwner` |
| List your open PRs | `gh pr list --author <username> --state open --json number,title,isDraft,labels,createdAt` |
| Check PR status, merge status, review wait | `gh pr view <number> --json state,mergedAt,mergeStateStatus,reviewDecision,statusCheckRollup,createdAt,reviewRequests,latestReviews` |
| CI check details and logs | `gh run view --log-failed` |
| Retry a check | `gh run rerun <run-id> --failed` |
| Fetch review comments | `gh api repos/<owner>/<repo>/pulls/<number>/comments --jq '[.[] | {author: .user.login, body: .body, path: .path, line: .original_line}]'` |
| Rebase | `git fetch origin <base> && git rebase origin/<base>` in a local checkout |

**State file**: Write `.claude/pr-fleet/state.json` (under the repo) after every cycle.
Track: `{pr_number, check_id, retried_at, actions_taken_today}`. Without this,
you'll retry the same check on every poll. Create the directory if missing.

## The Loop

```
every <interval>:
  for each PR in scope:
    0. fetch state + merged — drop merged PRs from scope immediately, report them as "✅ Merged"
    1. check CI → maybe retry (once)
    2. fetch review comments → summarize new ones in digest
    3. check merge status → maybe rebase
  accumulate digest entries
  print the digest to the terminal at the end of each cycle
  on any hard-stop trigger → escalate immediately at the top of the digest (don't bury it)
```

**Always fetch `state` and `mergedAt` fields.** If `state == "MERGED"`, report it
as merged (with `mergedAt`) and drop it from the active list — never say "no
reviewers assigned" for a merged PR. If `state == "CLOSED"` (not merged), report
it as closed and drop it similarly.

The loop is started automatically at the end of the launch sequence (step 6 above);
`/loop` reschedules at the chosen interval.

## Review Wait Tracking

**Apply to every PR where `reviewRequests` is non-empty OR `reviewDecision != APPROVED`** — including PRs where GitHub says APPROVED but not all requested reviewers have reviewed.

- **Identifier**: link to the GitHub PR URL (e.g., `https://github.com/<owner>/<repo>/pull/NNN`). If the PR title contains a ticket pattern `[A-Z]+-\d+` (e.g., `DD-1160`), keep it in the title text but always link to the GitHub PR, never elsewhere.
- **Age**: time since the PR was last made ready for review — NOT `createdAt`. Use the most recent `ReadyForReviewEvent` or `ReopenedEvent` from the timeline; fall back to `createdAt` only if neither exists. Format as "Xd Yh" (e.g., "2d 6h", "14h", "3d 0h").

  ```
  gh api graphql -f query='
  {
    repository(owner: "OWNER", name: "REPO") {
      pullRequest(number: NUMBER) {
        createdAt
        timelineItems(last: 20, itemTypes: [READY_FOR_REVIEW_EVENT, REOPENED_EVENT]) {
          nodes {
            __typename
            ... on ReadyForReviewEvent { createdAt }
            ... on ReopenedEvent { createdAt }
          }
        }
      }
    }
  }'
  ```

  Take the `max(createdAt)` across all returned timeline nodes; if none, use `pullRequest.createdAt`.
- **Approval status**: cross-reference `reviewRequests` against `latestReviews` to show partial approval state. Count total reviewers as the union of (all `reviewRequests` entries + anyone who left a review). **Never collapse partial approval to just "approved"** — all requested reviewers must approve. Show exactly who has and hasn't:
  - All pending: `→ @alice, @bob, @carol`
  - Partial: `→ 1/3 approved (@alice ✓) · still need @bob, @carol`
  - All approved (but CLEAN check failed): `→ ✅ all requested approved`
  - No reviewers assigned: `→ no reviewers assigned`

- **Timestamps**: always display in the user's local timezone in 12-hour format with AM/PM (e.g., "5:02 PM"), not UTC.

**Flag PRs waiting > 3 days with ⚠️** in the digest.

**In the observation cycle output and digest**, always show these for every PR in "No Action Needed". The primary identifier is the PR title (linked to the GitHub PR URL):

```
• [PR title](https://github.com/...) — awaiting review 2d 6h → 1/3 approved (@alice ✓) · still need @bob, @carol
```

If `reviewRequests` is empty and the PR has been waiting > 1 day, note it as a nudge: the user may need to assign reviewers.

## CI Checks: Flaky vs Broken

**Retry once if ALL of these are true:**
- Check failed (conclusion: `failure` or `timed_out`)
- Same commit SHA has not been retried for this check yet (check state file)
- Duration was under 90 seconds OR log contains: `ETIMEDOUT`, `connection refused`, `rate limit`, `no space left`, `context canceled`, `503`

**Do NOT retry — escalate instead:**
- Already retried once for this commit SHA + check ID
- Log contains: test assertion output, compilation errors, type errors, lint violations
- 3+ checks failing simultaneously (code problem, not infra)
- Check is a required status gating merge

Never retry more than once per (commit SHA, check ID) pair. Record in state file immediately after retrying.

## Review Comments: Surfacing Only

**Never take any automated action on review comments.** Surface them in the digest for the user to act on.

For each PR with new unresolved review comments since the last cycle, include a summary in the digest:
- Group by reviewer
- One line per comment: file + line (if inline), truncated comment body (≤ 120 chars)
- Note if it's a suggested change (reviewer used the suggest-a-change feature) — user can apply manually

**Never post a reply as the user.** Never apply suggested changes automatically.

## Rebase Conflicts: Safe vs Escalate

**Attempt auto-rebase only if ALL true:**
- PR has merge conflicts (`gh pr view` shows `mergeStateStatus: DIRTY`)
- PR does not already have an approved review (rebase invalidates approvals)
- Conflicted files ≤ 3
- **Every** conflicted file is in the safe-resolve list below (check this BEFORE starting the rebase)

**Within those conflicts, auto-resolve only:**
- `package-lock.json` / `yarn.lock` → re-run `npm install` after merging both `package.json` changes
- Generated files → re-run the generate command
- Import-only conflicts (both sides added different imports, no deletions) → take both

**Escalate immediately (do not attempt rebase):**
- ANY conflicted file is a logic file (function bodies, conditionals, class definitions)
- ANY conflicted file looks like a shared library or public API path
- More than 3 conflicted files
- Any file you haven't seen before in this session
- Even if only 1 out of 3 files is a logic file — escalate the whole PR, don't cherry-pick

**After rebase**: push (not force-push — rebase onto the base branch should be a fast-forward on the feature branch, so `git push` works), wait for CI before marking resolved.

**Force-push policy**: Never force-push without explicit user confirmation. If the rebase results in a non-fast-forward, stop and escalate.

## Escalation: Immediate vs Digest

**Escalate immediately (surface at the top of the digest, don't bury it):**
- CI failure after retry on a required status check
- Rebase failed or produced a conflict you can't resolve
- Any action you were about to take but hit a hard stop

Print a short line at the top of the digest:
`🚨 PR Fleet: [#NNNN] needs your attention — [one-line reason] <link>`

**Hold until the cycle digest:**
- Everything that "handled autonomously"
- PRs in "waiting / no action" state

## Cycle Digest Format

Print to the terminal at the end of every cycle:

```
*PR Digest* — <current date + time, local tz> · <owner/repo>
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔴 *Needs Your Attention* (N items)
• [PR title](gh-link) — reason (1 line)

💬 *Review Comments* (N items)
• [PR title](gh-link) — @reviewer on `file:line`: "comment text..." [suggested change]

✅ *Handled Autonomously* (N items)
• [PR title](gh-link) — what was done

⏳ *No Action Needed* (N items)
• [PR title](gh-link) — awaiting review Xd Yh → waiting on @reviewer1, @reviewer2
• ⚠️ [PR title](gh-link) — awaiting review 4d 2h → no reviewers assigned

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
N need your attention · N have review comments · N no action needed
```

## Escalation Criteria Reference Table

| Situation | Action |
|-----------|--------|
| CI failed, not yet retried, looks infra | Retry once, log it |
| CI failed, already retried | Escalate immediately |
| CI failed, test assertion in log | Escalate immediately (no retry) |
| Any review comment (including suggested changes) | Surface in digest, no automated action |
| Merge conflict, ≤3 files, only lock/imports | Auto-rebase |
| Merge conflict, logic files or >3 files | Escalate immediately |
| PR has approved review + conflicts | Escalate (rebase would invalidate approval) |
| Draft PR | CI monitoring only — skip review wait, rebase, comments |

## Common Mistakes

- **Using email instead of GitHub username**: `gh pr list --author me@example.com` fails. Use `gh auth status` to get the username first
- **Forgetting to check state file**: Retry the same check every cycle. Always read `.claude/pr-fleet/state.json` first
- **Force-pushing without confirmation**: Rebase may result in non-fast-forward. Always `git push` first, escalate if it fails
- **Reporting "no reviewers assigned" for merged PRs**: When `reviewRequests` is empty, always check `state` + `mergedAt` first. Empty review requests means the review completed — not that it was abandoned. Report merged PRs as "✅ Merged" and drop them from scope.
- **Taking any action on review comments**: Surface them in the digest only — never reply, never apply suggested changes automatically
- **Assuming a single base branch**: derive the PR's base with `gh pr view <n> --json baseRefName` before rebasing; don't hardcode `main`

## Hard Limits (Never Exceed)

- Max 1 retry per (commit SHA + check ID)
- Max 3 autonomous actions per PR per day
- Max 10 autonomous actions across all PRs per day
- Never force-push without explicit confirmation
- Never post a comment as the user
- Never auto-merge a PR, never apply a review suggestion
- Always write state file after every action
