#!/usr/bin/env bash
# Write this worktree's supervisor runtime-state files (task.md / question.md) from stdin.
#
# Claude Code gates Edit/Write on everything under `.claude/`, and a dispatched
# (`claude -p`) session cannot approve that prompt. Bash is not gated, so this is the
# sanctioned path — restricted to the two files the pipeline owns, and therefore unable
# to reach `.claude/settings.json` or `.claude/hooks/`.
#
# Usage:
#   write-runtime-state.sh task.md          <<'EOF'   # replace
#   write-runtime-state.sh question.md      <<'EOF'   # park on a design question
#   write-runtime-state.sh --append task.md <<'EOF'   # append a progress-log line
set -euo pipefail

append=false
if [ "${1:-}" = "--append" ]; then append=true; shift; fi

name="${1:-}"
case "$name" in
  task.md|question.md) ;;
  *) echo "write-runtime-state.sh: refusing '$name' — only task.md or question.md" >&2; exit 2 ;;
esac

# THIS session's worktree, not the main checkout common.sh anchors shared state to.
root="$(git rev-parse --show-toplevel)"
mkdir -p "$root/.claude"
target="$root/.claude/$name"

if [ "$append" = true ]; then cat >> "$target"; else cat > "$target"; fi
echo "wrote $target"
