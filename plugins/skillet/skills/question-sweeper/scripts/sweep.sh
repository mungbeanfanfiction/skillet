#!/usr/bin/env bash
# Read-only sweep: emit JSON of (newly-raised questions, answered inbox items).
# The SKILL.md decides what to act on. No spawning here.
set -euo pipefail

# Reuse the supervisor's common.sh for REPO_ROOT/REGISTRY/LIB_DIR/py().
SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SWEEP_DIR/../../issue-supervisor/scripts" && pwd)/common.sh"
require_tools

INBOX="$REPO_ROOT/docs/superpowers/questions"
mkdir -p "$INBOX"

RAISED="[]"
while read -r path; do
  [ -z "$path" ] && continue
  q="$path/.claude/question.md"
  [ -f "$q" ] || continue
  issue="$(py "from supervisorlib import registry; print(registry.issue_for_path('$REGISTRY','$path') or '')")"
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
