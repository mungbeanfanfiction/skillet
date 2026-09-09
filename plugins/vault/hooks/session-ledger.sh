#!/usr/bin/env bash
# Stop hook: nudge toward /vault:log once a session has enough material.
#
# Stop rather than SessionEnd -- SessionEnd shares a 1.5s budget and cannot prompt.
# Scores material only; /vault:log decides whether the session is worth keeping.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
[ -n "$session" ] || exit 0

STATE="${VAULT_STATE_DIR:-$HOME/.local/state/claude-vault}"
mkdir -p "$STATE/nudged" 2>/dev/null || exit 0

# Nudge at most once per session. This is also the cheap path for most turns.
[ -f "$STATE/nudged/$session" ] && exit 0

STATS_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" 2>/dev/null && pwd)/session-stats.sh"
[ -x "$STATS_SH" ] || exit 0

stats=$(bash "$STATS_SH" "$transcript" 2>/dev/null) || exit 0
printf '%s' "$stats" | jq -e '.ok == true' >/dev/null 2>&1 || exit 0

get() { printf '%s' "$stats" | jq -r "$1 // 0" 2>/dev/null || echo 0; }

turns=$(get '.turns')
files=$(get '.files_touched')
tools=$(get '.tools | length')
errors=$(get '.errors')
mins=$(get '.duration_min')

# Deliberately loose. Over-triggering costs nothing — the nudge is free and
# /vault:log filters. Under-triggering loses the session while context is warm.
score=0
[ "$turns"  -ge 12 ] && score=$((score+1))
[ "$files"  -ge 2  ] && score=$((score+1))
[ "$tools"  -ge 4  ] && score=$((score+1))
[ "$errors" -ge 2  ] && score=$((score+1))
[ "$mins"   -ge 15 ] && score=$((score+1))

[ "$score" -ge 2 ] || exit 0

: > "$STATE/nudged/$session" 2>/dev/null

cat <<EOF
[vault] This session has enough material to be worth a look: ${turns} turns, \
${files} files touched, ${tools} distinct tools, ${errors} errors, ~${mins}m.

Offer to run /vault:log. That skill decides whether the session is actually
worth keeping — plenty of long sessions are not. Do not write a note yourself.
EOF
exit 0
