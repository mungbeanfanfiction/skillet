#!/usr/bin/env bash
# Lint a GitHub review payload so every body is a short Conventional Comment.
# Checks the review `body` (if non-empty) and each `comments[].body`.
#
# Usage: lint-comments.sh <payload.json>
# Exit 0 when clean; exit 1 and print one line per violation otherwise.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq not found on PATH" >&2; exit 2; }
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: lint-comments.sh <payload.json>" >&2; exit 2; }

LABELS='praise|nitpick|suggestion|issue|todo|question|thought|chore|note'
MAX_SUBJECT=72
MAX_WORDS=40
OPENERS='i noticed|it looks like|i think|just a thought|great work, but'

errors=0
err() { echo "$1: $2"; errors=$((errors + 1)); }

lint() {
  local where="$1" body="$2"
  local first rest label decos subject words
  first=$(printf '%s\n' "$body" | head -n1)
  rest=$(printf '%s\n' "$body" | tail -n +2)

  if ! [[ "$first" =~ ^($LABELS)(\ \(([a-z-]+(,\ ?[a-z-]+)*)\))?:\ (.+)$ ]]; then
    err "$where" "first line must be '<label> [(decorations)]: <subject>' with label in: ${LABELS//|/, }"
    return
  fi
  label="${BASH_REMATCH[1]}"
  decos="${BASH_REMATCH[3]}"
  subject="${BASH_REMATCH[5]}"

  case "$label" in
    issue|suggestion|todo)
      [[ ",${decos// /}," =~ ,(blocking|non-blocking), ]] \
        || err "$where" "'$label' needs a (blocking) or (non-blocking) decoration" ;;
    nitpick)
      [[ ",${decos// /}," == *,blocking,* ]] && err "$where" "nitpick can't be blocking" ;;
  esac

  [ "${#subject}" -le "$MAX_SUBJECT" ] \
    || err "$where" "subject is ${#subject} chars (max $MAX_SUBJECT)"

  # Count discussion words outside fenced code blocks.
  words=$(printf '%s\n' "$rest" | awk '/^[[:space:]]*(```|~~~)/ { f = !f; next } !f' | wc -w | tr -d ' ')
  [ "$words" -le "$MAX_WORDS" ] \
    || err "$where" "discussion is $words words (max $MAX_WORDS, code blocks excluded)"

  local prose
  prose=$(printf '%s\n' "$body" | awk '/^[[:space:]]*(```|~~~)/ { f = !f; next } !f')
  if printf '%s\n' "$prose" | grep -qiE "\\b($OPENERS)\\b"; then
    err "$where" "cut the filler opener ($(printf '%s\n' "$prose" | grep -oiE "$OPENERS" | head -n1))"
  fi
}

review_body=$(jq -r '.body // ""' "$1")
[ -z "$review_body" ] || lint "review body" "$review_body"

count=$(jq '.comments // [] | length' "$1")
for ((i = 0; i < count; i++)); do
  where=$(jq -r --argjson i "$i" '.comments[$i] | "\(.path):\(.line)"' "$1")
  body=$(jq -r --argjson i "$i" '.comments[$i].body' "$1")
  lint "$where" "$body"
done

if [ "$errors" -gt 0 ]; then
  echo "$errors violation(s)"
  exit 1
fi
echo "ok: $count comment(s) pass"
