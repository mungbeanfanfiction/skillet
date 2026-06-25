---
name: check-pr-comments
description: Check a pull request for new or unaddressed comments — review comments, inline review threads, and top-level PR comments — excluding the agent's/supervisor's own comments, and distinguishing unaddressed feedback from already-resolved threads. Outputs a concise, actionable summary of what still needs a response. Standalone and invocable on its own; also consumable by /issue-supervisor. Use to see what feedback on a PR still needs handling.
argument-hint: "<pr-number> [--repo <owner/repo>] [--include-self] [--since <ISO8601>] [--json]"
---

# Check PR Comments

Surface the **new / unaddressed** comments on a single pull request so you can
see, at a glance, what still needs a response or a change — and what has already
been resolved.

This is a **standalone, one-shot** skill: give it a PR number and it prints a
summary. It takes no automated action (never replies, never resolves, never
edits) and is not coupled to `/issue-supervisor` — though the supervisor (#36)
can consume it to decide which PRs to requeue.

## What it covers

Three distinct comment sources, all fetched and merged:

1. **Inline review threads** — comments anchored to a file/line. These carry a
   native **resolved** state, so they are the source of truth for "handled vs.
   unaddressed".
2. **Review summary bodies** — the top-level text of a submitted review
   (`CHANGES_REQUESTED` / `COMMENTED` / `APPROVED`). The real ask often lives
   here. Empty-bodied reviews (pure approvals, or reviews that only have inline
   comments) are dropped.
3. **Top-level PR comments** — the issue-style discussion thread on the PR.

## How "unaddressed" is decided

- **Inline review thread** → unaddressed **iff it is not resolved**. A resolved
  thread is treated as handled. `isOutdated` is surfaced for context but does
  **not** by itself mean handled — an outdated thread can still need a reply.
- **Review summaries and top-level PR comments** have no native resolve state,
  so they are reported as unaddressed. Use `--since <ISO8601>` to scope to
  comments newer than a known checkpoint (e.g. the last supervisor pass) when
  you only care about what's new.
- **The agent's / supervisor's own comments are excluded.** By default the
  excluded account is the `gh`-authenticated user (the account the agent runs
  as), so its own replies and review summaries are never surfaced as "needs a
  response". Pass `--include-self` to include them (useful when inspecting a PR
  you authored by hand).

### Limitation: thread attribution

An inline review thread is attributed to its **first** comment — the opening
"ask" — for author, body, and timestamp, while its resolved/outdated state is
taken from the **thread**. Two consequences worth knowing:

- A thread *you* (the excluded account) opened is dropped even if a reviewer
  replied underneath with the real ask. If you self-review, pass
  `--include-self` or read the thread directly.
- The body shown is the opener's, not the latest reply. The resolved state is
  still authoritative for unaddressed-vs-handled, so you won't get false
  "handled" — but open the URL for the full conversation when a thread is long.
- `--since` scopes threads by their **opening** comment's timestamp, so a fresh,
  still-unresolved reply on an *old* thread can be filtered out by a `--since`
  pass. Resolved state is unaffected; only the new-since-checkpoint filter is.

## When invoked

Parse the arguments:

- **`<pr-number>`** (required) — the first bare integer.
- **`--repo <owner/repo>`** — defaults to the current checkout's repo.
- **`--include-self`** — do not exclude the authenticated user's own comments.
- **`--since <ISO8601>`** — only consider comments created at or after this
  timestamp (e.g. `2026-06-01T00:00:00Z`).
- **`--json`** — print the raw JSON envelope instead of the formatted summary
  (for callers like `/issue-supervisor`).

### 1. Run the fetch + classify script

The deterministic fetching and classification live in a script so the result is
reproducible:

```bash
plugins/skillet/skills/check-pr-comments/scripts/check-pr-comments.sh <pr-number> [flags]
```

It emits a single JSON envelope on stdout:

```json
{
  "ok": true,
  "repo": "owner/name",
  "pr": 123,
  "excludedAuthor": "leahpeker",
  "since": null,
  "counts": { "total": 4, "unaddressed": 3, "handled": 1 },
  "unaddressed": [ { "kind": "review-thread", "author": "...", "path": "...", "line": 42, "resolved": false, "outdated": false, "body": "...", "url": "..." } ],
  "handled":     [ { "kind": "review-thread", "resolved": true, ... } ]
}
```

`kind` is one of `review-thread`, `review-summary`, or `pr-comment`. On failure
the script prints `{"ok": false, "error": "..."}` and exits non-zero — surface
the error and stop.

If `--json` was passed, print that envelope verbatim and stop.

### 2. Format a concise, actionable summary

Otherwise turn the envelope into a short human summary. Lead with the headline
counts, then list **only the unaddressed items**, grouped by author, each on one
line: location + a truncated body (≤ 120 chars) + the URL. Mark outdated
threads. End with a one-line note of how many were already handled (don't list
them).

```
PR #123 — owner/name · 3 unaddressed, 1 handled (excluding @leahpeker)

@reviewer
  • src/auth.ts:42 — "this should handle the null case before…" (outdated)  <url>
  • review summary [CHANGES_REQUESTED] — "a couple of things to fix before…"  <url>

@otherbot
  • PR comment — "CI is red on the lint step"  <url>

1 thread already resolved — not listed.
```

If there are **no unaddressed comments**, say so plainly:
`PR #123 — owner/name · nothing unaddressed (1 handled, excluding @leahpeker).`

## Notes

- **Read-only.** This skill never replies, resolves, or edits. It only reports.
- **Self-exclusion uses the login, not email** — the script derives it from
  `gh api user`. If you run as a different identity than the one that posts, pass
  `--include-self` and filter in your own reasoning instead.
- **`--since` is the de-dup lever.** This skill is stateless; to avoid
  re-surfacing the same comments across passes, a caller (e.g. the supervisor)
  should record the last-checked timestamp per PR and pass it back as `--since`.
