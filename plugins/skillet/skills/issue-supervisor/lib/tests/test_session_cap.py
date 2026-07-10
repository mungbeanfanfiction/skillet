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
    # exists to stop. The shared reap_pid MUST prefer the GROUP target (`target="-$pid"`).
    assert "reap_pid()" in COMMON
    assert 'target="-$pid"' in COMMON            # group is the primary target
    assert 'kill -TERM -- "$target"' in COMMON
    assert 'kill -KILL -- "$target"' in COMMON


def test_reaper_handles_dead_leader_with_live_children():
    # The runaway case is claude (group leader) exiting while its xdist workers keep burning
    # CPU. reap_pid must validate a surviving group member when the leader is dead
    # (pid_predates_file can't read a dead pid) and still sweep the group.
    assert "group_predates_file" in COMMON


def test_group_enumeration_is_portable_not_ps_dash_g():
    # `ps -g N` means process-GROUP on macOS/BSD but SESSION-id on Linux/procps. Since
    # sessions get `set -m` (new group) not setsid (new session), pgid != sid on Linux, so
    # `ps -g $pgid` would return the wrong/empty set and the dead-leader reap would no-op
    # there. Enumerate by post-filtering the pgid column instead so it means the same thing
    # on both platforms.
    assert "group_members()" in COMMON
    assert "ps -Ao pid=,pgid=" in COMMON
    assert 'ps -o pid= -g "$pgid"' not in COMMON   # the non-portable form must be gone


def test_reaper_polls_rather_than_blind_sleeping_the_cap():
    # A session finishing early must free the detached timer promptly, not leave an
    # hour-long `sleep` parked. The reaper loops in short steps and exits when the session
    # is gone or the pidfile was overwritten — it must NOT `sleep "$cap"` in one shot.
    assert 'sleep "$cap"' not in COMMON
    assert "step=15" in COMMON
    assert 'while [ "$waited" -lt "$cap" ]' in COMMON


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
    # The TERM→KILL grace is a PID/PGID-reuse window: a pid/group recycled during the grace
    # must not be SIGKILLed. reap_pid re-validates provenance right before the delayed KILL,
    # with the SAME predicate the target was chosen by (group-inclusive for a group target,
    # pid-only for a bare target — a group-inclusive recheck on a bare target would defeat
    # the reuse guard on an unrelated recycled pgid).
    body = COMMON[COMMON.index("reap_pid()"):]
    kill_idx = body.index("kill -KILL")
    recheck = body[:kill_idx]
    assert "_group_provenance_ok" in recheck        # group target re-runs group provenance
    assert "pid_predates_file" in recheck           # bare target re-runs pid-only provenance
    assert 'if [ -n "$grouped" ]' in recheck        # recheck branches on which target was picked


def test_restart_uses_a_short_synchronous_grace():
    # restart.sh calls reap_pid INLINE on the survey's critical path, so it must pass a short
    # grace (not the default 30s) to avoid stalling the loop up to 30s per hung worktree.
    src = (SCRIPTS / "restart.sh").read_text()
    assert 'reap_pid "$OLD_PID" "$PID_FILE" 5' in src


def test_restart_only_logs_reap_when_something_was_alive():
    # reap_pid always returns 0 (even for a dead/recycled pid), so gating the "reaped" log on
    # its exit status would print on every ordinary exited-session restart. restart.sh must
    # check liveness up front — AND provenance, so a recycled-but-live stranger pid doesn't
    # log a phantom reap — mirroring exactly what reap_pid acts on.
    src = (SCRIPTS / "restart.sh").read_text()
    assert "WAS_ALIVE" in src
    assert 'reap_pid "$OLD_PID" "$PID_FILE" && ' not in src  # the misleading gate must be gone
    # liveness alone isn't enough; the log guard must also confirm provenance
    assert "_group_provenance_ok" in src
    assert "pid_predates_file" in src


def test_reap_pid_grace_loop_is_zero_safe():
    # The grace is caller-tunable via ${3:-30}; `seq 1 0` emits "1 0" (2 iterations), so the
    # loop must be a numeric while, not a seq expansion, to honor grace=0 (immediate KILL).
    body = COMMON[COMMON.index("reap_pid()"):]
    assert 'seq 1 "$grace"' not in body
    assert 'while [ "$i" -lt "$grace" ]' in body


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
