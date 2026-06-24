#!/usr/bin/env bash
# PreToolUse hook: discourage overly verbose, low-value comments in code edits.
#
# LLM-authored code tends to over-comment: narrating every line, restating what
# the code plainly says, or leaving "Step 1 / Step 2" play-by-play. These
# comments rot, add noise, and accelerate context compaction. Good comments
# explain *why*, not *what* — this hook flags the *what*-comments.
#
# Scope: only inspects the text being written (Edit.new_string / Write.content).
# It does not read the whole file, so it judges the incoming change in isolation.
#
# Detection (heuristic, tuned to avoid false positives on normal code):
#   1. Redundant narration: a comment whose words just echo the adjacent code
#      token, or that opens with a low-value verb like "increment/return/set/
#      loop/call/define" — classic line-by-line narration.
#   2. Step-by-step play-by-play: multiple "Step N" / numbered-procedure comments.
#   3. Comment-heavy diffs: a large share of the *added* lines are comments.
#
# Behavior: matches return permissionDecision "ask" (not a hard block) with the
# offending lines quoted, so the author can confirm intentional comments (e.g. a
# deliberately documented public API) but is nudged to trim narration. No match
# emits nothing and the edit proceeds. Anything unparseable exits 0 silently —
# the hook must never disrupt a session.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

# Pull the file path (to gate on source files) and the text being written.
target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
content=$(printf '%s' "$input" | jq -r '.tool_input.new_string // .tool_input.content // empty' 2>/dev/null || true)

[ -n "$content" ] || exit 0

# Only inspect source files that actually carry code comments. Skip docs,
# config, and data where "# ..." or "// ..." is content, not a code comment.
case "$target" in
  *.md|*.mdx|*.txt|*.json|*.jsonc|*.yaml|*.yml|*.toml|*.ini|*.csv|*.lock) exit 0 ;;
  "") exit 0 ;;
esac

# Extract comment lines from the added text: //, #, and -- single-line comments.
# (A leading "#!" shebang is excluded.) We work line-oriented so we can quote
# the offenders back to the author.
comment_lines=$(printf '%s\n' "$content" | grep -nE '^[[:space:]]*(//|#|--)' | grep -vE '^[0-9]+:[[:space:]]*#!' || true)

# Count added lines that are comments vs. total non-blank added lines.
total_nonblank=$(printf '%s\n' "$content" | grep -cE '[^[:space:]]' || true)
comment_count=$(printf '%s\n' "$comment_lines" | grep -cE '[^[:space:]]' || true)

flagged=""

# --- Heuristic 1: redundant / narration comments -----------------------------
# Strip the comment marker, lowercase, and flag if the comment opens with a
# low-value narration verb. These almost always restate the next line of code.
narration=$(printf '%s\n' "$comment_lines" \
  | sed -E 's@^[0-9]+:[[:space:]]*(//|#|--)[[:space:]]*@@' \
  | grep -iE '^(increment|decrement|return|returns|set|sets|get|gets|loop( over| through)?|iterate|call|calls|define|defines|create|creates|initialize|declare|assign|add|append|check if|now |then |first,|next,|finally,)' \
  || true)
if [ -n "$narration" ]; then
  flagged+="Narration comments that restate the code (explain *why*, not *what*):"$'\n'
  flagged+="$(printf '%s\n' "$narration" | head -5 | sed 's/^/  • /')"$'\n'
fi

# --- Heuristic 2: step-by-step play-by-play ----------------------------------
steps=$(printf '%s\n' "$comment_lines" | grep -icE '(//|#|--)[[:space:]]*step[[:space:]]*[0-9]' || true)
if [ "$steps" -ge 2 ]; then
  flagged+="Step-by-step \"Step N\" play-by-play comments ($steps found) — usually noise:"$'\n'
  flagged+="$(printf '%s\n' "$comment_lines" | grep -iE '(//|#|--)[[:space:]]*step[[:space:]]*[0-9]' | head -3 | sed -E 's/^[0-9]+://; s/^[[:space:]]*/  • /')"$'\n'
fi

# --- Heuristic 3: comment-heavy diff -----------------------------------------
# Only meaningful on a reasonably sized edit. >50% comments by line is a smell.
if [ "$total_nonblank" -ge 8 ] && [ "$comment_count" -gt 0 ]; then
  if [ $(( comment_count * 100 )) -ge $(( total_nonblank * 50 )) ]; then
    flagged+="Comment-heavy edit: $comment_count of $total_nonblank non-blank lines are comments (>50%)."$'\n'
  fi
fi

[ -z "$flagged" ] && exit 0

reason="Possible overly verbose / low-value comments in this edit. Comments should explain *why*, not narrate *what* the code does.

$flagged
Trim the narration, or approve if these comments are intentional (e.g. documented public API)."

# Emit the reason as a properly-escaped JSON string via jq.
jq -nc --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
