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
old_string=$(printf '%s' "$input" | jq -r '.tool_input.old_string // empty' 2>/dev/null || true)

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
comment_lines=$(grep -nE '^[[:space:]]*(//|#|--)' <<<"$content" | grep -vE '^[0-9]+:[[:space:]]*#!' || true)

# Count added lines that are comments vs. total non-blank added lines.
total_nonblank=$(grep -cE '[^[:space:]]' <<<"$content" || true)
comment_count=$(grep -cE '[^[:space:]]' <<<"$comment_lines" || true)

flagged=""

# --- Heuristic 1: redundant / narration comments -----------------------------
# Strip the comment marker, lowercase, and flag if the comment opens with a
# low-value narration verb, ending on a word boundary so that prose like
# "Callers must ..." is not mistaken for a "call" narration.
narration=$(sed -E 's@^[0-9]+:[[:space:]]*(//|#|--)[[:space:]]*@@' <<<"$comment_lines" \
  | grep -iE '^((increment|decrement|return|returns|set|sets|get|gets|loop( over| through)?|iterate|call|calls|define|defines|create|creates|initialize|declare|assign|add|append)\b|check if|now |then |first,|next,|finally,)' \
  || true)
if [ -n "$narration" ]; then
  flagged+="Narration comments that restate the code (explain *why*, not *what*):"$'\n'
  flagged+="$(head -5 <<<"$narration" | sed 's/^/  • /')"$'\n'
fi

# --- Heuristic 2: step-by-step play-by-play ----------------------------------
step_lines=$(grep -iE '(//|#|--)[[:space:]]*step[[:space:]]*[0-9]' <<<"$comment_lines" || true)
steps=$(grep -cE '[^[:space:]]' <<<"$step_lines" || true)
if [ "$steps" -ge 2 ]; then
  flagged+="Step-by-step \"Step N\" play-by-play comments ($steps found) — usually noise:"$'\n'
  flagged+="$(head -3 <<<"$step_lines" | sed -E 's/^[0-9]+://; s/^[[:space:]]*/  • /')"$'\n'
fi

# --- Heuristic 3: comment-heavy diff -----------------------------------------
# Only meaningful on a reasonably sized edit. >50% comments by line is a smell.
if [ "$total_nonblank" -ge 8 ] && [ "$comment_count" -gt 0 ]; then
  if [ $(( comment_count * 100 )) -ge $(( total_nonblank * 50 )) ]; then
    flagged+="Comment-heavy edit: $comment_count of $total_nonblank non-blank lines are comments (>50%)."$'\n'
  fi
fi

# --- Heuristic 4: gratuitous top-of-file comment block -----------------------
# Only applies when the incoming text actually lands at the file top: a Write
# (whole-file content) always does; an Edit only if the file currently starts
# with old_string. Set SKILLET_ALLOW_FILE_HEADERS=1 to skip this heuristic
# where a leading header is required (generated banners, license policies).
if [ "${SKILLET_ALLOW_FILE_HEADERS:-0}" != "1" ]; then
  at_file_top=0
  if [ -n "$old_string" ]; then
    # Edit: does the file already begin with old_string? Measure in bytes, not
    # characters — `head -c` is byte-oriented and old_string may be multibyte.
    n_bytes=$(printf '%s' "$old_string" | wc -c | tr -d '[:space:]')
    if [ -f "$target" ] && [ "$(head -c "$n_bytes" "$target" 2>/dev/null || true)" = "$old_string" ]; then
      at_file_top=1
    fi
  else
    at_file_top=1
  fi

  if [ "$at_file_top" = "1" ]; then
    # Take the leading run of comment lines — both line comments (//, #, --) and
    # a /* ... */ block. Skip blanks and anything the toolchain requires up top:
    # shebangs, encoding/type pragmas, linter and compiler directives,
    # license/copyright notices, and generated-file banners.
    # Fed by here-string, not a pipe: this awk exits at the first non-comment
    # line, which would SIGPIPE a `printf` producer on any large file.
    header=$(awk '
      function exempt(s) {
        return tolower(s) ~ /(copyright|licen[sc]e|spdx-|generated|do not edit|autogenerated|@flow|eslint-disable|prettier-ignore)/
      }
      # Inside a /* */ block: collect prose until the closing delimiter.
      inblock {
        line = $0
        sub(/\*\/.*$/, "", line)
        if (!exempt(line) && line ~ /[[:alnum:]]/) { started = 1; print line }
        if ($0 ~ /\*\//) inblock = 0
        next
      }
      /^[[:space:]]*$/ { if (started) exit; next }
      /^[[:space:]]*(#!|\/\/[[:space:]]*@|\/\/\/|\/\/go:|#[[:space:]]*-\*-|#[[:space:]]*(type|noqa|pylint|mypy|ruff|fmt):)/ { next }
      # Opening of a block comment. A single-line /* ... */ closes immediately.
      /^[[:space:]]*\/\*/ {
        if ($0 !~ /\*\//) inblock = 1
        line = $0
        sub(/^[[:space:]]*\/\*+/, "", line)
        sub(/\*\/.*$/, "", line)
        if (!exempt(line) && line ~ /[[:alnum:]]/) { started = 1; print line }
        next
      }
      /^[[:space:]]*(\/\/|#|--)/ {
        if (exempt($0)) next
        started = 1; print; next
      }
      { exit }
    ' <<<"$content")
    header_lines=$(grep -cE '[^[:space:]]' <<<"$header" || true)

    # Judge the header by content, not length. A long header that explains *why*
    # (constraints, footguns, rejected alternatives) earns its place; a short one
    # that just restates what the file is, is the narration this rule targets.
    # So flag a header only when it carries no reasoning signal at all. Bare
    # cross-refs ("See models.py") and dependency notes ("Requires psycopg2")
    # are deliberately not signals — they describe *what*, so they buy no pass.
    why_signal=$(grep -icE '(\bbecause\b|\bso that\b|\bso it\b|\botherwise\b|\bwhy\b|\binstead\b|\brather than\b|\bwould\b|\bavoids?\b|\bavoiding\b|\bmust\b|\bcannot\b|\bcan not\b|\bnot\b .*\bbut\b|\bcaveat\b|\bgotcha\b|\bbeware\b|\bworkaround\b|\bhack\b|\bassumes?\b|\bbug\b|\bissue #)' <<<"$header" \
      || true)

    # Does the opening line just echo the filename? ("foo_bar.py" → "foo bar")
    # Match on word boundaries so a stem of "auth" does not match inside the
    # word "authentication" — that is prose about the file, not a restatement.
    stem=$(basename "$target" | sed -E 's/\.[^.]+$//; s/[-_]+/ /g')
    # Escape regex metacharacters — a filename may legally contain them.
    stem_re=$(printf '%s' "$stem" | sed -E 's/[][\\.^$*+?(){}|]/\\&/g')
    first_line=$(grep -m1 -E '[^[:space:]]' <<<"$header" || true)
    echoes_name=0
    if [ -n "$stem" ] && printf '%s' "$first_line" | grep -qiE "(^|[^[:alnum:]])${stem_re}([^[:alnum:]]|\$)"; then
      echoes_name=1
    fi

    # A why-signal anywhere in the header earns it a pass, even if the opening
    # line names the file — naming your subject is prose, not restatement. So
    # echoing the filename never flags on its own; it only sharpens the message,
    # and lets a lone "# Session store." (pure restatement) flag at one line.
    min_lines=2
    [ "$echoes_name" = "1" ] && min_lines=1

    if [ "$header_lines" -ge "$min_lines" ] && [ "$why_signal" -eq 0 ]; then
      if [ "$echoes_name" = "1" ]; then
        flagged+="Top-of-file comment restates the filename — say *why*, or drop it:"$'\n'
      else
        flagged+="Top-of-file comment block ($header_lines lines) describes *what* the file is, with no *why*:"$'\n'
      fi
      flagged+="$(head -3 <<<"$header" | sed -E 's/^[[:space:]]*/  • /')"$'\n'
      flagged+="  (set SKILLET_ALLOW_FILE_HEADERS=1 if this file genuinely needs a header)"$'\n'
    fi
  fi
fi

[ -z "$flagged" ] && exit 0

reason="Possible overly verbose / low-value comments in this edit. Comments should explain *why*, not narrate *what* the code does.

$flagged
Trim the narration, or approve if these comments are intentional (e.g. documented public API)."

# Emit the reason as a properly-escaped JSON string via jq.
jq -nc --arg r "$reason" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
