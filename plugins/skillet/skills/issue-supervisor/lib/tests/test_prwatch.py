from supervisorlib import prwatch


def merge(status="CLEAN", base="b1", head="h1"):
    return {"mergeStateStatus": status, "baseRefOid": base, "headRefOid": head}


def envelope(unaddressed=0, items=None, ok=True):
    return {
        "ok": ok,
        "counts": {"unaddressed": unaddressed},
        "unaddressed": items or [],
    }


# --- comments_need_dispatch --------------------------------------------------

def test_comments_dispatch_when_unaddressed_present():
    assert prwatch.comments_need_dispatch(envelope(unaddressed=2)) is True


def test_comments_no_dispatch_when_none_unaddressed():
    assert prwatch.comments_need_dispatch(envelope(unaddressed=0)) is False


def test_comments_no_dispatch_on_failed_envelope():
    # a {"ok": false} envelope (fetch error) must never trigger a dispatch
    assert prwatch.comments_need_dispatch(envelope(unaddressed=5, ok=False)) is False


# --- conflict_need_dispatch --------------------------------------------------

def test_conflict_dispatch_on_dirty_when_new():
    assert prwatch.conflict_need_dispatch(merge("DIRTY"), last_conflict_oid=None) is True


def test_conflict_dispatch_on_behind():
    # BEHIND is an actionable clean-update state for resolve-conflicts
    assert prwatch.conflict_need_dispatch(merge("BEHIND"), last_conflict_oid=None) is True


def test_conflict_no_dispatch_on_clean():
    assert prwatch.conflict_need_dispatch(merge("CLEAN"), last_conflict_oid=None) is False


def test_conflict_no_dispatch_on_blocked_or_unstable():
    # BLOCKED/UNSTABLE = failing checks / pending review, NOT a merge conflict
    assert prwatch.conflict_need_dispatch(merge("BLOCKED"), last_conflict_oid=None) is False
    assert prwatch.conflict_need_dispatch(merge("UNSTABLE"), last_conflict_oid=None) is False


def test_conflict_no_dispatch_on_unknown():
    # GitHub hasn't computed mergeability yet — do not act
    assert prwatch.conflict_need_dispatch(merge("UNKNOWN"), last_conflict_oid=None) is False


def test_conflict_no_redispatch_for_same_unchanged_state():
    m = merge("DIRTY", base="b1", head="h1")
    oid = prwatch.conflict_oid(m)
    assert prwatch.conflict_need_dispatch(m, last_conflict_oid=oid) is False


def test_conflict_redispatch_when_base_moved():
    handled = prwatch.conflict_oid(merge("DIRTY", base="b1", head="h1"))
    moved = merge("DIRTY", base="b2", head="h1")
    assert prwatch.conflict_need_dispatch(moved, last_conflict_oid=handled) is True


def test_conflict_redispatch_when_head_moved():
    handled = prwatch.conflict_oid(merge("DIRTY", base="b1", head="h1"))
    moved = merge("DIRTY", base="b1", head="h2")
    assert prwatch.conflict_need_dispatch(moved, last_conflict_oid=handled) is True


# --- next_checkpoint ---------------------------------------------------------

def test_checkpoint_advances_comments_to_newest_timestamp():
    env = envelope(unaddressed=2, items=[
        {"created_at": "2026-06-25T10:00:00Z"},
        {"created_at": "2026-06-25T12:00:00Z"},
        {"created_at": "2026-06-25T11:00:00Z"},
    ])
    cp = prwatch.next_checkpoint(
        prior={}, envelope=env, merge=merge(),
        dispatch_comments=True, dispatch_conflict=False,
    )
    assert cp["comments_since"] == "2026-06-25T12:00:00Z"


def test_checkpoint_falls_back_to_now_when_items_lack_created_at():
    # malformed envelope: counts say unaddressed>0 but items carry no created_at.
    # Without a fallback the checkpoint would never advance → re-dispatch forever.
    env = {"ok": True, "counts": {"unaddressed": 2},
           "unaddressed": [{"body": "x"}, {"body": "y"}]}
    cp = prwatch.next_checkpoint(
        prior={}, envelope=env, merge=merge(),
        dispatch_comments=True, dispatch_conflict=False, now="2026-06-25T15:00:00Z",
    )
    assert cp["comments_since"] == "2026-06-25T15:00:00Z"


def test_checkpoint_prefers_envelope_timestamp_over_now():
    env = envelope(unaddressed=1, items=[{"created_at": "2026-06-25T12:00:00Z"}])
    cp = prwatch.next_checkpoint(
        prior={}, envelope=env, merge=merge(),
        dispatch_comments=True, dispatch_conflict=False, now="2026-06-25T15:00:00Z",
    )
    assert cp["comments_since"] == "2026-06-25T12:00:00Z"


def test_checkpoint_unadvanced_when_no_timestamp_and_no_now():
    # both sources absent → can't advance; surfaced as a degraded state by caller
    env = {"ok": True, "counts": {"unaddressed": 1}, "unaddressed": [{"body": "x"}]}
    cp = prwatch.next_checkpoint(
        prior={}, envelope=env, merge=merge(),
        dispatch_comments=True, dispatch_conflict=False, now=None,
    )
    assert "comments_since" not in cp


def test_checkpoint_does_not_advance_skipped_signal():
    # conflict dispatched, comments NOT — comments_since must stay un-advanced
    prior = {"comments_since": "2026-06-01T00:00:00Z"}
    cp = prwatch.next_checkpoint(
        prior=prior,
        envelope=envelope(unaddressed=3, items=[{"created_at": "2026-06-25T12:00:00Z"}]),
        merge=merge("DIRTY", base="b9", head="h9"),
        dispatch_comments=False, dispatch_conflict=True,
    )
    assert cp["comments_since"] == "2026-06-01T00:00:00Z"   # untouched
    assert cp["conflict_oid"] == "b9:h9"                    # advanced


def test_checkpoint_preserves_unrelated_prior_keys():
    prior = {"conflict_oid": "old:old"}
    cp = prwatch.next_checkpoint(
        prior=prior,
        envelope=envelope(unaddressed=1, items=[{"created_at": "2026-06-25T12:00:00Z"}]),
        merge=merge(),
        dispatch_comments=True, dispatch_conflict=False,
    )
    assert cp["conflict_oid"] == "old:old"                  # carried over
    assert cp["comments_since"] == "2026-06-25T12:00:00Z"


# --- decide ------------------------------------------------------------------

def test_decide_no_dispatch_when_nothing_pending():
    d = prwatch.decide(merge=merge("CLEAN"), envelope=envelope(0), checkpoint={})
    assert d["dispatch"] is False
    assert d["reasons"] == []


def test_decide_dispatches_on_comments_only():
    d = prwatch.decide(
        merge=merge("CLEAN"),
        envelope=envelope(2, items=[{"created_at": "2026-06-25T12:00:00Z"}]),
        checkpoint={},
    )
    assert d["dispatch"] is True
    assert d["reasons"] == ["comments"]
    assert d["checkpoint"]["comments_since"] == "2026-06-25T12:00:00Z"


def test_decide_dispatches_on_conflict_only():
    d = prwatch.decide(merge=merge("DIRTY", base="b1", head="h1"),
                       envelope=envelope(0), checkpoint={})
    assert d["dispatch"] is True
    assert d["reasons"] == ["conflict"]
    assert d["checkpoint"]["conflict_oid"] == "b1:h1"


def test_decide_dispatches_on_both():
    d = prwatch.decide(
        merge=merge("DIRTY", base="b1", head="h1"),
        envelope=envelope(1, items=[{"created_at": "2026-06-25T12:00:00Z"}]),
        checkpoint={},
    )
    assert d["dispatch"] is True
    assert d["reasons"] == ["comments", "conflict"]


def test_decide_passes_now_through_to_comments_fallback():
    env = {"ok": True, "counts": {"unaddressed": 1}, "unaddressed": [{"body": "x"}]}
    d = prwatch.decide(merge=merge("CLEAN"), envelope=env, checkpoint={},
                       now="2026-06-25T15:00:00Z")
    assert d["dispatch"] is True
    assert d["checkpoint"]["comments_since"] == "2026-06-25T15:00:00Z"


def test_decide_respects_prior_checkpoint_for_dedup():
    # same conflict state already handled, no new comments → no dispatch
    m = merge("DIRTY", base="b1", head="h1")
    d = prwatch.decide(
        merge=m, envelope=envelope(0),
        checkpoint={"conflict_oid": prwatch.conflict_oid(m)},
    )
    assert d["dispatch"] is False
