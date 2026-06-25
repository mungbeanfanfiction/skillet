"""Decide whether an owned, PR-bearing worktree needs a follow-up session for
new review feedback or a fresh merge conflict — and compute the checkpoint that
records the handled state so the same feedback/conflict is not re-dispatched.

Pure logic only: it takes already-fetched JSON (the `check-pr-comments --json`
envelope and a `gh pr view` merge snapshot) plus the per-PR checkpoint the
supervisor persisted last cycle. Subprocess/I/O lives in the shell layer.

The de-dup levers, one per signal:
  - comments  → a timestamp checkpoint (`comments_since`). `check-pr-comments`
    is already filtered with `--since <checkpoint>`, so by the time its envelope
    reaches here every unaddressed item is new-since-last-pass. We advance the
    checkpoint to the newest comment we saw, so next cycle starts after it.
  - conflict  → an identity checkpoint (`conflict_oid`): the (base, head) commit
    pair the last conflict dispatch handled. A conflict re-triggers only when
    that pair changes (base or head moved), never on the unchanged same state.
"""

# mergeStateStatus values that mean "a merge conflict this skill should act on".
# Mirrors resolve-conflicts' Step 1 table: DIRTY = real conflict, BEHIND = a
# clean update onto a moved base. BLOCKED/UNSTABLE are check/review failures (not
# conflicts), CLEAN/HAS_HOOKS are mergeable, UNKNOWN is not-yet-computed — none
# of those warrant a dispatch.
CONFLICT_STATES = ("DIRTY", "BEHIND")


def _newest_comment_ts(envelope: dict) -> str | None:
    """Latest `created_at` across the envelope's unaddressed items, or None.

    Used to advance the comments checkpoint. The envelope items carry
    `created_at`; missing/empty ones are ignored so a malformed item can't
    poison the max.
    """
    stamps = [
        c["created_at"]
        for c in envelope.get("unaddressed", [])
        if c.get("created_at")
    ]
    return max(stamps) if stamps else None


def comments_need_dispatch(envelope: dict) -> bool:
    """True iff the (already `--since`-filtered) envelope reports unaddressed
    comments. A malformed/failed envelope (`ok` is false) never dispatches."""
    if not envelope.get("ok", False):
        return False
    return envelope.get("counts", {}).get("unaddressed", 0) > 0


def conflict_need_dispatch(merge: dict, *, last_conflict_oid: str | None) -> bool:
    """True iff the PR is in an actionable conflict state AND that state is new
    since we last handled it.

    `merge` is a `gh pr view` snapshot with `mergeStateStatus`, `baseRefOid`,
    `headRefOid`. The conflict identity is the (base, head) pair: if either side
    moved since the last handled dispatch, it's a fresh conflict worth another
    pass; if neither moved, the same unresolved state is still in flight (a
    session may be working it) and we do not re-dispatch.
    """
    if merge.get("mergeStateStatus") not in CONFLICT_STATES:
        return False
    return conflict_oid(merge) != last_conflict_oid


def conflict_oid(merge: dict) -> str:
    """The identity of a conflict state: the base/head commit pair."""
    return f"{merge.get('baseRefOid', '')}:{merge.get('headRefOid', '')}"


def next_checkpoint(
    *, prior: dict | None, envelope: dict, merge: dict,
    dispatch_comments: bool, dispatch_conflict: bool, now: str | None = None,
) -> dict:
    """The checkpoint to persist after this pass.

    Only advance a checkpoint for a signal we actually dispatched on — a signal
    we skipped this cycle (e.g. the worktree was busy) must stay un-advanced so
    it is reconsidered next cycle rather than silently marked handled.

    When dispatching on comments, advance `comments_since` to the newest item's
    `created_at`. If no usable timestamp is found (a malformed envelope that
    reports `unaddressed > 0` but whose items lack `created_at`), fall back to
    `now` so the checkpoint still advances — otherwise the same comments would
    re-dispatch on every idle pass forever. `now` must be supplied by the caller
    (the shell layer stamps it) when comments dispatch; if it is also missing,
    the checkpoint can't advance and the loop logs that as a degraded state.
    """
    prior = prior or {}
    out = dict(prior)
    if dispatch_comments:
        advanced = _newest_comment_ts(envelope) or now
        if advanced:
            out["comments_since"] = advanced
    if dispatch_conflict:
        out["conflict_oid"] = conflict_oid(merge)
    return out


def decide(*, merge: dict, envelope: dict, checkpoint: dict | None,
           now: str | None = None) -> dict:
    """One PR's verdict. Returns:
      {"dispatch": bool, "reasons": [...], "checkpoint": {...}}

    `dispatch` is true if either signal fires. `reasons` is the human-facing list
    (e.g. ["comments", "conflict"]). `checkpoint` is what to persist — but only
    advanced for the signals that fired, so a deferred signal is retried later.
    `now` (ISO8601, from the shell layer) is the fallback the comments checkpoint
    advances to when the envelope carries no usable `created_at`.
    """
    checkpoint = checkpoint or {}
    do_comments = comments_need_dispatch(envelope)
    do_conflict = conflict_need_dispatch(
        merge, last_conflict_oid=checkpoint.get("conflict_oid")
    )
    reasons = []
    if do_comments:
        reasons.append("comments")
    if do_conflict:
        reasons.append("conflict")
    return {
        "dispatch": bool(reasons),
        "reasons": reasons,
        "checkpoint": next_checkpoint(
            prior=checkpoint, envelope=envelope, merge=merge,
            dispatch_comments=do_comments, dispatch_conflict=do_conflict, now=now,
        ),
    }
