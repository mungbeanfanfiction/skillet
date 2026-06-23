---
name: update-issue
description: Post a status update comment to a GitHub issue. Resolves the issue from an explicit number or infers it from the branch/commits, composes a concise status comment (or uses one you pass in), and posts it with the gh CLI. Comment-only and non-destructive — never changes labels, state, or assignees. Use to leave a status update, link a PR, or note progress on an issue.
argument-hint: "[issue-number] [status message] [--noninteractive]"
---

# Update Issue Skill

Post a status comment to a GitHub issue. This is comment-only: it never changes
labels, milestones, assignees, or issue state, and never closes an issue.

## When Invoked

Parse the arguments:

- **Issue number** — the first bare integer argument, if present.
- **Status message** — the remaining free text, if present.
- **`--noninteractive`** — if present, skip the confirmation prompt (see below).

Both the issue number and the status message are optional and inferred when
omitted.

## Non-interactive mode

When invoked with `--noninteractive` (e.g. by another skill or the autonomous
queue), **skip the confirmation prompt** in step 4 and post directly. The skill
must never block on input in this mode. If neither the issue nor a status
message can be resolved (passed in or inferable), do not post; report the
problem and stop.

## Workflow

### 1. Resolve the repo

```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
```

### 2. Resolve the issue number

In priority order:

1. The explicit issue-number argument, if provided.
2. The current branch name, matching any of: `^(\d+)-`, `issue-(\d+)`, `/(\d+)-`, `#(\d+)`.
3. Recent commit messages on the branch:

   ```bash
   BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')
   git log "origin/$BASE..HEAD" --pretty=%B | grep -oiE '(closes|fixes|resolves)[[:space:]]+#[0-9]+'
   ```

If no issue number can be resolved, stop and tell the user — there is nothing to
comment on.

### 3. Validate the issue

```bash
gh issue view <num> --repo "$REPO" --json number,title,url,state
```

If the issue does not exist, surface the error and stop. If its `state` is
`CLOSED`, tell the user and ask whether to comment anyway (in non-interactive
mode, skip the comment on a closed issue and report that it was skipped).

### 4. Compose and confirm the comment

Build the comment body:

- If a status message was passed in, use it verbatim.
- Otherwise synthesize a short status line from the conversation context plus
  recent git log (`git log "origin/$BASE..HEAD" --pretty='- %s'`). Keep it to a
  sentence or two. **Never** invent test results, screenshots, or "tested
  locally" claims.

Show the user the target issue (number + title) and the proposed comment body,
then ask: **"Post this comment to issue #<num>? (y/n, or paste edits)"**

If the user pastes edits, apply them and re-confirm. (In non-interactive mode,
skip this prompt and post directly.)

### 5. Post the comment

Write the body to a temp file to preserve newlines and quoting, then post:

```bash
BODY_FILE=$(mktemp)
# write body to $BODY_FILE
gh issue comment <num> --repo "$REPO" --body-file "$BODY_FILE"
rm "$BODY_FILE"
```

Return the comment URL (printed by `gh issue comment`) to the user.

## Do not

- Do not change labels, milestones, assignees, or issue state.
- Do not close the issue.
- Do not edit the issue body — only add a comment.
- Do not invent test results, screenshots, or claims of "tested locally".
