#!/usr/bin/env bash
# Read-only ground-truth survey. Emits JSON to stdout for SKILL.md.
# On any error: print {"error": "..."} and exit 1 so the cycle skips.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_tools

REPO="$(detect_repo)"
ISSUES_JSON="$(gh issue list --repo "$REPO" --state open --limit 100 \
  --json number,labels 2>/dev/null)" || fail "gh issue list failed"
PRS_JSON="$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json headRefName 2>/dev/null)" || fail "gh pr list failed"

OPEN_PR_BRANCHES="$(echo "$PRS_JSON" | jq -r '[.[].headRefName] | @json')"
FACTS="[]"
while read -r path; do
  [ -z "$path" ] && continue
  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  owned="$(py "from supervisorlib import registry; print('true' if registry.is_owned('$REGISTRY','$path') else 'false')")"
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
  fi
  has_pr="$(echo "$OPEN_PR_BRANCHES" | jq --arg b "$branch" 'index($b) != null')"
  issue_num="$(py "from supervisorlib import registry; print(registry.issue_for_path('$REGISTRY','$path') or 'null')")"
  FACTS="$(echo "$FACTS" | jq \
    --argjson issue "$issue_num" --arg path "$path" --arg branch "$branch" \
    --argjson owned "$owned" --argjson alive "$alive" --argjson hasq "$has_q" \
    --argjson complete "$task_complete" --argjson haspr "$has_pr" \
    --argjson restart "${restart:-0}" --argjson present "$task_present" \
    '. += [{issue:$issue, path:$path, branch:$branch, owned:$owned, facts:{
        process_alive:$alive, has_question_md:$hasq, task_complete:$complete,
        has_open_pr:$haspr, restart_count:$restart, task_md_present:$present}}]')"
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

python3 - "$LIB_DIR" "$REGISTRY" "$ISSUES_JSON" "$FACTS" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
from supervisorlib import gh, registry, survey
reg_path, issues, facts = sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4])
owned_nums = registry.issues(reg_path)
eligible = gh.eligible_issues(issues, owned_issue_numbers=owned_nums)
print(json.dumps(survey.assemble(worktree_facts=facts, eligible_issues=eligible)))
PY
