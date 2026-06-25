#!/usr/bin/env bash
# PR-watch pass: for each OWNED worktree whose branch has an open PR, check it
# for new/unaddressed comments (via the check-pr-comments skill) and for a fresh
# merge conflict (via gh's mergeStateStatus, which resolve-conflicts also acts
# on), and dispatch a follow-up session INTO that PR's existing worktree when
# either signal fires. De-dup is via a per-worktree checkpoint in the registry,
# so the same comments/conflict state is not re-dispatched every pass.
#
# Reuses the same detached-claude spawn as dispatch.sh — no one-off code path.
# Worktrees that are busy (live session) or parked on a question are skipped so
# we never clobber an in-flight session.
#
# Emits one JSON line per acted-on PR to stdout (for the SKILL report); all other
# diagnostics go to stderr.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_tools

REPO="$(detect_repo)"
# The check-pr-comments skill ships its fetch/classify script alongside this one,
# under the sibling skill dir. Resolve it relative to the plugin's skills/ root so
# it works wherever the plugin is installed.
SKILLS_ROOT="$(cd "$SKILL_DIR/.." && pwd)"
COMMENTS_SCRIPT="$SKILLS_ROOT/check-pr-comments/scripts/check-pr-comments.sh"

# Handle one worktree. Factored into a function (called with a `|| log` guard
# below) so that — unlike a pipe-fed `while` body under `set -e` — a failure on a
# single PR cannot silently abort the whole pass and skip every later worktree.
process_worktree() {
  local WT="$1"
  [ "$(is_owned "$WT")" = true ] || return 0

  local BRANCH
  BRANCH="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  [ -z "$BRANCH" ] && return 0

  # Resolve the open PR for this branch. No PR → nothing to watch.
  # NOTE: `gh pr list` may report mergeStateStatus as UNKNOWN (it doesn't always
  # force GitHub to recompute mergeability the way `gh pr view` does). prwatch
  # treats UNKNOWN as no-op, so a real conflict is simply caught on a later pass
  # rather than the first — acceptable for a recurring loop.
  local PR_JSON PR
  PR_JSON="$(gh pr list --repo "$REPO" --state open --head "$BRANCH" \
    --json number,mergeStateStatus,baseRefOid,headRefOid 2>/dev/null || echo '[]')"
  PR="$(echo "$PR_JSON" | jq -r 'if length>0 then .[0].number else empty end')"
  [ -z "$PR" ] && return 0

  # Never spawn a second session into a worktree that is busy or parked.
  local PID_FILE="$WT/.claude/session.pid"
  if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "skip PR #$PR ($WT): session live" >&2; return 0
  fi
  if [ -f "$WT/.claude/question.md" ]; then
    echo "skip PR #$PR ($WT): parked on a question" >&2; return 0
  fi

  local MERGE_JSON CHECKPOINT
  MERGE_JSON="$(echo "$PR_JSON" | jq -c '.[0]')"
  CHECKPOINT="$(python3 - "$LIB_DIR" "$REGISTRY" "$WT" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
from supervisorlib import registry
print(json.dumps(registry.get_pr_checkpoint(sys.argv[2], sys.argv[3])))
PY
)"

  # Comments: pass the stored `comments_since` as --since so check-pr-comments
  # only returns feedback newer than the last handled pass. Tolerate a failing
  # envelope (script prints {"ok":false,...}); the decision treats it as no-op.
  local SINCE ENVELOPE
  SINCE="$(echo "$CHECKPOINT" | jq -r '.comments_since // empty')"
  if [ -x "$COMMENTS_SCRIPT" ]; then
    ENVELOPE="$("$COMMENTS_SCRIPT" "$PR" --repo "$REPO" --since "$SINCE" --json 2>/dev/null || echo '{"ok":false}')"
  else
    echo "warn: check-pr-comments script not found at $COMMENTS_SCRIPT — comments skipped for PR #$PR" >&2
    ENVELOPE='{"ok":false}'
  fi

  # Decide + compute the next checkpoint in one pure pass. NOW is the fallback the
  # comments checkpoint advances to when the envelope carries no usable timestamp,
  # so a malformed envelope can't cause an unbounded re-dispatch loop.
  local NOW DECISION
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  DECISION="$(python3 - "$LIB_DIR" "$MERGE_JSON" "$ENVELOPE" "$CHECKPOINT" "$NOW" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
from supervisorlib import prwatch
merge, envelope, checkpoint = (json.loads(a) for a in sys.argv[2:5])
print(json.dumps(prwatch.decide(merge=merge, envelope=envelope,
                                checkpoint=checkpoint, now=sys.argv[5])))
PY
)"

  local DISPATCH
  DISPATCH="$(echo "$DECISION" | jq -r '.dispatch')"
  if [ "$DISPATCH" != "true" ]; then
    echo "ok PR #$PR ($BRANCH): nothing to address" >&2; return 0
  fi

  local REASONS ISSUE PROMPT CLAUDE NEXT_CP
  REASONS="$(echo "$DECISION" | jq -r '.reasons | join(",")')"
  ISSUE="$(python3 - "$LIB_DIR" "$REGISTRY" "$WT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import registry
print(registry.issue_for_path(sys.argv[2], sys.argv[3]) or "")
PY
)"

  PROMPT="$(python3 - "$LIB_DIR" "$ISSUE" "$PR" "$REASONS" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import spawn
print(spawn.pr_address_prompt(issue=sys.argv[2], pr=sys.argv[3], reasons=sys.argv[4]))
PY
)"

  CLAUDE="$(resolve_claude)"
  ( cd "$WT" && nohup "$CLAUDE" -p "$PROMPT" --permission-mode acceptEdits --add-dir "$WT" \
      > "$WT/.claude/session.log" 2>&1 & echo $! > "$WT/.claude/session.pid" )

  # Advance the checkpoint ONLY for the signals we just dispatched on (the
  # decision already computed it that way), so a deferred signal is retried.
  NEXT_CP="$(echo "$DECISION" | jq -c '.checkpoint')"
  python3 - "$LIB_DIR" "$REGISTRY" "$WT" "$NEXT_CP" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
from supervisorlib import registry
registry.set_pr_checkpoint(sys.argv[2], sys.argv[3], json.loads(sys.argv[4]))
PY

  jq -nc --arg pr "$PR" --arg branch "$BRANCH" --arg reasons "$REASONS" \
    '{pr: ($pr|tonumber), branch: $branch, reasons: ($reasons|split(","))}'
  echo "dispatched PR #$PR ($BRANCH) → $WT [$REASONS]" >&2
}

# Walk every worktree in the PARENT shell (process substitution, like survey.sh)
# so a per-PR failure surfaces as a logged warning instead of silently aborting
# the loop. Each call is guarded so one bad worktree can't end the pass.
while read -r WT; do
  [ -z "$WT" ] && continue
  process_worktree "$WT" || echo "warn: PR-watch failed for $WT — continuing" >&2
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')
