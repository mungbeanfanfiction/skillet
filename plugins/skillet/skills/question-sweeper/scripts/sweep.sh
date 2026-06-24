#!/usr/bin/env bash
# Read-only sweep: emit JSON of (newly-raised questions, answered inbox items).
# The SKILL.md decides what to act on. No spawning here.
set -euo pipefail

# Reuse the supervisor's common.sh for REPO_ROOT/REGISTRY/LIB_DIR/py().
SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SWEEP_DIR/../../issue-supervisor/scripts" && pwd)/common.sh"
require_tools

# Fail closed like survey.sh: emit the error envelope rather than a bare exit.
trap 'fail "sweep aborted unexpectedly"' ERR

INBOX="$REPO_ROOT/docs/superpowers/questions"
mkdir -p "$INBOX"

# Look up an owned worktree's issue number from the registry. Path is passed as
# argv (never interpolated into a Python literal), so a quote in a foreign
# worktree path cannot break or inject.
issue_for_path() {
  python3 - "$LIB_DIR" "$REGISTRY" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from supervisorlib import registry
print(registry.issue_for_path(sys.argv[2], sys.argv[3]) or "")
PY
}

RAISED="[]"
while read -r path; do
  [ -z "$path" ] && continue
  q="$path/.claude/question.md"
  [ -f "$q" ] || continue
  issue="$(issue_for_path "$path")"
  [ -z "$issue" ] && continue
  if [ ! -f "$INBOX/$issue.md" ]; then
    RAISED="$(echo "$RAISED" | jq --argjson i "$issue" --arg p "$path" '. += [{issue:$i, path:$p}]')"
  fi
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

ANSWERED="[]"
for f in "$INBOX"/*.md; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .md)"; [ "$base" = ".gitkeep" ] && continue
  case "$base" in (*[!0-9]*) continue ;; esac   # only numeric <issue>.md
  filled="$(py "from supervisorlib import questions; print('true' if questions.is_answered('$f') else 'false')")"
  [ "$filled" = true ] && ANSWERED="$(echo "$ANSWERED" | jq --argjson i "$base" '. += [$i]')"
done

jq -n --argjson raised "$RAISED" --argjson answered "$ANSWERED" \
  '{raised:$raised, answered:$answered}'
