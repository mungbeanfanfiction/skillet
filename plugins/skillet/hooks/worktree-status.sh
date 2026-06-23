#!/usr/bin/env bash
# Skillet worktree-status Stop hook (writer).
# Passive: writes .claude/status/STATUS.md for linked worktrees only.
# Always exits 0 — never disrupts the session.
set -u

# Read the hook's stdin JSON. Bail quietly if jq is missing or input is unusable.
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)"
[ -n "$input" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || exit 0
[ -d "$cwd" ] || exit 0

# Must be inside a git repo.
toplevel="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
git_dir="$(git -C "$cwd" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
common_dir="$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || exit 0

# Linked-worktree detection: a linked worktree's git dir lives under
# <common>/worktrees/<name>, so it contains "/worktrees/". The main checkout's
# git dir equals the common dir and does not. Bail in main (no work in main).
case "$git_dir" in
  */worktrees/*) : ;;   # linked worktree → proceed
  *) exit 0 ;;          # main checkout → do nothing
esac

# Self-heal the local exclude so STATUS.md never pollutes git status / commits.
exclude_file="$common_dir/info/exclude"
mkdir -p "$(dirname "$exclude_file")"
touch "$exclude_file"
grep -qxF '.claude/status/' "$exclude_file" 2>/dev/null || printf '.claude/status/\n' >>"$exclude_file"

branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
dirty_count="$(git -C "$cwd" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
updated="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

last_ask=""
last_did=""
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # Last user prompt: content may be a string or an array of blocks.
  last_ask="$(jq -rs '
    [ .[] | select(.type=="user")
          | (.message.content // .content) ] | last
    | if type=="array" then (map(select(.type=="text").text) | join(" "))
      elif type=="string" then .
      else "" end // ""' "$transcript" 2>/dev/null | head -c 200)"
  # Last assistant text block.
  last_did="$(jq -rs '
    [ .[] | select(.type=="assistant")
          | (.message.content // .content) ] | last
    | if type=="array" then (map(select(.type=="text").text) | join(" "))
      elif type=="string" then .
      else "" end // ""' "$transcript" 2>/dev/null | head -c 200)"
fi

touched="$(git -C "$cwd" diff --stat 2>/dev/null | tail -1)"

status_dir="$toplevel/.claude/status"
mkdir -p "$status_dir"
cat >"$status_dir/STATUS.md" <<EOF
# worktree status

- updated: $updated
- branch: $branch
- dirty files: $dirty_count

## current activity
**last ask:** $last_ask
**last did:** $last_did

## touched
$touched
EOF

exit 0
