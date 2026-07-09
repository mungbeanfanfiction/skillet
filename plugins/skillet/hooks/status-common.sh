# Shared helpers for the hooks that write into .claude/status/. Source; do not run.

# Keep .claude/status/ out of `git status` and commits. Both writers call this, so
# whichever fires first heals the exclude; the grep makes it idempotent.
status_self_exclude() {
  local common_dir="$1" exclude_file
  exclude_file="$common_dir/info/exclude"
  mkdir -p "$(dirname "$exclude_file")" || return 0
  touch "$exclude_file" 2>/dev/null || return 0
  grep -qxF '.claude/status/' "$exclude_file" 2>/dev/null \
    || printf '.claude/status/\n' >>"$exclude_file"
}
