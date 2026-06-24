# Issue Supervisor v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build two `/loop`-driven, repo-agnostic skillet skills — `issue-supervisor` (recurring ~5h loop that dispatches GitHub issues / checklist tasks to background `claude` sessions in worktrees, restarts mechanical stalls, refills 3 slots, and grooms the backlog) and `question-sweeper` (~1h loop that routes design questions to a human) — sharing a tested, stdlib-only `supervisorlib` Python package, reusing the existing `review-fix` skill, and retiring `drain-queue`.

**Architecture:** Deterministic logic (registry I/O, worktree-state classification, slot accounting, eligibility filtering, restart-count parsing, answer detection, queue parsing, spawn argv) lives in `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/` as a stdlib-only Python package with plain-pytest unit tests. Thin, injection-safe bash scripts shell out to that package and to `gh`/`git`/`claude`. Model judgment (triage, decomposition, review-loop, question authoring) lives in `SKILL.md`. State is ground-truth every cycle; the only persisted state is a worktree registry JSON in the **target repo's** `.claude/` (the plugin install ships code only). Everything is repo-agnostic: repo slug and base branch are derived from `gh repo view`, never hard-coded.

**Tech Stack:** Python 3 (stdlib only — no Django, no third-party deps), pytest, bash, `gh` CLI, `git worktree`, `claude -p` headless, `jq`. Plan + spec live in `docs/superpowers/`. Lib tests are wired into skillet's `npm test` via a new `npm run test:lib`.

**Spec:** `docs/superpowers/specs/2026-06-23-issue-supervisor-v2-design.md`

> **Post-rebase integration (2026-06-23):** after Tasks 1–19, the branch was
> rebased onto skillet `main` (v0.8.0) and integrated with three sibling skills.
> These changes are NOT reflected in the task-by-task snippets below — see the
> spec's "Integration with sibling skillet skills" section and the commit
> `feat(supervisor): route explore-issues, sync-repo-labels bootstrap, worktree-status report`:
> (1) `gh.is_explore` + a step-0 routing preamble in `spawn.PIPELINE` send
> `explore`-labeled issues to the `explore-issue` skill; (2) `dispatch.sh` gained a
> 5th `[labels]` arg and writes a `**Labels:**` line into `task.md`; (3) bootstrap
> calls `/sync-repo-labels` then adds only `epic`/`loop-generated`/`needs-input`;
> (4) the cycle report invokes `worktree-status` (additive — `survey.sh` still
> drives automated decisions).
>
> **Live-dispatch fixes (2026-06-23):** a real smoke-test (`dispatch.sh` against a
> throwaway issue) surfaced two bugs the task-by-task snippets below still show
> uncorrected — see commit `fix(supervisor): resolve claude binary + survive
> grep-no-match in dispatch`: (a) the env-file `grep` in `dispatch.sh` aborts under
> `set -o pipefail` when it matches nothing — it must be wrapped
> `{ grep ... || true; }`; (b) `claude` is commonly a shell ALIAS, so a bare
> `nohup claude` fails in the detached subshell — `common.sh` now provides
> `resolve_claude()` (`$CLAUDE_BIN` → `command -v claude` → `~/.claude/local/claude`)
> and all three spawn scripts call `CLAUDE="$(resolve_claude)"` then
> `nohup "$CLAUDE" ...`. After both fixes the end-to-end dispatch was verified live.

---

## File Structure & Shared Interfaces

Lock these names — every task depends on them being identical across phases.

```
plugins/skillet/skills/issue-supervisor/
  SKILL.md                       # ~5h procedure (Task 16)
  lib/
    supervisorlib/
      __init__.py
      paths.py                   # resolve target-repo .claude/ runtime-state dir (Task 1)
      registry.py                # owned-worktree registry read/write (Task 2)
      gitstatus.py               # pure git-output parsers (Task 3)
      state.py                   # WorktreeState enum + classify() (Task 4)
      slots.py                   # slot accounting (Task 5)
      gh.py                      # gh issue/PR pure filters (Task 6)
      queue_source.py            # markdown-checklist parser (Task 7)
      survey.py                  # assemble survey JSON (Task 8)
      spawn.py                   # build claude spawn argv + pipeline prompts (Task 10)
      questions.py               # question.md parse + answer detection (Task 13)
      runreport.py               # run-report markdown writer (Task 9)
    tests/
      test_paths.py  test_registry.py  test_gitstatus.py  test_state.py
      test_slots.py  test_gh.py  test_queue_source.py  test_survey.py
      test_spawn.py  test_questions.py  test_runreport.py
    pytest.ini                   # standalone pytest config (no Django)
  scripts/
    common.sh                    # shared: resolve REPO/BASE/STATE_DIR/LIB_DIR/CI cmd (Task 11)
    survey.sh                    # calls supervisorlib.survey → JSON (Task 12)
    dispatch.sh                  # create worktree + task.md + spawn (Task 14)
    restart.sh                   # respawn in existing worktree, burns restart budget (Task 15)
    resume.sh                    # respawn after answered question, NO restart increment (Task 15)
plugins/skillet/skills/question-sweeper/
  SKILL.md                       # ~1h sweep procedure (Task 17)
  scripts/
    sweep.sh                     # calls supervisorlib.questions → JSON (Task 13)

docs/superpowers/questions/.gitkeep    # one <issue#>.md per queued question (runtime, in target repo)
docs/superpowers/runs/.gitkeep         # run-reports (runtime)
```

**Runtime-state location (the portability rule).** The plugin install dir is treated as read-only code. All mutable state lives under the **target repo's** `.claude/issue-supervisor/`:

```
<target-repo>/.claude/issue-supervisor/registry.json   # owned-worktree registry
<target-repo>/.claude/issue-supervisor/supervisor.lock  # 5h loop concurrency lock
<target-repo>/.claude/issue-supervisor/sweeper.lock     # 1h loop concurrency lock
<target-repo>/.claude/worktrees/auto-<n>-<slug>/        # per-issue worktrees
```

`paths.py` computes this dir from `git rev-parse --show-toplevel`. Scripts resolve their own lib via `BASH_SOURCE` (works regardless of plugin install path).

**Shared registry schema** (`<target-repo>/.claude/issue-supervisor/registry.json`, created at runtime, git-ignored in the target repo):
```json
{
  "worktrees": [
    {
      "issue": 489,
      "path": "/abs/path/.claude/worktrees/auto-489-clubs",
      "branch": "auto-489-clubs",
      "source": "label",
      "created_at": "2026-06-23T10:00:00Z"
    }
  ]
}
```
`source` is `"label"` (GitHub issue) or `"file"` (markdown-checklist task); file tasks skip issue-specific steps (assignment, decomposition, issue comments).

**Shared `WorktreeState` enum** (string values, used in every JSON payload):
`working` | `needs-input` | `stalled` | `pr-open` | `blocked`

**In-flight definition:** a worktree counts toward the 3-slot cap iff its state is `working` or `stalled`.

**Shared `task.md` template** (written by `dispatch.sh`, read by sessions + restart/resume):
```markdown
# Task — issue #<N>
**Goal:** <issue title or checklist item>
**Source:** <label | file>
**Acceptance criteria:** <from issue body, or the checklist line>

## Pipeline stage
<one of: pickup | work | review | ci | done>

## Restart count
0

## Progress log
- <timestamp> dispatched
```

**Shared `question.md` template** (written by a session, parsed by `questions.py`):
```markdown
# Question — issue #<N>
<the design question>

## Options
1. <option> — <tradeoff>   (recommended)
2. <option> — <tradeoff>

## Context
<what the session was doing, relevant files>

## Answer
<!-- empty until the user fills it -->
```

**Shared `claude` spawn argv** (verified against local CLI in Task 18):
```bash
claude -p "<prompt>" --permission-mode acceptEdits --add-dir <worktree>
```
Launched via `nohup ... &`, PID captured to `<worktree>/.claude/session.pid`, output to `<worktree>/.claude/session.log`.

**CI-command detection order** (per spec, used by the per-issue pipeline and documented in `common.sh`): `make ci` → `make agent-ci` → `npm test` / `npm run test` → `pytest` → a check documented in the repo's CLAUDE.md/README → else record "no check command found" and proceed.

---

## Phase 1 — Runtime paths, registry & state primitives (read-only, no spawning)

### Task 1: Runtime-state path resolution

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/__init__.py` (empty)
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/paths.py`
- Create: `plugins/skillet/skills/issue-supervisor/lib/pytest.ini`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_paths.py`

- [ ] **Step 1: Create the standalone pytest config**

Create `plugins/skillet/skills/issue-supervisor/lib/pytest.ini`:
```ini
[pytest]
testpaths = tests
python_files = test_*.py
pythonpath = .
addopts = -q
```

- [ ] **Step 2: Write the failing test**

Create `plugins/skillet/skills/issue-supervisor/lib/tests/test_paths.py`:
```python
from pathlib import Path
from supervisorlib import paths


def test_state_dir_is_under_repo_claude(tmp_path):
    assert paths.state_dir(repo_root=tmp_path) == tmp_path / ".claude" / "issue-supervisor"


def test_registry_path_lives_in_state_dir(tmp_path):
    assert paths.registry_path(repo_root=tmp_path) == (
        tmp_path / ".claude" / "issue-supervisor" / "registry.json"
    )


def test_worktrees_dir_is_repo_claude_worktrees(tmp_path):
    assert paths.worktrees_dir(repo_root=tmp_path) == tmp_path / ".claude" / "worktrees"


def test_lock_path_names_the_loop(tmp_path):
    assert paths.lock_path(repo_root=tmp_path, loop="supervisor").name == "supervisor.lock"
    assert paths.lock_path(repo_root=tmp_path, loop="sweeper").name == "sweeper.lock"


def test_ensure_state_dir_creates_it(tmp_path):
    d = paths.ensure_state_dir(repo_root=tmp_path)
    assert d.is_dir()
    assert d == tmp_path / ".claude" / "issue-supervisor"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_paths.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib'` (then, after `__init__.py`, `No module named 'supervisorlib.paths'`).

- [ ] **Step 4: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/__init__.py` (empty file).

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/paths.py`:
```python
"""Resolve runtime-state paths in the TARGET repo's .claude/ dir.

The plugin install dir is code-only and treated read-only; all mutable
supervisor state lives under <repo_root>/.claude/issue-supervisor/. Callers
pass repo_root (from `git rev-parse --show-toplevel`) so these stay pure."""
from pathlib import Path

_SUBDIR = "issue-supervisor"


def state_dir(*, repo_root) -> Path:
    return Path(repo_root) / ".claude" / _SUBDIR


def registry_path(*, repo_root) -> Path:
    return state_dir(repo_root=repo_root) / "registry.json"


def worktrees_dir(*, repo_root) -> Path:
    return Path(repo_root) / ".claude" / "worktrees"


def lock_path(*, repo_root, loop: str) -> Path:
    return state_dir(repo_root=repo_root) / f"{loop}.lock"


def ensure_state_dir(*, repo_root) -> Path:
    d = state_dir(repo_root=repo_root)
    d.mkdir(parents=True, exist_ok=True)
    return d
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_paths.py -q`
Expected: PASS — 5 passed.

- [ ] **Step 6: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/__init__.py \
        plugins/skillet/skills/issue-supervisor/lib/supervisorlib/paths.py \
        plugins/skillet/skills/issue-supervisor/lib/pytest.ini \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_paths.py
git commit -m "feat(supervisor): runtime-state path resolution in target repo"
```

---

### Task 2: Worktree registry read/write

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/registry.py`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_registry.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_registry.py`:
```python
from supervisorlib import registry


def test_load_missing_file_returns_empty(tmp_path):
    assert registry.load(tmp_path / "registry.json") == {"worktrees": []}


def test_add_then_load_roundtrip(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=489, path="/wt/auto-489", branch="auto-489",
                 source="label", created_at="2026-06-23T10:00:00Z")
    reg = registry.load(p)
    assert reg["worktrees"][0]["issue"] == 489
    assert reg["worktrees"][0]["source"] == "label"


def test_is_owned_true_for_registered_path(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=1, path="/wt/a", branch="a", source="label", created_at="t")
    assert registry.is_owned(p, "/wt/a") is True
    assert registry.is_owned(p, "/wt/other") is False


def test_remove_by_path(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=1, path="/wt/a", branch="a", source="label", created_at="t")
    registry.remove(p, "/wt/a")
    assert registry.load(p) == {"worktrees": []}


def test_issues_lists_registered_numbers(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=1, path="/wt/a", branch="a", source="label", created_at="t")
    registry.add(p, issue=2, path="/wt/b", branch="b", source="file", created_at="t")
    assert sorted(registry.issues(p)) == [1, 2]


def test_issue_for_path_returns_number_or_none(tmp_path):
    p = tmp_path / "registry.json"
    registry.add(p, issue=7, path="/wt/a", branch="a", source="label", created_at="t")
    assert registry.issue_for_path(p, "/wt/a") == 7
    assert registry.issue_for_path(p, "/wt/missing") is None


def test_add_is_atomic_no_partial_file(tmp_path, monkeypatch):
    # _save writes to a temp file then renames, so a crash mid-write never
    # leaves a half-written registry.json. Verify the temp path is distinct.
    p = tmp_path / "registry.json"
    registry.add(p, issue=1, path="/wt/a", branch="a", source="label", created_at="t")
    assert p.exists()
    assert not (tmp_path / "registry.json.tmp").exists()  # tmp cleaned up after rename
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_registry.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib.registry'`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/registry.py`:
```python
"""Owned-worktree registry. The only persisted supervisor state.
Writes are atomic (temp file + rename) so a crash never corrupts it."""
import json
import os
from pathlib import Path


def load(registry_path) -> dict:
    p = Path(registry_path)
    if not p.exists():
        return {"worktrees": []}
    return json.loads(p.read_text())


def _save(registry_path, data: dict) -> None:
    p = Path(registry_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(p.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(tmp, p)


def add(registry_path, *, issue, path, branch, source, created_at) -> None:
    data = load(registry_path)
    data["worktrees"].append({
        "issue": issue, "path": path, "branch": branch,
        "source": source, "created_at": created_at,
    })
    _save(registry_path, data)


def remove(registry_path, path: str) -> None:
    data = load(registry_path)
    data["worktrees"] = [w for w in data["worktrees"] if w["path"] != path]
    _save(registry_path, data)


def is_owned(registry_path, path: str) -> bool:
    return any(w["path"] == path for w in load(registry_path)["worktrees"])


def issues(registry_path) -> list:
    return [w["issue"] for w in load(registry_path)["worktrees"]]


def issue_for_path(registry_path, path: str):
    return next((w["issue"] for w in load(registry_path)["worktrees"]
                 if w["path"] == path), None)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_registry.py -q`
Expected: PASS — 7 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/registry.py \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_registry.py
git commit -m "feat(supervisor): atomic owned-worktree registry"
```

---

### Task 3: Pure git-status parsers

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/gitstatus.py`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_gitstatus.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_gitstatus.py`:
```python
from supervisorlib import gitstatus


def test_classify_porcelain_clean():
    assert gitstatus.classify_porcelain("") == "clean"


def test_classify_porcelain_uncommitted():
    assert gitstatus.classify_porcelain(" M file.py\n") == "uncommitted"


def test_classify_porcelain_untracked_only():
    assert gitstatus.classify_porcelain("?? new.py\n") == "uncommitted"


def test_ahead_count_parses_rev_list_output():
    assert gitstatus.ahead_count("3") == 3
    assert gitstatus.ahead_count("0") == 0
    assert gitstatus.ahead_count("") == 0
    assert gitstatus.ahead_count("not-a-number") == 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_gitstatus.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib.gitstatus'`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/gitstatus.py`:
```python
"""Pure parsers for git output. Subprocess calls live in the shell layer;
these take already-captured stdout so they are unit-testable."""


def classify_porcelain(porcelain: str) -> str:
    """`git status --porcelain` output → 'clean' | 'uncommitted'."""
    return "clean" if porcelain.strip() == "" else "uncommitted"


def ahead_count(rev_list_count: str) -> int:
    """`git rev-list --count @{u}..HEAD` output → int (0 if empty/no upstream)."""
    s = rev_list_count.strip()
    return int(s) if s.isdigit() else 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_gitstatus.py -q`
Expected: PASS — 4 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/gitstatus.py \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_gitstatus.py
git commit -m "feat(supervisor): pure git-status parsers"
```

---

### Task 4: Worktree state classification

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/state.py`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_state.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_state.py`:
```python
from supervisorlib import state
from supervisorlib.state import WorktreeState


def make(**kw):
    base = dict(
        process_alive=False, has_question_md=False, task_complete=False,
        has_open_pr=False, restart_count=0, task_md_present=True,
    )
    base.update(kw)
    return base


def test_pr_open_takes_precedence():
    assert state.classify(make(has_open_pr=True, process_alive=True)) == WorktreeState.PR_OPEN


def test_blocked_when_task_md_missing():
    assert state.classify(make(task_md_present=False)) == WorktreeState.BLOCKED


def test_needs_input_when_question_present():
    assert state.classify(make(has_question_md=True, process_alive=True)) == WorktreeState.NEEDS_INPUT


def test_blocked_when_restart_cap_reached():
    assert state.classify(make(restart_count=2)) == WorktreeState.BLOCKED


def test_blocked_when_task_complete_but_no_pr():
    assert state.classify(make(task_complete=True)) == WorktreeState.BLOCKED


def test_working_when_process_alive_no_question():
    assert state.classify(make(process_alive=True)) == WorktreeState.WORKING


def test_stalled_when_dead_incomplete_no_question():
    assert state.classify(make(process_alive=False)) == WorktreeState.STALLED


def test_in_flight_only_for_working_and_stalled():
    assert state.is_in_flight(WorktreeState.WORKING) is True
    assert state.is_in_flight(WorktreeState.STALLED) is True
    assert state.is_in_flight(WorktreeState.NEEDS_INPUT) is False
    assert state.is_in_flight(WorktreeState.PR_OPEN) is False
    assert state.is_in_flight(WorktreeState.BLOCKED) is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_state.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib.state'`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/state.py`:
```python
"""Worktree state classification. Order of checks encodes the spec's
precedence rules — the first matching check wins."""
from enum import Enum


class WorktreeState(str, Enum):
    WORKING = "working"
    NEEDS_INPUT = "needs-input"
    STALLED = "stalled"
    PR_OPEN = "pr-open"
    BLOCKED = "blocked"


RESTART_CAP = 2


def classify(facts: dict) -> WorktreeState:
    """facts keys: process_alive, has_question_md, task_complete, has_open_pr,
    restart_count, task_md_present. Returns the single authoritative state."""
    if facts["has_open_pr"]:
        return WorktreeState.PR_OPEN
    if not facts["task_md_present"]:
        return WorktreeState.BLOCKED
    if facts["has_question_md"]:
        return WorktreeState.NEEDS_INPUT
    if facts["restart_count"] >= RESTART_CAP:
        return WorktreeState.BLOCKED
    if facts["task_complete"]:
        return WorktreeState.BLOCKED  # marked done but no PR → needs a human
    if facts["process_alive"]:
        return WorktreeState.WORKING
    return WorktreeState.STALLED


def is_in_flight(s: WorktreeState) -> bool:
    return s in (WorktreeState.WORKING, WorktreeState.STALLED)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_state.py -q`
Expected: PASS — 8 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/state.py \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_state.py
git commit -m "feat(supervisor): worktree state classification with precedence"
```

---

### Task 5: Slot accounting

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/slots.py`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_slots.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_slots.py`:
```python
from supervisorlib import slots
from supervisorlib.state import WorktreeState as S

CAP = 3


def test_free_counts_only_in_flight():
    assert slots.free([S.WORKING, S.NEEDS_INPUT, S.PR_OPEN], cap=CAP) == 2


def test_free_zero_when_full():
    assert slots.free([S.WORKING, S.STALLED, S.WORKING], cap=CAP) == 0


def test_free_never_negative():
    assert slots.free([S.WORKING] * 5, cap=CAP) == 0


def test_is_full():
    assert slots.is_full([S.WORKING, S.STALLED, S.WORKING], cap=CAP) is True
    assert slots.is_full([S.WORKING], cap=CAP) is False
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_slots.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib.slots'`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/slots.py`:
```python
"""Slot accounting from ground-truth states each cycle. No shared counter
between loops — both derive from the same state list."""
from supervisorlib.state import is_in_flight


def free(states: list, *, cap: int = 3) -> int:
    in_flight = sum(1 for s in states if is_in_flight(s))
    return max(0, cap - in_flight)


def is_full(states: list, *, cap: int = 3) -> bool:
    return free(states, cap=cap) == 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_slots.py -q`
Expected: PASS — 4 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/slots.py \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_slots.py
git commit -m "feat(supervisor): slot accounting from ground-truth states"
```

---

## Phase 2 — GitHub filters, queue sources & survey assembly (read-only)

### Task 6: gh issue/PR pure filters

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/gh.py`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_gh.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_gh.py`:
```python
from supervisorlib import gh


def test_eligible_issues_filters_label_epic_and_ownership():
    issues = [
        {"number": 1, "labels": [{"name": "auto"}]},
        {"number": 2, "labels": [{"name": "auto"}, {"name": "epic"}]},   # epic excluded
        {"number": 3, "labels": [{"name": "bug"}]},                      # no auto
        {"number": 4, "labels": [{"name": "auto"}]},                     # owned, excluded
    ]
    result = gh.eligible_issues(issues, owned_issue_numbers=[4])
    assert [i["number"] for i in result] == [1]


def test_eligible_issues_sorted_lowest_first():
    issues = [
        {"number": 9, "labels": [{"name": "auto"}]},
        {"number": 3, "labels": [{"name": "auto"}]},
    ]
    assert [i["number"] for i in gh.eligible_issues(issues, owned_issue_numbers=[])] == [3, 9]


def test_open_pr_branches_set():
    prs = [{"headRefName": "auto-1-x"}, {"headRefName": "auto-2-y"}]
    assert gh.open_pr_branches(prs) == {"auto-1-x", "auto-2-y"}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_gh.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib.gh'`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/gh.py`:
```python
"""Pure filters over `gh` JSON. Subprocess invocation lives in the shell
layer; these take parsed JSON so they're unit-testable without network."""

GATE_LABEL = "auto"
EPIC_LABEL = "epic"


def _label_names(issue: dict) -> set:
    return {lbl["name"] for lbl in issue.get("labels", [])}


def eligible_issues(issues: list, *, owned_issue_numbers: list) -> list:
    owned = set(owned_issue_numbers)
    out = [
        i for i in issues
        if GATE_LABEL in _label_names(i)
        and EPIC_LABEL not in _label_names(i)
        and i["number"] not in owned
    ]
    return sorted(out, key=lambda i: i["number"])


def open_pr_branches(prs: list) -> set:
    return {pr["headRefName"] for pr in prs}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_gh.py -q`
Expected: PASS — 3 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/gh.py \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_gh.py
git commit -m "feat(supervisor): gh issue/PR pure filters"
```

---

### Task 7: Markdown-checklist queue source

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/queue_source.py`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_queue_source.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_queue_source.py`:
```python
from supervisorlib import queue_source

CHECKLIST = """# Tasks
- [ ] First task
- [x] Already done task
- [ ] Second task with `code`
  - [ ] nested unchecked (still a task)
not a task line
* [ ] alt-bullet task
"""


def test_unchecked_items_parsed_in_order(tmp_path):
    f = tmp_path / "queue.md"; f.write_text(CHECKLIST)
    items = queue_source.unchecked_items(f)
    assert items == [
        "First task",
        "Second task with `code`",
        "nested unchecked (still a task)",
        "alt-bullet task",
    ]


def test_checked_items_excluded(tmp_path):
    f = tmp_path / "queue.md"; f.write_text(CHECKLIST)
    assert "Already done task" not in queue_source.unchecked_items(f)


def test_empty_file_yields_no_items(tmp_path):
    f = tmp_path / "queue.md"; f.write_text("# Nothing here\n")
    assert queue_source.unchecked_items(f) == []


def test_slug_for_item_is_filesystem_safe():
    assert queue_source.slug("Fix the Login Button!") == "fix-the-login-button"
    assert queue_source.slug("a/b\\c:d") == "a-b-c-d"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_queue_source.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib.queue_source'`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/queue_source.py`:
```python
"""Markdown-checklist queue parser. Unchecked `- [ ]` / `* [ ]` lines (any
indent) become tasks, in document order. File tasks skip GitHub-issue-specific
machinery (assignment, decomposition, issue comments)."""
import re
from pathlib import Path

_UNCHECKED = re.compile(r"^\s*[-*]\s+\[ \]\s+(.*\S)\s*$")
_NONWORD = re.compile(r"[^a-z0-9]+")


def unchecked_items(path) -> list:
    out = []
    for line in Path(path).read_text().splitlines():
        m = _UNCHECKED.match(line)
        if m:
            out.append(m.group(1))
    return out


def slug(text: str) -> str:
    s = _NONWORD.sub("-", text.lower()).strip("-")
    return s
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_queue_source.py -q`
Expected: PASS — 4 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/queue_source.py \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_queue_source.py
git commit -m "feat(supervisor): markdown-checklist queue source parser"
```

---

### Task 8: Survey assembly (pure)

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/survey.py`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_survey.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_survey.py`:
```python
from supervisorlib import survey
from supervisorlib.state import WorktreeState as S


def test_assemble_produces_states_and_free_slots():
    worktree_facts = [
        {"issue": 1, "path": "/wt/1", "branch": "auto-1", "owned": True,
         "facts": {"process_alive": True, "has_question_md": False, "task_complete": False,
                   "has_open_pr": False, "restart_count": 0, "task_md_present": True}},
        {"issue": 2, "path": "/wt/2", "branch": "auto-2", "owned": True,
         "facts": {"process_alive": False, "has_question_md": True, "task_complete": False,
                   "has_open_pr": False, "restart_count": 0, "task_md_present": True}},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[{"number": 7}])
    by_issue = {w["issue"]: w for w in result["worktrees"]}
    assert by_issue[1]["state"] == S.WORKING.value
    assert by_issue[2]["state"] == S.NEEDS_INPUT.value
    assert result["free_slots"] == 2
    assert result["eligible_issues"] == [7]


def test_foreign_worktrees_never_consume_a_slot():
    worktree_facts = [
        {"issue": None, "path": "/wt/foreign", "branch": "fix/x", "owned": False,
         "facts": {"process_alive": False, "has_question_md": False, "task_complete": False,
                   "has_open_pr": False, "restart_count": 0, "task_md_present": False}},
    ]
    result = survey.assemble(worktree_facts=worktree_facts, eligible_issues=[])
    assert result["worktrees"][0]["owned"] is False
    assert result["free_slots"] == 3
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_survey.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib.survey'`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/survey.py`:
```python
"""Assemble the ground-truth survey JSON the SKILL.md consumes each cycle.
Foreign worktrees are reported but never counted toward slots."""
from supervisorlib import state as state_mod, slots


def assemble(*, worktree_facts: list, eligible_issues: list) -> dict:
    worktrees = []
    in_flight_states = []
    for w in worktree_facts:
        st = state_mod.classify(w["facts"])
        worktrees.append({
            "issue": w["issue"], "path": w["path"], "branch": w["branch"],
            "owned": w["owned"], "state": st.value,
        })
        if w["owned"]:
            in_flight_states.append(st)
    return {
        "worktrees": worktrees,
        "free_slots": slots.free(in_flight_states, cap=3),
        "eligible_issues": [i["number"] for i in eligible_issues],
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_survey.py -q`
Expected: PASS — 2 passed.

- [ ] **Step 5: Run the whole lib suite green**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest -q`
Expected: PASS — all Phase 1-2 tests (~37).

- [ ] **Step 6: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/survey.py \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_survey.py
git commit -m "feat(supervisor): survey assembly with slot-aware ground truth"
```

---

### Task 9: Run-report writer (drain-queue heritage)

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/runreport.py`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_runreport.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_runreport.py`:
```python
from supervisorlib import runreport


def test_render_has_three_sections():
    md = runreport.render(
        date="2026-06-23",
        shipped=[{"title": "Fix login", "pr_url": "http://pr/1", "summary": "2 fixes"}],
        skipped=[{"title": "Vague task", "reason": "no safe guess"}],
        flagged=[{"title": "Caching", "note": "needs human review"}],
    )
    assert "# Run report — 2026-06-23" in md
    assert "## Shipped" in md and "Fix login" in md and "http://pr/1" in md
    assert "## Skipped" in md and "no safe guess" in md
    assert "## Needs your attention" in md and "Caching" in md


def test_render_empty_sections_show_none():
    md = runreport.render(date="2026-06-23", shipped=[], skipped=[], flagged=[])
    assert "_none_" in md
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_runreport.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib.runreport'`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/runreport.py`:
```python
"""Render the cycle run-report markdown (inherited from drain-queue).
The shell layer captures the date and writes the file to docs/superpowers/runs/."""


def _section(title: str, lines: list) -> str:
    body = "\n".join(lines) if lines else "_none_"
    return f"## {title}\n{body}\n"


def render(*, date: str, shipped: list, skipped: list, flagged: list) -> str:
    shipped_lines = [f"- {s['title']} → {s['pr_url']} — {s['summary']}" for s in shipped]
    skipped_lines = [f"- {s['title']} — {s['reason']}" for s in skipped]
    flagged_lines = [f"- {f['title']} — {f['note']}" for f in flagged]
    return (
        f"# Run report — {date}\n\n"
        + _section("Shipped", shipped_lines) + "\n"
        + _section("Skipped", skipped_lines) + "\n"
        + _section("Needs your attention", flagged_lines)
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_runreport.py -q`
Expected: PASS — 2 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/runreport.py \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_runreport.py
git commit -m "feat(supervisor): run-report markdown writer"
```

---

## Phase 3 — Spawn argv, shared shell glue & survey script

### Task 10: claude spawn argv + pipeline prompts

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/spawn.py`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_spawn.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_spawn.py`:
```python
from supervisorlib import spawn


def test_build_argv_has_print_and_permission_flags():
    argv = spawn.build_argv(prompt="do the thing", worktree="/wt/1")
    assert argv[0] == "claude"
    assert argv[argv.index("-p") + 1] == "do the thing"
    assert argv[argv.index("--permission-mode") + 1] == "acceptEdits"
    assert argv[argv.index("--add-dir") + 1] == "/wt/1"


def test_dispatch_prompt_references_task_md_review_fix_and_escape_hatch():
    p = spawn.dispatch_prompt(issue=489)
    assert "489" in p
    assert ".claude/task.md" in p
    assert "review-fix" in p          # reuses the existing skillet skill
    assert "question.md" in p         # design-question escape hatch present


def test_restart_prompt_says_resume_from_stage():
    p = spawn.restart_prompt(issue=489)
    assert "resume" in p.lower()
    assert ".claude/task.md" in p


def test_resume_prompt_mentions_the_answer():
    p = spawn.resume_prompt(issue=489)
    assert "answer" in p.lower()
    assert "489" in p
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_spawn.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib.spawn'`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/spawn.py`:
```python
"""Build the claude spawn argv + the prompts a dispatched/restarted/resumed
session runs. The per-issue pipeline reuses skillet's `review-fix` skill for
the review/auto-fix loop instead of calling /code-review directly."""

PIPELINE = """\
Run this pipeline for the task, logging each completed stage to the
`## Pipeline stage` section of `.claude/task.md`:
1. pickup — read `.claude/task.md` + any existing diff.
2. triage — confirm the work is actionable as scoped. Minor ambiguity: make a
   DOCUMENTED best guess and note the assumption. If it is a genuine DESIGN
   question (API shape, product behavior, irreversible/ambiguous choice) use the
   escape hatch below. If there is no safe guess and it is not a design question,
   stop and write the reason to the `## Progress log`.
3. work — implement the change.
4. review — run the `review-fix` skill on the working changes (it loops
   /code-review + auto-fixes high/medium findings, cap 3 rounds). If it leaves
   unsafe findings, they become PR comments; if it cannot get clean, stop and
   summarize in the progress log — do NOT open a PR.
5. ci — detect and run the repo's check command (try in order: `make ci`,
   `make agent-ci`, `npm test`/`npm run test`, `pytest`, or a check documented in
   CLAUDE.md/README; if none, record "no check command found" and proceed). It
   must pass; fix and re-run, or stop and report if un-greenable.
6. open a DRAFT PR with the `open-pr` skill, then write `done` under
   `## Pipeline stage`.

DESIGN-QUESTION ESCAPE HATCH (any stage): if you need a decision only the user
can make, write `.claude/question.md` (the question, 2-4 options with your
recommendation, context) and EXIT cleanly. Do not guess on design questions.
Never merge, never push to the base branch, never run git
restore/checkout/clean/reset.
"""


def build_argv(*, prompt: str, worktree: str) -> list:
    return ["claude", "-p", prompt,
            "--permission-mode", "acceptEdits", "--add-dir", worktree]


def dispatch_prompt(*, issue) -> str:
    return f"You are working task #{issue} in this worktree.\n\n{PIPELINE}"


def restart_prompt(*, issue) -> str:
    return (
        f"You are resuming task #{issue} in this worktree. Read `.claude/task.md` "
        f"and the working diff, then resume the pipeline from the last completed "
        f"stage under `## Pipeline stage`.\n\n{PIPELINE}"
    )


def resume_prompt(*, issue) -> str:
    return (
        f"You are resuming task #{issue} after the user ANSWERED your design "
        f"question. Read the latest `## Progress log` entry in `.claude/task.md` "
        f"for the answer, then continue the pipeline from where you parked.\n\n"
        f"{PIPELINE}"
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_spawn.py -q`
Expected: PASS — 4 passed.

- [ ] **Step 5: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/spawn.py \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_spawn.py
git commit -m "feat(supervisor): claude spawn argv + pipeline prompts (review-fix reuse)"
```

---

### Task 11: Shared shell glue (`common.sh`)

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/scripts/common.sh`

- [ ] **Step 1: Write the script**

Create `plugins/skillet/skills/issue-supervisor/scripts/common.sh`:
```bash
#!/usr/bin/env bash
# Shared helpers for supervisor scripts. Source this; do not execute.
# Resolves repo-agnostic context (REPO, BASE), runtime-state dir, and lib dir.
set -euo pipefail

# LIB_DIR resolves relative to THIS file, so it works regardless of where the
# plugin is installed. Scripts that source common.sh are in scripts/, so the
# lib is one dir up.
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$COMMON_DIR/.." && pwd)"
LIB_DIR="$SKILL_DIR/lib"

REPO_ROOT="$(git rev-parse --show-toplevel)"
STATE_DIR="$REPO_ROOT/.claude/issue-supervisor"
REGISTRY="$STATE_DIR/registry.json"
WORKTREES_DIR="$REPO_ROOT/.claude/worktrees"

fail() { printf '{"error": %s}\n' "$(jq -Rn --arg m "$1" '$m')"; exit 1; }

require_tools() {
  command -v gh >/dev/null || fail "gh not installed"
  command -v jq >/dev/null || fail "jq not installed"
  command -v git >/dev/null || fail "git not installed"
}

# Repo-agnostic identifiers (no hard-coded owner/name/branch).
detect_repo() { gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || fail "gh repo view failed"; }
detect_base() { gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main"; }

# Print the repo's check command, or empty string if none detected.
detect_ci_cmd() {
  if [ -f "$REPO_ROOT/Makefile" ] && grep -qE '^ci:' "$REPO_ROOT/Makefile"; then echo "make ci"; return; fi
  if [ -f "$REPO_ROOT/Makefile" ] && grep -qE '^agent-ci:' "$REPO_ROOT/Makefile"; then echo "make agent-ci"; return; fi
  if [ -f "$REPO_ROOT/package.json" ] && grep -q '"test"' "$REPO_ROOT/package.json"; then echo "npm test"; return; fi
  if [ -f "$REPO_ROOT/pytest.ini" ] || [ -f "$REPO_ROOT/pyproject.toml" ]; then echo "pytest"; return; fi
  echo ""
}

py() { python3 -c "import sys; sys.path.insert(0,'$LIB_DIR'); $1"; }

mkdir -p "$STATE_DIR"
```

- [ ] **Step 2: Smoke-test sourcing (from the v2 worktree, a real git repo)**

Run:
```bash
chmod +x plugins/skillet/skills/issue-supervisor/scripts/common.sh
bash -c 'source plugins/skillet/skills/issue-supervisor/scripts/common.sh; echo "REPO=$(detect_repo) BASE=$(detect_base) CI=$(detect_ci_cmd) STATE=$STATE_DIR"'
```
Expected: prints `REPO=mungbeanfanfiction/skillet BASE=main CI=npm test STATE=.../.claude/issue-supervisor` (skillet's package.json has a `test` script). No crash; `$STATE_DIR` created.

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/scripts/common.sh
git commit -m "feat(supervisor): shared repo-agnostic shell glue (common.sh)"
```

---

### Task 12: survey.sh

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/scripts/survey.sh`

- [ ] **Step 1: Write the script**

Create `plugins/skillet/skills/issue-supervisor/scripts/survey.sh`:
```bash
#!/usr/bin/env bash
# Read-only ground-truth survey. Emits JSON to stdout for SKILL.md.
# On any error: print {"error": "..."} and exit 1 so the cycle skips.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_tools

REPO="$(detect_repo)"
ISSUES_JSON="$(gh issue list --repo "$REPO" --state open --limit 100 \
  --json number,labels 2>/dev/null)" || fail "gh issue list failed"
PRS_JSON="$(gh pr list --repo "$REPO" --state open --limit 100 \
  --json headRefName 2>/dev/null)" || fail "gh pr list failed"

OPEN_PR_BRANCHES="$(echo "$PRS_JSON" | jq -r '[.[].headRefName] | @json')"
FACTS="[]"
while read -r path; do
  [ -z "$path" ] && continue
  branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
  owned="$(py "from supervisorlib import registry; print('true' if registry.is_owned('$REGISTRY','$path') else 'false')")"
  has_q="$([ -f "$path/.claude/question.md" ] && echo true || echo false)"
  pid_file="$path/.claude/session.pid"
  alive=false
  if [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then alive=true; fi
  task_present="$([ -f "$path/.claude/task.md" ] && echo true || echo false)"
  task_complete=false; restart=0
  if [ "$task_present" = true ]; then
    awk '/^## Pipeline stage/{getline; if($1=="done") found=1} END{exit !found}' \
      "$path/.claude/task.md" 2>/dev/null && task_complete=true || true
    restart="$(awk '/## Restart count/{getline; print $1; exit}' "$path/.claude/task.md" 2>/dev/null || echo 0)"
  fi
  has_pr="$(echo "$OPEN_PR_BRANCHES" | jq --arg b "$branch" 'index($b) != null')"
  issue_num="$(py "from supervisorlib import registry; print(registry.issue_for_path('$REGISTRY','$path') or 'null')")"
  FACTS="$(echo "$FACTS" | jq \
    --argjson issue "$issue_num" --arg path "$path" --arg branch "$branch" \
    --argjson owned "$owned" --argjson alive "$alive" --argjson hasq "$has_q" \
    --argjson complete "$task_complete" --argjson haspr "$has_pr" \
    --argjson restart "${restart:-0}" --argjson present "$task_present" \
    '. += [{issue:$issue, path:$path, branch:$branch, owned:$owned, facts:{
        process_alive:$alive, has_question_md:$hasq, task_complete:$complete,
        has_open_pr:$haspr, restart_count:$restart, task_md_present:$present}}]')"
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

python3 - "$LIB_DIR" "$REGISTRY" "$ISSUES_JSON" "$FACTS" <<'PY'
import sys, json
sys.path.insert(0, sys.argv[1])
from supervisorlib import gh, registry, survey
reg_path, issues, facts = sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4])
owned_nums = registry.issues(reg_path)
eligible = gh.eligible_issues(issues, owned_issue_numbers=owned_nums)
print(json.dumps(survey.assemble(worktree_facts=facts, eligible_issues=eligible)))
PY
```

- [ ] **Step 2: Make executable and smoke-test**

Run:
```bash
chmod +x plugins/skillet/skills/issue-supervisor/scripts/survey.sh
plugins/skillet/skills/issue-supervisor/scripts/survey.sh | jq .
```
Expected: a JSON object with `worktrees` (the repo's worktrees, all `owned:false` since the registry is empty), `free_slots: 3`, `eligible_issues` (likely `[]` until labeling). No crash.

- [ ] **Step 3: Verify the error path fails closed**

Run: `PATH=/usr/bin:/bin plugins/skillet/skills/issue-supervisor/scripts/survey.sh; echo "exit=$?"`
Expected: if this hides `gh`/`jq`, prints `{"error": ...}` and `exit=1`. If those tools live in `/usr/bin`, note that and skip.

- [ ] **Step 4: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/scripts/survey.sh
git commit -m "feat(supervisor): survey.sh ground-truth shell glue"
```

---

## Phase 4 — Question lifecycle & dispatch/restart/resume

### Task 13: question.md parse + answer detection + sweep.sh

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/questions.py`
- Test: `plugins/skillet/skills/issue-supervisor/lib/tests/test_questions.py`
- Create: `plugins/skillet/skills/question-sweeper/scripts/sweep.sh`
- Create: `docs/superpowers/questions/.gitkeep`

- [ ] **Step 1: Write the failing test**

Create `tests/test_questions.py`:
```python
from supervisorlib import questions

UNANSWERED = """# Question — issue #5
Should clubs be public?

## Options
1. public — simpler
2. gated — safer (recommended)

## Context
working on issue 5

## Answer
<!-- empty until the user fills it -->
"""

ANSWERED = UNANSWERED.replace("<!-- empty until the user fills it -->", "go with gated")


def test_is_answered_false_for_placeholder(tmp_path):
    f = tmp_path / "5.md"; f.write_text(UNANSWERED)
    assert questions.is_answered(f) is False


def test_is_answered_true_when_filled(tmp_path):
    f = tmp_path / "5.md"; f.write_text(ANSWERED)
    assert questions.is_answered(f) is True


def test_extract_answer_returns_text(tmp_path):
    f = tmp_path / "5.md"; f.write_text(ANSWERED)
    assert questions.extract_answer(f) == "go with gated"


def test_question_body_strips_answer_section(tmp_path):
    f = tmp_path / "5.md"; f.write_text(UNANSWERED)
    body = questions.question_body(f)
    assert "Should clubs be public?" in body
    assert "Answer" not in body
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_questions.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'supervisorlib.questions'`.

- [ ] **Step 3: Write minimal implementation**

Create `plugins/skillet/skills/issue-supervisor/lib/supervisorlib/questions.py`:
```python
"""Parse worktree question.md and inbox <issue#>.md files.
'Answered' = the `## Answer` section contains non-placeholder text."""
from pathlib import Path

_PLACEHOLDER = "<!-- empty until the user fills it -->"
_ANSWER_HEADER = "## Answer"


def _answer_section(text: str) -> str:
    if _ANSWER_HEADER not in text:
        return ""
    return text.split(_ANSWER_HEADER, 1)[1].strip()


def is_answered(path) -> bool:
    section = _answer_section(Path(path).read_text())
    return bool(section) and _PLACEHOLDER not in section


def extract_answer(path) -> str:
    return _answer_section(Path(path).read_text())


def question_body(path) -> str:
    """Everything above `## Answer` — for the GitHub issue comment."""
    return Path(path).read_text().split(_ANSWER_HEADER, 1)[0].strip()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest tests/test_questions.py -q`
Expected: PASS — 4 passed.

- [ ] **Step 5: Run full lib suite**

Run: `cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest -q`
Expected: PASS — all (~45 tests).

- [ ] **Step 6: Write sweep.sh + the inbox keepfile**

Create `docs/superpowers/questions/.gitkeep` (empty file).

Create `plugins/skillet/skills/question-sweeper/scripts/sweep.sh`:
```bash
#!/usr/bin/env bash
# Read-only sweep: emit JSON of (newly-raised questions, answered inbox items).
# The SKILL.md decides what to act on. No spawning here.
set -euo pipefail

# Reuse the supervisor's common.sh for REPO_ROOT/REGISTRY/LIB_DIR/py().
SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SWEEP_DIR/../../issue-supervisor/scripts" && pwd)/common.sh"
require_tools

INBOX="$REPO_ROOT/docs/superpowers/questions"
mkdir -p "$INBOX"

RAISED="[]"
while read -r path; do
  [ -z "$path" ] && continue
  q="$path/.claude/question.md"
  [ -f "$q" ] || continue
  issue="$(py "from supervisorlib import registry; print(registry.issue_for_path('$REGISTRY','$path') or '')")"
  [ -z "$issue" ] && continue
  if [ ! -f "$INBOX/$issue.md" ]; then
    RAISED="$(echo "$RAISED" | jq --argjson i "$issue" --arg p "$path" '. += [{issue:$i, path:$p}]')"
  fi
done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

ANSWERED="[]"
for f in "$INBOX"/*.md; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .md)"; [ "$base" = ".gitkeep" ] && continue
  case "$base" in (*[!0-9]*) continue ;; esac   # only numeric <issue>.md
  filled="$(py "from supervisorlib import questions; print('true' if questions.is_answered('$f') else 'false')")"
  [ "$filled" = true ] && ANSWERED="$(echo "$ANSWERED" | jq --argjson i "$base" '. += [$i]')"
done

jq -n --argjson raised "$RAISED" --argjson answered "$ANSWERED" \
  '{raised:$raised, answered:$answered}'
```

- [ ] **Step 7: Make executable, smoke-test**

Run:
```bash
chmod +x plugins/skillet/skills/question-sweeper/scripts/sweep.sh
plugins/skillet/skills/question-sweeper/scripts/sweep.sh | jq .
```
Expected: `{"raised": [], "answered": []}` (nothing parked yet).

- [ ] **Step 8: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/lib/supervisorlib/questions.py \
        plugins/skillet/skills/issue-supervisor/lib/tests/test_questions.py \
        plugins/skillet/skills/question-sweeper/scripts/sweep.sh \
        docs/superpowers/questions/.gitkeep
git commit -m "feat(sweeper): question parsing, answer detection, sweep.sh"
```

---

### Task 14: dispatch.sh — create worktree, task.md, spawn

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/scripts/dispatch.sh`

- [ ] **Step 1: Write the script**

Create `plugins/skillet/skills/issue-supervisor/scripts/dispatch.sh`:
```bash
#!/usr/bin/env bash
# Dispatch one task: worktree off latest origin/<base>, task.md, register, spawn.
# Usage: dispatch.sh <issue-or-id> <title> <slug> <source>   (source: label|file)
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
require_tools

ISSUE="$1"; TITLE="$2"; SLUG="$3"; SOURCE="${4:-label}"
REPO="$(detect_repo)"; BASE="$(detect_base)"
BRANCH="auto-${ISSUE}-${SLUG}"
WT="$WORKTREES_DIR/$BRANCH"

# Assign the issue to the current user (label source only).
if [ "$SOURCE" = "label" ]; then
  gh issue edit "$ISSUE" --repo "$REPO" --add-assignee @me >/dev/null 2>&1 || true
fi

# Branch off LATEST origin/<base>; skip on collision.
git -C "$REPO_ROOT" fetch origin "$BASE" >/dev/null 2>&1 || fail "git fetch failed"
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "skip: branch $BRANCH exists"; exit 0
fi
git -C "$REPO_ROOT" worktree add -b "$BRANCH" "$WT" "origin/$BASE" >/dev/null

# Symlink gitignored env-like files from the main repo (best-effort).
git -C "$REPO_ROOT" ls-files --others --ignored --exclude-standard \
  | grep -E '(^|/)\.env(\.|$)' | while read -r rel; do
    mkdir -p "$WT/$(dirname "$rel")"; ln -sfn "$REPO_ROOT/$rel" "$WT/$rel" 2>/dev/null || true
  done

mkdir -p "$WT/.claude"
cat > "$WT/.claude/task.md" <<EOF
# Task — issue #${ISSUE}
**Goal:** ${TITLE}
**Source:** ${SOURCE}
**Acceptance criteria:** see issue #${ISSUE} body.

## Pipeline stage
pickup

## Restart count
0

## Progress log
- dispatched
EOF

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
py "from supervisorlib import registry; registry.add('$REGISTRY', issue='$ISSUE' if not '$ISSUE'.isdigit() else int('$ISSUE'), path='$WT', branch='$BRANCH', source='$SOURCE', created_at='$NOW')"

PROMPT="$(py "from supervisorlib import spawn; print(spawn.dispatch_prompt(issue='$ISSUE'))")"
cd "$WT"
nohup claude -p "$PROMPT" --permission-mode acceptEdits --add-dir "$WT" \
  > "$WT/.claude/session.log" 2>&1 &
echo $! > "$WT/.claude/session.pid"
echo "dispatched #$ISSUE → $WT (pid $(cat "$WT/.claude/session.pid"))"
```

- [ ] **Step 2: Make executable, verify prompt builder in isolation (do NOT run live)**

Run:
```bash
chmod +x plugins/skillet/skills/issue-supervisor/scripts/dispatch.sh
python3 -c "import sys; sys.path.insert(0,'plugins/skillet/skills/issue-supervisor/lib'); from supervisorlib import spawn; print(spawn.dispatch_prompt(issue=999)[:80])"
```
Expected: prints the first 80 chars of the dispatch prompt. Do not run `dispatch.sh` live yet — it spawns a real session (covered in Task 18).

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/scripts/dispatch.sh
git commit -m "feat(supervisor): dispatch.sh worktree+task.md+spawn"
```

---

### Task 15: restart.sh + resume.sh

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/scripts/restart.sh`
- Create: `plugins/skillet/skills/issue-supervisor/scripts/resume.sh`

- [ ] **Step 1: Write restart.sh**

Create `plugins/skillet/skills/issue-supervisor/scripts/restart.sh`:
```bash
#!/usr/bin/env bash
# Restart a stalled OWNED worktree: assert ownership, increment restart count,
# respawn detached. Refuses if a question is pending. Usage: restart.sh <wt> <issue>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WT="$1"; ISSUE="$2"; TASK="$WT/.claude/task.md"

# Defense-in-depth: only act on registered (owned) worktrees.
owned="$(py "from supervisorlib import registry; print('true' if registry.is_owned('$REGISTRY','$WT') else 'false')")"
[ "$owned" = true ] || { echo "refusing: $WT is not owned"; exit 1; }
[ -f "$TASK" ] || { echo "no task.md at $WT — refusing restart"; exit 1; }
[ -f "$WT/.claude/question.md" ] && { echo "question pending — not restarting"; exit 0; }

CUR="$(awk '/## Restart count/{getline; print $1; exit}' "$TASK" 2>/dev/null || echo 0)"
NEW=$(( ${CUR:-0} + 1 ))
python3 - "$TASK" "$NEW" <<'PY'
import sys, re
task, new = sys.argv[1], sys.argv[2]
text = open(task).read()
text = re.sub(r'(## Restart count\n)\d+', rf'\g<1>{new}', text, count=1)
open(task, 'w').write(text)
PY

PROMPT="$(py "from supervisorlib import spawn; print(spawn.restart_prompt(issue='$ISSUE'))")"
cd "$WT"
nohup claude -p "$PROMPT" --permission-mode acceptEdits --add-dir "$WT" \
  > "$WT/.claude/session.log" 2>&1 &
echo $! > "$WT/.claude/session.pid"
echo "restarted #$ISSUE → $WT (restart #$NEW, pid $(cat "$WT/.claude/session.pid"))"
```

- [ ] **Step 2: Write resume.sh (NO restart-count increment)**

Create `plugins/skillet/skills/issue-supervisor/scripts/resume.sh`:
```bash
#!/usr/bin/env bash
# Resume an OWNED worktree after an ANSWERED design question. Unlike restart.sh,
# this does NOT burn the restart budget — answering a question is not a stall.
# Usage: resume.sh <worktree-path> <issue>
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

WT="$1"; ISSUE="$2"; TASK="$WT/.claude/task.md"

owned="$(py "from supervisorlib import registry; print('true' if registry.is_owned('$REGISTRY','$WT') else 'false')")"
[ "$owned" = true ] || { echo "refusing: $WT is not owned"; exit 1; }
[ -f "$TASK" ] || { echo "no task.md at $WT — refusing resume"; exit 1; }

# Clear the question marker so the worktree leaves needs-input.
rm -f "$WT/.claude/question.md"

PROMPT="$(py "from supervisorlib import spawn; print(spawn.resume_prompt(issue='$ISSUE'))")"
cd "$WT"
nohup claude -p "$PROMPT" --permission-mode acceptEdits --add-dir "$WT" \
  > "$WT/.claude/session.log" 2>&1 &
echo $! > "$WT/.claude/session.pid"
echo "resumed #$ISSUE → $WT (pid $(cat "$WT/.claude/session.pid"))"
```

- [ ] **Step 3: Make executable, unit-check the restart increment in isolation**

Run:
```bash
chmod +x plugins/skillet/skills/issue-supervisor/scripts/restart.sh \
         plugins/skillet/skills/issue-supervisor/scripts/resume.sh
T=$(mktemp -d)/task.md; printf '## Restart count\n0\n' > "$T"
python3 - "$T" 1 <<'PY'
import sys, re
text=open(sys.argv[1]).read()
text=re.sub(r'(## Restart count\n)\d+', rf'\g<1>{sys.argv[2]}', text, count=1)
open(sys.argv[1],'w').write(text)
PY
grep -A1 "Restart count" "$T"
```
Expected: shows `## Restart count` then `1`.

- [ ] **Step 4: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/scripts/restart.sh \
        plugins/skillet/skills/issue-supervisor/scripts/resume.sh
git commit -m "feat(supervisor): restart.sh (budgeted) + resume.sh (answer, unbudgeted)"
```

---

## Phase 5 — SKILL.md authoring (model-judgment layer)

### Task 16: issue-supervisor SKILL.md

**Files:**
- Create: `plugins/skillet/skills/issue-supervisor/SKILL.md`

- [ ] **Step 1: Write the skill**

Create `plugins/skillet/skills/issue-supervisor/SKILL.md`:
```markdown
---
name: issue-supervisor
description: Supervise auto-labeled GitHub issues (or a markdown checklist) across git worktrees — survey ground truth, restart stalled background sessions, dispatch new work to fill 3 slots, groom the backlog. Repo-agnostic; reuses review-fix. Use when running the ~5h supervisor loop.
argument-hint: "[--label <name> | --file <path>]"
---

# issue-supervisor

The heavy ~5h loop. Repo-agnostic: it derives the repo and base branch from the
current git context. Run order each cycle. Concurrency lock first.

## 0. Lock
Acquire `<repo>/.claude/issue-supervisor/supervisor.lock` (create the file; if it
exists and is <6h old, exit — another cycle is running). Remove it at the end.

## 1. Bootstrap (first run only)
Create any missing labels in the CURRENT repo (`REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)`):
`auto`, `epic`, `loop-generated`, `needs-input`. Then present open issues and apply
`auto` only to the ones the user approves. Do NOT bulk-label.

## 2. Survey
Run `scripts/survey.sh`. If it returns `{"error": ...}`, report the error and STOP
this cycle (reschedule). Never act on partial data.

## 3. Act on owned worktrees (from survey JSON)
- `stalled` → run `scripts/restart.sh <path> <issue>`.
- `needs-input` → leave alone (the sweeper owns it; never restart).
- `pr-open` → leave to the human.
- `blocked` → report with reason; do not touch.
- `working` → leave alone.
NEVER touch worktrees with `"owned": false` — report them if stalled, nothing more.

## 4. Refill slots
While `free_slots > 0` and the queue is non-empty, take the next item:
- **Label queue:** lowest `eligible_issues` number. Fetch the body
  (`gh issue view <n>`), judge scope.
- **File queue (`--file`):** next unchecked `- [ ]` item.
Run the **dispatch-time triage gate**:
- **Atomic** (one focused PR) → `scripts/dispatch.sh <id> "<title>" <slug> <source>`.
- **Too big** (label source only) → decompose autonomously: create ≤6 sub-issues
  with `gh issue create ... --label auto --label loop-generated` and body
  `part of #<n>`; then re-label the parent `epic` and remove `auto`. Do NOT
  dispatch the parent. (Idempotent: epics are filtered out by survey.)

## 5. Report + reschedule
Print: in-flight (issue→state), restarted, PRs open, blocked w/ reason,
needs-input count, foreign-stalled FYI, slots filled, backlog groomed. Append a
run-report under `docs/superpowers/runs/` (use `supervisorlib.runreport`). Release
the lock. The /loop reschedules ~5h.

## Hard rules
No merge, no push to the base branch, only DRAFT PRs (those happen inside
sessions). Never git restore/checkout/clean/reset. Foreign worktrees are
report-only. The per-issue review step uses the `review-fix` skill.
```

- [ ] **Step 2: Validate frontmatter loads**

Run: `head -5 plugins/skillet/skills/issue-supervisor/SKILL.md && wc -l plugins/skillet/skills/issue-supervisor/SKILL.md`
Expected: frontmatter with `name: issue-supervisor`; file well under 300 lines.

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/issue-supervisor/SKILL.md
git commit -m "feat(supervisor): issue-supervisor SKILL.md procedure"
```

---

### Task 17: question-sweeper SKILL.md

**Files:**
- Create: `plugins/skillet/skills/question-sweeper/SKILL.md`

- [ ] **Step 1: Write the skill**

Create `plugins/skillet/skills/question-sweeper/SKILL.md`:
```markdown
---
name: question-sweeper
description: Sweep worktrees for sessions parked on design questions, queue them to a local inbox + GitHub comment, and re-dispatch once the user answers. Repo-agnostic. Use when running the ~1h question-sweeper loop.
---

# question-sweeper

The light ~1h loop. Manages the design-question lifecycle only. Never dispatches
fresh work or restarts mechanical stalls.

## 0. Lock
Acquire `<repo>/.claude/issue-supervisor/sweeper.lock` (create; if it exists and is
<2h old, exit). Remove at the end.

## 1. Sweep
Run `scripts/sweep.sh`. If `{"error": ...}`, report and STOP.

## 2. Newly-raised questions (`raised` array)
For each `{issue, path}`:
- Copy `path/.claude/question.md` (body above `## Answer`) into
  `docs/superpowers/questions/<issue>.md`, keeping an empty `## Answer` section.
- Apply the label: `gh issue edit <issue> --add-label needs-input`.
- Post the question as a comment: `gh issue comment <issue> --body "<question body>"`.
  (File-source tasks have no GitHub issue — record them in the run-report instead.)
The worktree's slot is now free (survey counts `needs-input` as not-in-flight), so
the 5h loop will refill it.

## 3. Answered questions (`answered` array)
For each issue number, recompute free slots by running the supervisor's
`scripts/survey.sh` and reading `free_slots`:
- If `free_slots > 0`:
  - Append the answer to the worktree's `.claude/task.md` progress log.
  - Remove the label: `gh issue edit <issue> --remove-label needs-input`.
  - Re-dispatch with the supervisor's **`scripts/resume.sh <worktree-path> <issue>`**
    (NOT restart.sh — answering must not burn the restart budget; resume.sh also
    clears question.md).
- If `free_slots == 0`: leave answered-and-queued; report it. It re-dispatches on a
  later sweep when a slot opens.

## 4. Report + reschedule
Print: questions newly raised, awaiting answer, answers detected + re-dispatched,
answered-but-queued. Release lock. /loop reschedules ~1h.

## Hard rules
Never answer a question on the user's behalf. Never restart a mechanical stall
(that's the 5h loop). Shares the owned-worktree registry; never touches foreign
worktrees.
```

- [ ] **Step 2: Validate**

Run: `head -4 plugins/skillet/skills/question-sweeper/SKILL.md`
Expected: frontmatter with `name: question-sweeper`.

- [ ] **Step 3: Commit**

```bash
git add plugins/skillet/skills/question-sweeper/SKILL.md
git commit -m "feat(sweeper): question-sweeper SKILL.md procedure"
```

---

## Phase 6 — Test wiring, end-to-end verification, docs & retirement

### Task 18: Wire supervisorlib into npm test + verify spawn against local claude

**Files:**
- Modify: `package.json`

- [ ] **Step 1: Add the lib test script**

Edit `package.json` `scripts` so it reads:
```json
  "scripts": {
    "test": "npm run test:tooling && npm run test:lib",
    "test:tooling": "node --test \"scripts/**/*.test.mjs\"",
    "test:lib": "cd plugins/skillet/skills/issue-supervisor/lib && python3 -m pytest -q"
  },
```

- [ ] **Step 2: Run the unified test command**

Run: `npm test`
Expected: the node tooling tests pass AND pytest reports all supervisorlib tests passing (~45). If `python3`/`pytest` is missing, install pytest (`python3 -m pip install pytest`) and note the dependency in the skill README (Step 5).

- [ ] **Step 3: Verify the claude spawn flags against the LOCAL CLI**

Run: `claude --help 2>&1 | grep -E -- '-p|--permission-mode|--add-dir' || echo "FLAGS DIFFER"`
Expected: `-p`, `--permission-mode`, and `--add-dir` are all present. If any differ, update `spawn.build_argv` + `dispatch.sh`/`restart.sh`/`resume.sh` to match, re-run `npm test`, and record the change.

- [ ] **Step 4: One live dispatch smoke-test (operational — coordinate with the user)**

Confirm a small throwaway target with the user first. Then create the labels and label one tiny issue:
```bash
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
for L in "auto:0E8A16" "epic:5319E7" "loop-generated:BFD4F2" "needs-input:D93F0B"; do
  gh label create "${L%%:*}" --repo "$REPO" --color "${L##*:}" 2>/dev/null || echo "${L%%:*} exists"
done
gh issue edit <small#> --repo "$REPO" --add-label auto
plugins/skillet/skills/issue-supervisor/scripts/survey.sh | jq '.eligible_issues'   # → [<small#>]
plugins/skillet/skills/issue-supervisor/scripts/dispatch.sh <small#> "<title>" <slug> label
plugins/skillet/skills/issue-supervisor/scripts/survey.sh | jq '.worktrees[] | select(.owned==true)'
```
Expected: dispatch prints a pid; the second survey shows the worktree `working` (or `stalled` if the session already exited — check `session.log`); `free_slots` reduced by 1.

- [ ] **Step 5: Commit any spawn-flag fixes + the test wiring**

```bash
git add package.json plugins/skillet/skills/issue-supervisor/lib/supervisorlib/spawn.py \
        plugins/skillet/skills/issue-supervisor/scripts/ 2>/dev/null || true
git commit -m "feat(supervisor): wire lib tests into npm test; verify spawn flags"
```

---

### Task 19: Retire drain-queue + document both loops

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-05-29-autonomous-queue-design.md` (supersession note)

- [ ] **Step 1: Confirm drain-queue is already absent, note the supersession**

Run: `ls plugins/skillet/skills/drain-queue 2>/dev/null && echo "STILL PRESENT — remove it" || echo "already absent"`
Expected: `already absent` (it was retired before this branch). If present, `git rm -r plugins/skillet/skills/drain-queue`.

Add a note at the top of `docs/superpowers/specs/2026-05-29-autonomous-queue-design.md`:
```markdown
> **Superseded (2026-06-23):** `drain-queue` is retired and folded into
> `issue-supervisor` + `question-sweeper`. See
> `2026-06-23-issue-supervisor-v2-design.md`. `review-fix` is retained.
```

- [ ] **Step 2: Add both skills to the README skills table + layout tree**

Add two rows to the skills table:
```markdown
| `/issue-supervisor` | ~5h loop: survey worktrees, restart stalled sessions, dispatch `auto`-labeled issues (or a `--file` checklist) to background sessions, groom the backlog. Opens draft PRs via `review-fix` + `open-pr`. |
| `/question-sweeper` | ~1h loop: route sessions parked on design questions to `docs/superpowers/questions/` + a GitHub comment, and re-dispatch once answered. |
```
Add both to the layout tree under `skills/` (fix the box-drawing connectors so the last entry uses `└──`).

- [ ] **Step 3: Document the run commands + Python dependency**

Append to `README.md` an "Issue automation" section:
```markdown
## Issue automation

Two self-paced loops supervise `auto`-labeled issues (or a markdown checklist)
across worktrees in ANY repo:

- `/loop issue-supervisor` — ~5h: dispatch/restart/groom; opens draft PRs.
- `/loop question-sweeper` — ~1h: routes design questions to `docs/superpowers/questions/`.

Label an issue `auto` (or pass `--file <checklist>.md`) to enqueue it. Runtime
state lives in the target repo's `.claude/issue-supervisor/` (gitignore it).
Requires `python3` + `pytest` for the test suite, and `gh`/`jq`/`git`. See
`docs/superpowers/specs/2026-06-23-issue-supervisor-v2-design.md`.
```

- [ ] **Step 4: Verify the README edits landed**

Run: `grep -n "issue-supervisor\|question-sweeper" README.md`
Expected: at least four matches (two table rows, two tree lines) plus the section.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/superpowers/specs/2026-05-29-autonomous-queue-design.md
git commit -m "docs: document issue-supervisor + question-sweeper, retire drain-queue"
```

---

## Final verification

- [ ] **Full lib suite green via npm**

Run: `npm test`
Expected: node tooling tests pass AND all supervisorlib tests pass (~45).

- [ ] **Survey + sweep both emit valid JSON**

Run:
```bash
plugins/skillet/skills/issue-supervisor/scripts/survey.sh | jq -e . >/dev/null && echo "survey ok"
plugins/skillet/skills/question-sweeper/scripts/sweep.sh | jq -e . >/dev/null && echo "sweep ok"
```
Expected: `survey ok` and `sweep ok`.

- [ ] **Both skills discoverable + well-formed**

Run:
```bash
for s in issue-supervisor question-sweeper; do
  head -4 "plugins/skillet/skills/$s/SKILL.md"; wc -l "plugins/skillet/skills/$s/SKILL.md"
done
```
Expected: valid frontmatter for both; each SKILL.md under 300 lines.

- [ ] **Clean tree + sane log**

Run: `git status --porcelain && git log --oneline -20`
Expected: working tree clean; the feature/test/docs commits from Tasks 1-19 present.

---

## Self-Review

**Spec coverage** (against `2026-06-23-issue-supervisor-v2-design.md`):
- Two skills + shared `supervisorlib` → Tasks 1-17. ✔
- Repo-agnostic (`gh repo view` repo + base, CI detection) → `common.sh` Task 11; CI order in `spawn.PIPELINE` Task 10. ✔
- Runtime state in target repo `.claude/` → `paths.py` Task 1, used everywhere. ✔
- The two loops (survey→act→refill→report; sweep→raise→answer) → SKILL.md Tasks 16-17. ✔
- Per-issue pipeline reuses `review-fix` (not raw /code-review) → `spawn.PIPELINE` Task 10 (asserted in test). ✔
- Design-question philosophy (best-guess / escalate / skip) → `spawn.PIPELINE` Task 10; sweeper Task 17. ✔
- `needs-input` not in-flight; restart cap 2; resume.sh ≠ restart.sh (budget) → state.py Task 4, restart/resume Task 15. ✔
- Autonomous decomposition (≤6, epic idempotency, loop-generated) → SKILL.md Task 16; epic filter in gh.py Task 6. ✔
- Both queue sources (label + `--file`) → queue_source.py Task 7, threaded through dispatch.sh Task 14 + SKILL.md Task 16. ✔
- Run-report (drain-queue heritage) → runreport.py Task 9, wired in Task 16. ✔
- Safety rails in code (ownership assertion, atomic registry, survey fails closed) → registry.py Task 2, restart/resume Task 15, survey.sh Task 12. ✔
- Retire/absorb drain-queue; keep review-fix; note supersession → Task 19. ✔
- supervisorlib tested + wired into skillet CI → pytest per task + `npm run test:lib` Task 18. ✔

**Placeholder scan:** every code/step block is concrete; no TBD/TODO. The single deliberately-operational item (live dispatch, Task 18 Step 4) is gated on user confirmation, as the spec requires.

**Type/name consistency:** `WorktreeState` values, `registry.{add,is_owned,issues,issue_for_path}`, `spawn.{build_argv,dispatch_prompt,restart_prompt,resume_prompt}`, `paths.*`, and the `source` field (`label`/`file`) are used identically across lib, scripts, and SKILL.md. CI-detection order matches between `common.sh` and `spawn.PIPELINE`.
```
