#!/usr/bin/env bash
# SessionEnd hook: mark a session that ended unlogged, for /vault:backfill.
# One small write is all the 1.5s budget allows.

set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0

session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null) || exit 0
reason=$(printf '%s' "$input" | jq -r '.reason // "other"' 2>/dev/null) || exit 0
[ -n "$session" ] && [ -n "$transcript" ] || exit 0

STATE="${VAULT_STATE_DIR:-$HOME/.claude/vault}"
mkdir -p "$STATE/queue" 2>/dev/null || exit 0

# Already logged this session? Nothing to queue.
[ -f "$STATE/logged/$session" ] && exit 0

jq -nc \
  --arg s "$session" --arg t "$transcript" --arg c "$cwd" --arg r "$reason" \
  --arg e "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{session_id:$s, transcript:$t, cwd:$c, reason:$r, ended_at:$e}' \
  > "$STATE/queue/$session.json" 2>/dev/null || true

exit 0
