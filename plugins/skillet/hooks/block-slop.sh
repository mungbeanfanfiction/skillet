#!/usr/bin/env bash
# PreToolUse hook: flag agent-written prose in markdown. See /deslop for the standard.
# Thresholds are relative to document length -- density is the tell, not presence.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

target=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
content=$(printf '%s' "$input" | jq -r '.tool_input.new_string // .tool_input.content // empty' 2>/dev/null || true)

[ -n "$content" ] || exit 0

# Markdown and plain prose only.
case "$target" in
  *.md|*.markdown|*.mdx|*.txt) : ;;
  *) exit 0 ;;
esac

# The deslop skill itself documents these patterns by name. Never flag it.
case "$target" in
  */skills/deslop/*) exit 0 ;;
esac

# Ignore trivial edits — a one-line change has no texture to judge.
total_nonblank=$(printf '%s\n' "$content" | grep -cE '[^[:space:]]' || true)
[ "$total_nonblank" -ge 6 ] || exit 0

# Strip fenced code blocks and inline code before judging prose. Backticked
# content is frequently technical vocabulary that would false-positive.
prose=$(printf '%s\n' "$content" \
  | awk '/^[[:space:]]*```/{f=!f; next} !f' \
  | sed -E 's/`[^`]*`//g')

flagged=""

# --- Heuristic 1: stock vocabulary -------------------------------------------
# These words are the strongest single signal and rarely the right choice.
stock=$(printf '%s\n' "$prose" \
  | grep -inoE '\b(delve|delves|delving|leverages?|leveraging|utilizes?|utilizing|facilitates?|streamlines?|seamless(ly)?|robust|comprehensive|holistic|elevates?|unlocks?|harnesses?|tapestry|landscape of|realm of|testament to|crucial|pivotal|myriad|plethora|underscores?)\b' \
  | head -6 || true)
if [ -n "$stock" ]; then
  flagged+="Stock AI vocabulary:"$'\n'
  flagged+="$(printf '%s\n' "$stock" | sed -E 's/^([0-9]+):/  • line \1: /')"$'\n'
fi

# --- Heuristic 2: contrast frames as a rhythm --------------------------------
contrast=$(printf '%s\n' "$prose" \
  | grep -inE "(isn't just|is not just|not just [a-z]+, (but|it)|rather than [a-z]+, |it's not [a-z]+ — it's|more than just)" \
  | head -4 || true)
contrast_n=$(printf '%s\n' "$contrast" | grep -cE '[^[:space:]]' || true)
if [ "$contrast_n" -ge 2 ]; then
  flagged+="Contrast frames used as a rhythm ($contrast_n found) — fine once, a tic at this density:"$'\n'
  flagged+="$(printf '%s\n' "$contrast" | head -3 | sed -E 's/^([0-9]+):[[:space:]]*/  • line \1: /' | cut -c1-100)"$'\n'
fi

# --- Heuristic 3: em-dash density --------------------------------------------
# Leah writes "--". Thresholds are relative: a long doc earns more em-dashes than
# a short one. Calibrated against this repo — the existing SKILL.md files run
# 5-37% of sentences, so 32% flags roughly the worst quarter.
emdash=$(printf '%s' "$prose" | grep -o '—' | grep -c '' || true)
sentences=$(printf '%s' "$prose" | grep -o '[.!?]' | grep -c '' || true)
if [ "$emdash" -ge 8 ] && [ "$sentences" -gt 0 ] && [ $(( emdash * 100 )) -ge $(( sentences * 32 )) ]; then
  flagged+="Em-dash density: $emdash em-dashes across ~$sentences sentences. Prefer \`--\`, and fewer of them."$'\n'
fi

# --- Heuristic 4: bold scattered on non-terms --------------------------------
# Also relative. This repo's files run 0-27 bold spans per 100 prose lines;
# 22 flags the top handful without firing on every reference doc.
bold=$(printf '%s' "$prose" | grep -oE '\*\*[^*]+\*\*' | grep -c '' || true)
if [ "$bold" -ge 8 ] && [ "$total_nonblank" -gt 0 ] && [ $(( bold * 100 )) -ge $(( total_nonblank * 22 )) ]; then
  flagged+="Bold on $bold spans across $total_nonblank lines. Bold a term being defined; let sentence order carry the rest."$'\n'
fi

# --- Heuristic 5: scaffolding headings over thin content ---------------------
headings=$(printf '%s\n' "$prose" | grep -cE '^#{2,4} ' || true)
if [ "$headings" -ge 3 ] && [ "$total_nonblank" -lt $(( headings * 8 )) ]; then
  flagged+="Scaffolding: $headings headings over $total_nonblank lines. If a heading owns one paragraph, drop the heading."$'\n'
fi

# --- Heuristic 6: empty hedges -----------------------------------------------
hedges=$(printf '%s\n' "$prose" \
  | grep -inoE "(it's worth noting|it is worth noting|importantly,|essentially,|in essence|needless to say|at the end of the day)" \
  | head -4 || true)
hedge_n=$(printf '%s\n' "$hedges" | grep -cE '[^[:space:]]' || true)
if [ "$hedge_n" -ge 2 ]; then
  flagged+="Empty hedges ($hedge_n found) — they carry no information:"$'\n'
  flagged+="$(printf '%s\n' "$hedges" | sed -E 's/^([0-9]+):/  • line \1: /')"$'\n'
fi

[ -z "$flagged" ] && exit 0

reason="This markdown reads as agent-written. See /deslop for the full standard.

$flagged
Tighten it, or approve if the phrasing is deliberate."

jq -nc --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
