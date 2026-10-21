---
name: review-pr
description: Review a pull request, verify each finding, and leave short, human-readable comments in Conventional Comments format (`label (decorations): subject`). Every comment, including the review summary, is linted for format and length before posting; a comment that fails is rewritten, never posted as-is. Posts one GitHub review with event COMMENT — never approves or requests changes. Use when asked to review a PR and leave comments on it.
argument-hint: "[pr-number] [--repo <owner/repo>] [--dry-run]"
model: opus
---

# Review PR

Few comments, each short, each labeled with
[Conventional Comments](https://conventionalcomments.org/) so the author sees
at a glance what's blocking. No exceptions, including praise and the summary.

## When invoked

- **`[pr-number]`** — defaults to the current branch's PR. No PR, stop and say so.
- **`--repo <owner/repo>`** — defaults to the current checkout's repo.
- **`--dry-run`** — print the comments, post nothing.

## Workflow

### 1. Read the change

Run `gh pr view <pr> --json title,body,headRefOid` and `gh pr diff <pr>`. Read
the PR body and linked issue so you review against what the change is for.

### 2. Find what's worth saying

In order: bugs and broken edge cases, security, missing tests for new
behavior, confusing design, readability. Skip what a linter would catch.

Cap it at **10 comments**. Fold extra nitpicks into one, or drop them.

### 3. Verify each finding

A wrong comment costs the author more than a missing one. Try to disprove
each finding:

- Re-read the code at the head commit, not just the hunk: callers, guards
  elsewhere, whether the "missing" thing exists in another file.
- For a bug, trace the input that breaks it. Run a quick test if it's cheap.
- Check the PR body and issue. The behavior may be intended.

Keep what survives. Can't confirm but it matters? Ask a `question` instead of
asserting an `issue`. Drop the rest.

### 4. Write each comment

`<label> [(decorations)]: <subject>`, then an optional discussion paragraph.

| Label | Use for |
|---|---|
| `issue` | A real problem, stated concretely. |
| `suggestion` | A specific improvement. Say what, not "consider improving". |
| `question` | You need the answer to judge the code. |
| `nitpick` | Trivial preference. Never blocking. |
| `todo` | Small, necessary change (missing test, stale doc). |
| `thought` | An idea, not a request. |
| `chore` | Process task before merge. |
| `note` | Context; no action needed. |
| `praise` | Something specific done well. At most one per review. |

Put `(blocking)` or `(non-blocking)` on every `issue`, `suggestion`, and
`todo`. Add a topic when it helps: `issue (blocking, security):`.

- Subject: 72 characters max. Reading only subjects should give every ask.
- Discussion: 40 words max outside code blocks. Usually one sentence of *why*.
- For a code change, use a ```` ```suggestion ```` block instead of prose.
- Cut openers ("I noticed", "It looks like", "I think"), restating the code,
  hedging, and second points. One comment, one point.

~~~
issue (blocking): `retries` resets on every loop, so this never gives up

Hoist it above the `while`.

suggestion (non-blocking): early return reads easier here

```suggestion
if (!user) return null;
```

question: is `cache` safe to share across requests?

nitpick: `data2` → `parsedRows`
~~~

### 5. Write the review summary

One line, one conventional comment. Count blocking items and stop:
`note: 2 blocking issues in auth.ts; rest are non-blocking.` No findings?
`praise: clean change, nothing to flag.`

### 6. Lint before posting

Write the payload to a scratch file. Anchor comments to `RIGHT`-side diff lines
(`start_line` + `line` for a range):

```json
{ "commit_id": "<headRefOid>", "event": "COMMENT", "body": "note: ...",
  "comments": [{ "path": "src/auth.ts", "line": 42, "side": "RIGHT", "body": "issue (blocking): ..." }] }
```

```bash
plugins/skillet/skills/review-pr/scripts/lint-comments.sh <payload.json>
```

It checks label, decoration, subject length, discussion length, and openers,
naming the comment and rule on failure. Rewrite and lint again. Never post a
payload that fails.

### 7. Post

With `--dry-run`, print each comment as `path:line` plus body, then stop.
Otherwise post once:

```bash
gh api repos/<owner>/<repo>/pulls/<pr>/reviews --method POST --input <payload.json>
```

If GitHub rejects a line that isn't in the diff, move the comment to the
nearest changed line or into the summary, lint, and retry. Report the review
URL and the count by label.

## Do not

- Approve or request changes. Blocking status lives in the decorations.
- Post comments one at a time. One review, one notification.
- Push, commit, or edit code.
