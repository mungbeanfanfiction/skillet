#!/usr/bin/env bash
# Read-only ground-truth survey. Emits JSON to stdout for SKILL.md.
# On any error: print {"error": "..."} and exit 1 so the cycle skips.
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

# Collect RAW filesystem facts only; ownership/issue are derived in the Python
# pass below. Keeps untrusted worktree paths out of inlined Python literals.
FACTS="[]"
while read -r path; do
  [ -z "$path" ] && continue
  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  has_q="$([ -f "$path/.claude/question.md" ] && echo true || echo false)"
  pid_file="$path/.claude/session.pid"
  alive=false
  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then alive=true; fi
  task_present="$([ -f "$path/.claude/task.md" ] && echo true || echo false)"
  task_complete=false; restart=0
  if [ "$task_present" = true ]; then
    awk '/^## Pipeline stage/{getline; if($1=="done") found=1} END{exit !found}' \
      "$path/.claude/task.md" 2>/dev/null && task_complete=true || true
    restart="$(awk '/## Restart count/{getline; print $1; exit}' "$path/.claude/task.md" 2>/dev/null || echo 0)"
    # Sanitize: a hand-edited non-numeric count must not break the jq below.
    case "$restart" in (''|*[!0-9]*) restart=0 ;; esac
  fi
  has_pr="$(echo "$OPEN_PR_BRANCHES" | jq --arg b "$branch" 'index($b) != null')"
  # Changed lines vs base (added + deleted) — the metric open-pr caps at 400.
  # Exclude lockfiles/generated files; any git failure → 0 so survey never aborts.
  # `|| echo 0`: an unresolvable origin/<base> (fresh/unfetched worktree) makes git
  # exit 128; under pipefail that would trip the ERR trap and abort the survey.
  diff_lines="$(git -C "$path" diff --numstat "origin/$BASE...HEAD" \
    -- . ':(exclude)**/*.lock' ':(exclude)**/*.freezed.dart' ':(exclude)**/*.g.dart' 2>/dev/null \
    | awk '$1 != "-" && $2 != "-" { s += $1 + $2 } END { print s + 0 }' || echo 0)"
  case "$diff_lines" in (''|*[!0-9]*) diff_lines=0 ;; esac
  FACTS="$(echo "$FACTS" | jq \
    --arg path "$path" --arg branch "$branch" \
    --argjson alive "$alive" --argjson hasq "$has_q" \
    --argjson complete "$task_complete" --argjson haspr "$has_pr" \
    --argjson restart "$restart" --argjson present "$task_present" \
    --argjson difflines "$diff_lines" \
    '. += [{path:$path, branch:$branch, facts:{
        process_alive:$alive, has_question_md:$hasq, task_complete:$complete,
        has_open_pr:$haspr, restart_count:$restart, task_md_present:$present,
        diff_changed_lines:$difflines}}]')"
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

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
