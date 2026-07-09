"""Structural guards for the per-session wall-clock cap in scripts/common.sh.

These are fast static assertions over the shell source — the mechanism is easy to
regress in ways that silently disable the cap or orphan children (e.g. dropping the
process-group signal, or reintroducing a `timeout(1)`/`setsid` dependency macOS lacks).
The full behavioral proof (spawn a fake session + child, confirm the whole tree is
reaped) lives in scripts/tests/reaper_behavior.sh, run on demand — it sleeps past the
cap and would make this unit suite slow and timing-flaky.
"""
from pathlib import Path

COMMON = (Path(__file__).resolve().parents[2] / "scripts" / "common.sh").read_text()
SCRIPTS = (Path(__file__).resolve().parents[2] / "scripts")


def test_session_timeout_default_is_set_and_overridable():
    # A default cap must exist (the bug was NO cap), and honor an operator override.
    assert 'SKILLET_SESSION_TIMEOUT_SECONDS="${SKILLET_SESSION_TIMEOUT_SECONDS:-2700}"' in COMMON


def test_reaper_signals_the_process_group_not_just_the_pid():
    # Killing the bare pid orphans claude's CI child + xdist workers — the exact leak
    # this cap exists to stop. The reaper MUST signal the group (kill … -"$cur").
    assert 'kill -TERM -- "-$cur"' in COMMON
    assert 'kill -KILL -- "-$cur"' in COMMON


def test_session_gets_its_own_process_group():
    # The group signal above only works if the session IS a group leader. macOS has no
    # `setsid`, so we rely on bash job control (`set -m`) to make the spawn a leader.
    assert "set -m" in COMMON
    # Must not INVOKE setsid (absent on macOS). A comment mentioning why we avoid it is
    # fine; a command call — `setsid ` or a `command -v setsid` guard — is not.
    assert "setsid " not in COMMON
    assert "command -v setsid" not in COMMON


def test_cap_does_not_depend_on_timeout_binary():
    # macOS ships no `timeout(1)`; a cap that needs it is inert exactly where it's needed.
    # Guard against an INVOCATION, not the word (comments may explain the choice).
    assert "command -v timeout" not in COMMON
    assert "gtimeout" not in COMMON


def test_reaper_guards_against_pid_reuse():
    # A recycled pid must never be signalled: the reaper re-reads the pidfile, confirms
    # the pid is unchanged, still alive, and predates the pidfile before killing.
    assert "pid_predates_file" in COMMON
    assert '[ "$cur" = "$pid" ]' in COMMON


def test_disabled_cap_skips_the_reaper():
    # 0 / empty / garbage disables the cap cleanly (no timer), never blocking a dispatch.
    assert "(''|0|*[!0-9]*) return" in COMMON


def test_all_three_spawn_scripts_use_the_capped_helper():
    # dispatch / restart / resume must all route through spawn_capped_session — a raw
    # `nohup claude` in any of them would be an uncapped session.
    for name in ("dispatch.sh", "restart.sh", "resume.sh"):
        src = (SCRIPTS / name).read_text()
        assert "spawn_capped_session" in src, f"{name} does not use the capped spawn"
        assert "nohup" not in src, f"{name} still spawns claude directly, bypassing the cap"
