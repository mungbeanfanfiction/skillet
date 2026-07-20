---
name: cleanup-processes
description: Survey claude processes on this machine and safely reap the dead, orphaned, stale, or runaway ones — detached dispatched sessions whose supervisor is gone, sessions past their heartbeat window, or process groups pegging the CPU. Group-aware reaping (session + pytest/xdist workers + MCP servers go down together) reusing issue-supervisor's common.sh helpers. Interactive by default; supports a --noninteractive mode that reaps only provably-safe candidates. Use after a supervisor crash, a reboot that left zombies, or when claude processes are runaway.
argument-hint: "[--noninteractive]"
---

# Cleanup Processes Skill

Find and reap dead / orphaned / stale / runaway claude processes left behind when a
supervisor crashes, a machine reboots mid-run, or a detached session hangs after its
parent supervisor has exited. `/issue-supervisor` dispatches work as **detached**
`claude -p` sessions reparented to PID 1, and its stall detection only runs *during* a
survey — once the supervisor exits, nothing reaps stalled or runaway sessions. This
skill is the standalone, on-demand reaper for exactly those leftovers.

By default it never kills anything without explicit confirmation, and never touches the
session that invoked it or a session owned by a live supervisor.

## Classification

The survey script groups every claude process by its **process group** (so a session and
its xdist/MCP children are one unit) and labels each group:

- **🟢 healthy** — a live supervisor/sweeper loop owns the machine (a fresh lock dir) and
  this group maps to a registered worktree with a fresh heartbeat. Never reaped.
- **🟠 stale** — the group's worktree heartbeat is older than the stale window
  (default 15 min): the session is wedged. Reap candidate.
- **🔴 runaway** — some member of the group is pegging CPU (default ≥ 90%). Reap
  candidate even when a supervisor is live (a runaway must be stopped regardless).
- **⚫ orphaned** — no live supervisor owns it, or it maps to no worktree at all
  (reparented leftover). Reap candidate.
- **self** — the invoking session's own process tree. Never a candidate, never shown as
  reapable.

## Workflow

### 1. Survey

```bash
SKILL_DIR="<this skill dir>"   # plugins/skillet/skills/cleanup-processes
"$SKILL_DIR/scripts/survey-processes.sh"
```

It prints a JSON array, one object per group:
`{ pid, pgid, class, reason, worktree, cpu, is_self, supervisor_alive }`.
`pid` and `pgid` are the group leader (they are equal — sessions are group leaders).

If the array is empty, report "no claude processes found" and stop.

### 2. Present the candidates

Show a table grouped by class, e.g.:

```
CLASS       PGID     CPU    WORKTREE / NOTE
⚫ orphaned  98766    1.5%   auto-87-cursor-hooks-load-fail (no live supervisor)
🔴 runaway   47021   187%    auto-91-foo (group CPU 187% ≥ 90%)
🟠 stale     51233    2.0%   auto-90-bar (heartbeat 1840s old)
🟢 healthy   60011    8.0%   auto-92-baz (fresh heartbeat, live supervisor)
```

Reap candidates are everything **except** `healthy` and `self`.

### 3. Ask what to reap

Offer:
- Reap all candidates (orphaned + stale + runaway)
- Reap only orphaned
- Pick individually
- Cancel

Never offer to reap `healthy` or `self` groups.

**In `--noninteractive` mode, skip this step** and select the **provably-safe** subset:
`orphaned` groups (no owner — safe to reclaim), PLUS `runaway` groups whose
`supervisor_alive` is `false` (burning CPU with nothing watching). A `stale` group (may
be slow, not dead) and a runaway under a *live* supervisor (that supervisor's job to
reap) are left for the supervisor or a human — the same conservatism as
`/cleanup-worktrees` picking only the 🟢 bucket. Report what was skipped and why.

### 4. Reap the chosen groups

For each selected group, reap by pgid — group-aware, so the session, its xdist workers,
and MCP servers all go down together with no orphans. Pass a short TERM→KILL grace
(second arg, seconds) when reaping several groups so the flow isn't serialized on the
30 s default per group:

```bash
"$SKILL_DIR/scripts/reap-group.sh" <pgid> 5
```

`reap-group.sh` reuses `common.sh`'s `reap_pid` (with its PID-reuse provenance guards)
when the group's `session.pid` file is on disk, and falls back to a direct group
TERM→KILL escalation for a pidfile-less orphan. It refuses any pgid in the invoking
process's ancestor chain, so it can never kill the session running this skill.

### 5. Report

Summarize:
- N groups reaped (by class)
- K candidates skipped (and why — e.g. stale left for the supervisor)
- The `healthy` / `self` groups that were never touched

Re-run the survey once more and show what remains.

## Safety

- **Never reaps its own invoking session.** Claude Code runs each Bash call in its own
  process group, so the invoking `claude -p` session is an *ancestor* group, not the
  current one. Both scripts exclude every ancestor pgid (`self-pgids.sh`); guarding only
  the immediate pgid would not protect the invoking session.
- **Never reaps a healthy session under a live supervisor** (fresh `supervisor.lock`/
  `sweeper.lock`). A *runaway* is the sole exception — stopped even under a live
  supervisor, but interactively only; `--noninteractive` leaves those alone.
- **Group-aware** reaping leaves no orphaned xdist workers or MCP servers behind, and is
  **portable** (macOS + Linux; no `ps -g`, `timeout`, `setsid`).
- **PID-reuse safe** — the `reap_pid` path validates provenance by start time vs. pidfile
  mtime; the pidfile-less path re-confirms the group still hosts a `claude` process
  before signalling.

## Tuning (env vars)

- `SKILLET_RUNAWAY_CPU` — CPU% threshold for `runaway` (default 90).
- `SKILLET_STALE_HEARTBEAT_SECONDS` — stale-heartbeat window (default 900, matching the
  supervisor).
- `LOCK_TTL_HOURS` — max age of a supervisor lock still counted "live" (default 6).
