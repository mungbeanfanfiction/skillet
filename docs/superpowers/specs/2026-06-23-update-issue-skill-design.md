# update-issue skill + open-pr integration — design

**Date:** 2026-06-23
**Branch:** `feat-update-issue-skill`

## Problem

`open-pr` creates a draft PR but does nothing to the linked GitHub issue. A
reviewer watching the issue has no signal that work has reached the PR stage.
Separately, there's no reusable way to post a status update to an issue from
within a Claude workflow.

## Decisions (settled during brainstorming)

1. **Separate skill, not folded into `open-pr`.** Posting an issue update is its
   own concern with reusable value (mid-work status, blocked, PR created). This
   matches the skillet idiom: small, single-purpose skills.
2. **`open-pr` posts automatically** once the PR is created and an issue was
   linked — no extra y/n prompt. The user already confirmed opening the PR, and
   a comment is non-destructive.
3. **Wording is "created", never "opened"/"ready".** The PR is always a draft, so
   the issue comment must accurately reflect that state.
4. **Comment with PR link** is the content — a short status line plus the PR URL.
   No labels, no state changes, no close.
5. **Standalone contract is a flexible status comment** — takes an issue number
   plus an optional status message; infers both when omitted.

## Architecture

Two pieces:

### 1. New skill: `update-issue`

Path: `plugins/skillet/skills/update-issue/SKILL.md`

Invocable as `/update-issue [issue-number] [status message]`.

**Input resolution:**
- Issue number: explicit arg → else infer from branch name / commits using the
  same patterns `open-pr` uses in its step 5 (`^(\d+)-`, `issue-(\d+)`,
  `/(\d+)-`, `#(\d+)`, and `(closes|fixes|resolves)\s+#\d+` in commit messages).
- Status message: explicit remaining args → else synthesize a short status line
  from conversation context + recent git log. Never invent test results or
  "tested locally" claims.

**Behavior:**
1. Resolve the repo: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`.
2. Resolve and validate the issue:
   `gh issue view <num> --repo "$REPO" --json number,title,url,state`.
   If not found or `CLOSED`, surface that and ask before posting.
3. Compose a concise comment (status line + any links provided).
4. **Preview the comment and target issue, then confirm (y/n)** before posting.
   Standalone runs are user-initiated and may target any issue, so they get a
   confirm gate.
5. Post: `gh issue comment <num> --repo "$REPO" --body-file <tmpfile>`
   (body file to preserve newlines/quoting; `rm` after).
6. Return the comment URL.

**Does not:** change labels, milestones, assignees, or issue state; never closes
the issue. Comment-only and non-destructive.

**Non-interactive mode:** mirrors `open-pr` — a `--noninteractive` flag skips the
confirm gate and posts directly; the skill never blocks on input. On a closed or
unresolvable issue in this mode, it skips and reports rather than prompting.

### 2. `open-pr` integration

After the PR is created and the URL is known (current step 9), add a new step
(before the "Do not" section):

- **Guard:** only if an issue was linked in step 5.
- Compose a comment: a short line stating a **draft PR was created** + the PR
  URL. Example body:

  ```
  🔧 Draft PR created: <pr-url>
  ```

- Post it **automatically** with the same `gh issue comment` mechanism — no extra
  prompt.
- Report both the PR URL and the issue-comment URL to the user.
- If no issue was linked, skip silently.
- In `open-pr`'s existing non-interactive mode, the new step is unchanged — it
  already posts the comment without prompting.

**Cross-skill boundary:** `open-pr` does **not** programmatically invoke
`/update-issue` (skillet skills point users to slash commands, they don't call
each other). The comment-posting is two `gh` commands, so `open-pr` inlines it.
`open-pr`'s SKILL.md notes that `/update-issue` exists for standalone use.

## Wording

Both skills use **"created"** for the draft-PR case — never "opened" or "ready
for review".

## Out of scope (YAGNI)

- Label/state changes on the issue.
- Auto-closing issues.
- Editing the issue body.
- `open-pr` prompting before posting (decided: automatic).
- Workflow orchestration — this is two sequential steps in one context, no
  fan-out, so no Workflow.

## Files touched

- **New:** `plugins/skillet/skills/update-issue/SKILL.md`
- **Edit:** `plugins/skillet/skills/open-pr/SKILL.md` (new post-PR step + a note
  pointing at `/update-issue`)
- **New:** this spec doc.
