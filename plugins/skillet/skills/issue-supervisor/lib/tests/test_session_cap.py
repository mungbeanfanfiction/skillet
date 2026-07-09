"""Structural guards for the per-session wall-clock cap + shared reaper in common.sh.

Fast static assertions over the shell source — the mechanism is easy to regress in ways
that silently disable the cap or orphan children (dropping the process-group signal,
reintroducing a `timeout(1)`/`setsid` dependency macOS lacks, or letting a reap path
diverge). The behavioral proofs sleep past the cap and would make this suite slow/flaky,
so they live on-demand in scripts/tests/: reaper_behavior.sh (whole-tree reap) and
reap_dead_leader.sh (leader dead, xdist workers still reaped via the group).
"""
from pathlib import Path

COMMON = (Path(__file__).resolve().parents[2] / "scripts" / "common.sh").read_text()
SCRIPTS = (Path(__file__).resolve().parents[2] / "scripts")


def test_session_timeout_default_is_set_and_overridable():
    # A default cap must exist (the bug was NO cap). Uses `-` not `:-` so an explicitly
    # EMPTY override survives to the disable branch instead of being reset to the default.
    assert 'SKILLET_SESSION_TIMEOUT_SECONDS="${SKILLET_SESSION_TIMEOUT_SECONDS-3600}"' in COMMON
    assert ":-2700}" not in COMMON  # the old bug: `:-` reset empty to default; must be gone


def test_reaper_signals_the_process_group_not_just_the_pid():
    # Killing the bare pid orphans claude's CI child + xdist workers — the exact leak this
    # exists to stop. The shared reap_pid MUST signal the group (kill … -"$pid").
    assert "reap_pid()" in COMMON
    assert 'kill -TERM -- "-$pid"' in COMMON
    assert 'kill -KILL -- "-$pid"' in COMMON


def test_reaper_handles_dead_leader_with_live_children():
    # The runaway case is claude (group leader) exiting while its xdist workers keep
    # burning CPU. reap_pid must validate the group's oldest live member when the leader
    # is dead (pid_predates_file can't read a dead pid) and still sweep the group.
    assert "group_predates_file" in COMMON


def test_session_gets_its_own_process_group():
    # The group signal only works if the session IS a group leader. macOS has no `setsid`,
    # so we rely on bash job control (`set -m`) to make the spawn a leader.
    assert "set -m" in COMMON
    # Must not INVOKE setsid (absent on macOS). A comment about why we avoid it is fine;
    # a command call — `setsid ` or a `command -v setsid` guard — is not.
    assert "setsid " not in COMMON
    assert "command -v setsid" not in COMMON


def test_cap_does_not_depend_on_timeout_binary():
    # macOS ships no `timeout(1)`; a cap that needs it is inert exactly where it's needed.
    assert "command -v timeout" not in COMMON
    assert "gtimeout" not in COMMON


def test_reaper_guards_against_pid_reuse():
    # A recycled pid/group must never be signalled: provenance is proven by START TIME
    # (pid or oldest group member predates the pidfile), and the timer confirms the pidfile
    # still names this exact session before reaping.
    assert "pid_predates_file" in COMMON
    assert '[ "$cur" = "$pid" ]' in COMMON


def test_reuse_guard_rechecked_before_delayed_sigkill():
    # The 30s TERM→KILL grace is a PID-reuse window: a pid recycled during the grace must
    # not be SIGKILLed. reap_pid re-validates provenance right before the delayed KILL.
    body = COMMON[COMMON.index("reap_pid()"):]
    # both kill branches re-run a predates check before their `kill -KILL`
    assert body.count("|| return 0") >= 4  # numeric guard + group/bare pre-KILL rechecks


def test_disabled_cap_skips_the_reaper():
    # 0 / empty / garbage disables the cap cleanly (no timer), never blocking a dispatch.
    assert "(''|0|*[!0-9]*) return" in COMMON


def test_all_spawn_paths_use_the_capped_helper():
    # Every path that spawns a claude session must route through spawn_capped_session — a
    # raw `nohup claude` in any of them would be an uncapped, un-grouped session. pr-watch
    # was the 4th spawn site the original PR missed.
    for name in ("dispatch.sh", "restart.sh", "resume.sh", "pr-watch.sh"):
        src = (SCRIPTS / name).read_text()
        assert "spawn_capped_session" in src, f"{name} does not use the capped spawn"
        assert "nohup" not in src, f"{name} still spawns claude directly, bypassing the cap"


def test_restart_reaps_via_the_shared_helper():
    # restart.sh's stall-reap (the MORE COMMON trigger than the wall clock) must use the
    # shared reap_pid so it group-kills too — not its old bare-pid `kill -TERM "$OLD_PID"`.
    src = (SCRIPTS / "restart.sh").read_text()
    assert "reap_pid" in src
    assert 'kill -TERM "$OLD_PID"' not in src  # the old bare-pid reap must be gone
