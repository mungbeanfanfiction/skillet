#!/usr/bin/env bash
# session-stats.sh <transcript.jsonl> -- emit one JSON object of session stats,
# or {"ok":false,"error":...} and exit 1. Single extraction point so no skill
# estimates from memory.

set -uo pipefail

fail() { jq -nc --arg e "$1" '{ok:false,error:$e}' 2>/dev/null || printf '{"ok":false,"error":"%s"}\n' "$1"; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq not installed"

PROG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/session-stats.jq"
[ -f "$PROG" ] || fail "missing session-stats.jq next to this script"

T="${1:-}"
[ -n "$T" ] || fail "usage: session-stats.sh <transcript.jsonl>"
[ -f "$T" ] || fail "no such transcript: $T"

turns=$(jq -s '[.[] | select(.type=="assistant")] | length' "$T" 2>/dev/null) || fail "unparseable transcript"
[ "${turns:-0}" -gt 0 ] || fail "empty transcript"

out=$(jq -s -f "$PROG" "$T" 2>&1) || fail "extraction failed: $(printf '%s' "$out" | head -1)"
printf '%s\n' "$out"
