#!/usr/bin/env bash
# Read-only ground-truth survey. Emits JSON to stdout for SKILL.md.
# On any error: print {"error": "..."} and exit 1 so the cycle skips.
#
# Subprocess budget is O(1) in worktree count, not O(N): the open- and merged-PR
# branch sets are each fetched with ONE `gh pr list`, path+branch come from a
# single `git worktree list --porcelain`, and per-worktree JSON is slurped in one
# jq. The only remaining per-worktree fork is the unavoidable `git -C diff`.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_tools

# Fail closed: any unhandled error in the loop body emits the error envelope on
# stdout (the SKILL's "STOP on {"error":...}" contract) instead of a bare exit.
trap 'fail "survey aborted unexpectedly"' ERR

REPO="$(detect_repo)"; BASE="$(detect_base)"
ISSUES_JSON="$(gh issue list --repo "$REPO" --state open --limit 100 \
  --json number,labels 2>/dev/null)" || fail "gh issue list failed"
PRS_JSON="$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json headRefName 2>/dev/null)" || fail "gh pr list failed"

OPEN_PR_BRANCHES="$(echo "$PRS_JSON" | jq -r '[.[].headRefName] | @json')"

# `--state merged` excludes closed-but-unmerged PRs on purpose: that work was
# abandoned, not shipped, so it keeps its ordinary classification. The 200-PR
# window covers every branch a live worktree could still be on; a merge older than
# that only costs one wasted restart, whereas a false positive would strand real
# work as `merged`. Any gh/jq failure yields an empty set — a missed merge, never
# a false positive — which is the safe direction.
MERGED_PR_BRANCHES="$(gh pr list --repo "$REPO" --state merged --limit 200 \
  --json headRefName 2>/dev/null | jq -r '[.[].headRefName] | @json' 2>/dev/null || echo '[]')"

# One clock read for the whole survey; heartbeat age is measured against it.
NOW="$(date +%s)"

# Collect RAW filesystem facts only; ownership/issue are derived in the Python
# pass below. Keeps untrusted worktree paths out of inlined Python literals.
# A detached-HEAD worktree has no `branch` line; awk emits the literal `HEAD` for
# it (what `git rev-parse --abbrev-ref HEAD` returned) to keep output identical.
FACTS="$(while IFS=$'\t' read -r path branch; do
  [ -z "$path" ] && continue
  has_q="$([ -f "$path/.claude/question.md" ] && echo true || echo false)"
  pid_file="$path/.claude/session.pid"
  alive=false
  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then alive=true; fi
  task_present="$([ -f "$path/.claude/task.md" ] && echo true || echo false)"
  task_complete=false; restart=0; conflict_escalated=false
  if [ "$task_present" = true ]; then
    awk '/^## Pipeline stage/{getline; if($1=="done") found=1} END{exit !found}' \
      "$path/.claude/task.md" 2>/dev/null && task_complete=true || true
    restart="$(awk '/## Restart count/{getline; print $1; exit}' "$path/.claude/task.md" 2>/dev/null || echo 0)"
    # Sanitize: a hand-edited non-numeric count must not break the jq below.
    case "$restart" in (''|*[!0-9]*) restart=0 ;; esac
    # An unclean merge conflict the PR-watch session couldn't auto-resolve leaves a
    # `CONFLICT-ESCALATED` marker in the progress log; surface it for the digest.
    if grep -q 'CONFLICT-ESCALATED' "$path/.claude/task.md" 2>/dev/null; then
      conflict_escalated=true
    fi
  fi
  # Heartbeat age is the only evidence distinguishing a working session from a wedged
  # one (the PostToolUse hook rewrites the file on every tool call). `null` = no
  # evidence, never stale.
  hb="$path/.claude/status/HEARTBEAT.md"
  hb_age=null; last_step=null; exit_reason=null
  if [ -f "$hb" ]; then
    hb_mtime="$(file_mtime "$hb" || echo "")"
    case "$hb_mtime" in (''|*[!0-9]*) : ;; (*) hb_age=$(( NOW - hb_mtime )) ;; esac
    # awk exits at the first match: a `sed | head -1` pipeline SIGPIPEs on a large
    # file, and under pipefail that trips the ERR trap and kills the whole cycle.
    last_step="$(awk '/^- last step: /{sub(/^- last step: /,""); print; exit}' "$hb" | jq -Rs 'rtrimstr("\n")')"
    exit_reason="$(awk '/^- exit reason: /{sub(/^- exit reason: /,""); print; exit}' "$hb" | jq -Rs 'rtrimstr("\n")')"
    [ "$exit_reason" = '""' ] && exit_reason=null
    [ "$last_step" = '""' ] && last_step=null
  fi
  has_pr="$(echo "$OPEN_PR_BRANCHES" | jq --arg b "$branch" 'index($b) != null')"
  # Merged state comes from GitHub, not task.md, so a stale local marker can't fake
  # it. Empty branch never matches.
  pr_merged=false
  if [ -n "$branch" ]; then
    pr_merged="$(echo "$MERGED_PR_BRANCHES" | jq --arg b "$branch" 'index($b) != null')"
  fi
  # Changed lines vs base (added + deleted) — the metric open-pr caps at 400.
  # Exclude lockfiles/generated files; any git failure → 0 so survey never aborts.
  # `|| echo 0`: an unresolvable origin/<base> (fresh/unfetched worktree) makes git
  # exit 128; under pipefail that would trip the ERR trap and abort the survey.
  diff_lines="$(git -C "$path" diff --numstat "origin/$BASE...HEAD" \
    -- . ':(exclude)**/*.lock' ':(exclude)**/*.freezed.dart' ':(exclude)**/*.g.dart' 2>/dev/null \
    | awk '$1 != "-" && $2 != "-" { s += $1 + $2 } END { print s + 0 }' || echo 0)"
  case "$diff_lines" in (''|*[!0-9]*) diff_lines=0 ;; esac
  jq -nc \
    --arg path "$path" --arg branch "$branch" \
    --argjson alive "$alive" --argjson hasq "$has_q" \
    --argjson complete "$task_complete" --argjson haspr "$has_pr" \
    --argjson restart "$restart" --argjson present "$task_present" \
    --argjson difflines "$diff_lines" --argjson escalated "$conflict_escalated" \
    --argjson prmerged "$pr_merged" \
    --argjson hbage "$hb_age" --argjson laststep "$last_step" --argjson exitreason "$exit_reason" \
    '{path:$path, branch:$branch, facts:{
        process_alive:$alive, has_question_md:$hasq, task_complete:$complete,
        has_open_pr:$haspr, pr_merged:$prmerged, restart_count:$restart,
        task_md_present:$present, diff_changed_lines:$difflines,
        conflict_escalated:$escalated, heartbeat_age_seconds:$hbage,
        last_step:$laststep, exit_reason:$exitreason}}'
done < <(git worktree list --porcelain \
  | awk '/^worktree /{if(p!="")print p"\t"b; p=substr($0,10); b="HEAD"}
         /^branch refs\/heads\//{b=substr($0,19)}
         END{if(p!="")print p"\t"b}') | jq -sc .)"

# Derive ownership + issue from the registry here (paths passed as argv, never
# interpolated into a literal), then assemble the survey.
python3 - "$LIB_DIR" "$REGISTRY" "$ISSUES_JSON" "$FACTS" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
from supervisorlib import gh, registry, survey
reg_path, issues, raw_facts = sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4])
reg = registry.load(reg_path)
by_path = {w["path"]: w for w in reg["worktrees"]}
facts = []
for f in raw_facts:
    owner = by_path.get(f["path"])
    facts.append({
        "issue": owner["issue"] if owner else None,
        "path": f["path"], "branch": f["branch"],
        "owned": owner is not None, "facts": f["facts"],
    })
owned_nums = registry.issues(reg_path)
eligible = gh.eligible_issues(issues, owned_issue_numbers=owned_nums)
print(json.dumps(survey.assemble(worktree_facts=facts, eligible_issues=eligible)))
PY
