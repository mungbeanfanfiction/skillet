---
name: check-pr-comments
description: Check a pull request for new or unaddressed comments — review comments, inline review threads, and top-level PR comments — distinguishing unaddressed feedback from already-resolved threads. Outputs a concise, actionable summary of what still needs a response. Standalone and invocable on its own; also consumable by /issue-supervisor. Use to see what feedback on a PR still needs handling.
argument-hint: "<pr-number> [--repo <owner/repo>] [--since <ISO8601>] [--json]"
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
- **All comments are surfaced regardless of author** — no filtering by who posted.

### Limitation: thread attribution

An inline review thread is attributed to its **first** comment — the opening
"ask" — for author, body, and timestamp, while its resolved/outdated state is
taken from the **thread**. Two consequences worth knowing:

- The body shown is the opener's, not the latest reply. The resolved state is
  still authoritative for unaddressed-vs-handled, so you won't get false
  "handled" — but open the URL for the full conversation when a thread is long.
- `--since` does **not** apply to inline threads — they de-dup by `isResolved`,
  not by timestamp, so an unresolved thread is always surfaced regardless of the
  checkpoint. (Only top-level PR comments and review summaries, which have no
  resolve state, are scoped by `--since`.) This prevents an old-but-unresolved
  thread from being silently filtered out by a checkpoint that has moved past it.

## When invoked

Parse the arguments:

- **`<pr-number>`** (required) — the first bare integer.
- **`--repo <owner/repo>`** — defaults to the current checkout's repo.
- **`--since <ISO8601>`** — only consider top-level PR comments / review
  summaries created at or after this timestamp (e.g. `2026-06-01T00:00:00Z`).
  Inline review threads are exempt (de-duped by `isResolved`, not timestamp).
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
PR #123 — owner/name · 3 unaddressed, 1 handled

@reviewer
  • src/auth.ts:42 — "this should handle the null case before…" (outdated)  <url>
  • review summary [CHANGES_REQUESTED] — "a couple of things to fix before…"  <url>

@otherbot
  • PR comment — "CI is red on the lint step"  <url>

1 thread already resolved — not listed.
```

If there are **no unaddressed comments**, say so plainly:
`PR #123 — owner/name · nothing unaddressed (1 handled).`

## Notes

- **Read-only.** This skill never replies, resolves, or edits. It only reports.
- **`--since` is the de-dup lever for resolve-less items.** This skill is
  stateless; to avoid re-surfacing the same top-level PR comments / review
  summaries across passes, a caller (e.g. the supervisor) records the
  last-checked timestamp per PR and passes it back as `--since`. Inline threads
  ignore `--since` — they de-dup by `isResolved` instead — so an unresolved
  thread keeps surfacing until it is actually resolved.
