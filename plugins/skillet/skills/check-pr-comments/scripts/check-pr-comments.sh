#!/usr/bin/env bash
# Read-only: fetch a PR's review comments, review threads, and top-level PR
# comments, then classify each as "unaddressed" or "handled". Emits a single
# JSON envelope on stdout. The SKILL.md formats the human summary; this script
# does the deterministic fetching + classification so the result is reproducible.
#
# Usage: check-pr-comments.sh <pr-number> [--repo <owner/repo>] [--include-self] [--since <ISO8601>]
#
# Classification rules (documented in SKILL.md):
#   - Inline review threads: unaddressed iff NOT isResolved. (isOutdated is
#     surfaced but does not by itself mean handled — an outdated thread can still
#     need a reply.) A thread is attributed to its FIRST comment (the "ask");
#     resolved/outdated state is taken from the thread itself.
#   - Top-level PR comments + standalone review-summary bodies: no native
#     resolve state, so treated as unaddressed unless filtered by --since or
#     authored by the excluded self account.
#   - Comments authored by the excluded account (default: the gh-authenticated
#     user — i.e. the agent/supervisor) are dropped entirely, never surfaced.
set -euo pipefail

fail() { jq -n --arg e "$1" '{ok:false, error:$e}'; exit 1; }
trap 'fail "check-pr-comments aborted unexpectedly"' ERR

command -v gh >/dev/null 2>&1 || fail "gh CLI not found on PATH"
command -v jq >/dev/null 2>&1 || fail "jq not found on PATH"

PR=""
REPO=""
INCLUDE_SELF=0
SINCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --include-self) INCLUDE_SELF=1; shift ;;
    --since) SINCE="${2:-}"; shift 2 ;;
    # Always emit JSON, so accept-and-ignore --json — lets callers forward [flags] verbatim.
    --json) shift ;;
    --*) fail "unknown flag: $1" ;;
    *) if [ -z "$PR" ]; then PR="$1"; shift; else fail "unexpected argument: $1"; fi ;;
  esac
done

case "$PR" in
  ""|*[!0-9]*) fail "first argument must be a PR number" ;;
esac

if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')" || fail "could not resolve repo (pass --repo <owner/repo>)"
fi
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# The account to exclude: the agent/supervisor runs as the gh-authenticated user,
# so its own replies/summaries must never be surfaced as "needs a response".
SELF=""
if [ "$INCLUDE_SELF" -eq 0 ]; then
  SELF="$(gh api user --jq '.login' 2>/dev/null || echo "")"
fi

# --- Inline review threads (carry the resolved/outdated state) -----------------
# GraphQL is the only source that exposes isResolved, so it is the source of
# truth for "handled vs unaddressed" on inline comments. Paginate over
# reviewThreads with a cursor so threads beyond the first page are not silently
# dropped (a vanished unaddressed thread would be a correctness bug for a tool
# whose whole job is "don't miss feedback").
THREADS="[]"
CURSOR=""
while :; do
  if [ -z "$CURSOR" ]; then AFTER="null"; else AFTER="\"$CURSOR\""; fi
  PAGE="$(gh api graphql -f owner="$OWNER" -f name="$NAME" -F number="$PR" -f query='
query($owner:String!, $name:String!, $number:Int!) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:100, after:'"$AFTER"') {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          isOutdated
          path
          line
          comments(first:1) {
            nodes { author { login } body createdAt url }
          }
        }
      }
    }
  }
}')" || fail "review threads fetch failed (PR #$PR in $REPO)"

  PAGE_NODES="$(jq -c '[.data.repository.pullRequest.reviewThreads.nodes[] | {
    kind: "review-thread",
    resolved: .isResolved,
    outdated: .isOutdated,
    path: .path,
    line: .line,
    author: (.comments.nodes[0].author.login // "ghost"),
    body: (.comments.nodes[0].body // ""),
    createdAt: (.comments.nodes[0].createdAt // ""),
    url: (.comments.nodes[0].url // "")
  }]' <<<"$PAGE")" || fail "could not parse review threads response"
  THREADS="$(jq -c --argjson a "$THREADS" --argjson b "$PAGE_NODES" -n '$a + $b')"

  HAS_NEXT="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$PAGE")"
  [ "$HAS_NEXT" = "true" ] || break
  CURSOR="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<<"$PAGE")"
done

# --- Top-level PR comments (issue-comment endpoint) ----------------------------
# --paginate runs the --jq filter per page, so emit ONE object per line (not a
# wrapped array) and slurp into a single array with jq -s. Wrapping per page
# would concatenate multiple JSON arrays and break the merge below.
TOPLEVEL="$(gh api "repos/$OWNER/$NAME/issues/$PR/comments" --paginate --jq '.[] | {
  kind: "pr-comment",
  resolved: false,
  outdated: false,
  path: null,
  line: null,
  author: (.user.login // "ghost"),
  body: .body,
  createdAt: .created_at,
  url: .html_url
}' | jq -s '.')" || fail "top-level PR comments fetch failed (PR #$PR in $REPO)"

# --- Review summary bodies (the top-level text of a submitted review) ----------
# These are distinct from inline review comments and from PR comments; a
# CHANGES_REQUESTED / COMMENTED review with a body often carries the real ask.
# Empty-bodied reviews (pure approvals, or reviews that only have inline
# comments) are dropped.
REVIEWS="$(gh api "repos/$OWNER/$NAME/pulls/$PR/reviews" --paginate --jq '.[]
  | select((.body // "") != "")
  | {
      kind: "review-summary",
      resolved: false,
      outdated: false,
      path: null,
      line: null,
      author: (.user.login // "ghost"),
      body: .body,
      state: .state,
      createdAt: .submitted_at,
      url: .html_url
    }' | jq -s '.')" || fail "review summaries fetch failed (PR #$PR in $REPO)"

# --- Merge, filter (self + --since), classify ----------------------------------
jq -n \
  --argjson threads "$THREADS" \
  --argjson toplevel "$TOPLEVEL" \
  --argjson reviews "$REVIEWS" \
  --arg self "$SELF" \
  --arg since "$SINCE" \
  --arg pr "$PR" \
  --arg repo "$REPO" '
  ($threads + $toplevel + $reviews)
  | map(select($self == "" or .author != $self))
  | map(select($since == "" or .createdAt >= $since))
  | map(. + {unaddressed: (.resolved | not)})
  | {
      ok: true,
      repo: $repo,
      pr: ($pr | tonumber),
      excludedAuthor: (if $self == "" then null else $self end),
      since: (if $since == "" then null else $since end),
      counts: {
        total: length,
        unaddressed: (map(select(.unaddressed)) | length),
        handled: (map(select(.unaddressed | not)) | length)
      },
      unaddressed: (map(select(.unaddressed))),
      handled: (map(select(.unaddressed | not)))
    }
  '
