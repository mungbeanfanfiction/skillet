# Task — issue #74
**Goal:** Bias triage priority higher for bugs
**Source:** label
**Labels:** auto,chore,p2
**Acceptance criteria:** see issue #74 body.

## Pipeline stage
done

## Restart count
0

## Progress log
- dispatched
- triage: actionable as scoped. Priority inference lives only in the two SKILL.md prose rules (create-issue step 3, triage-issue step 6); no code path infers priority.
- work: added a "Bug bias" clause to both priority rules (bug + unclear -> p1; p0 still urgent-only; explicitly-minor bug may stay p2)
- review: 1 round via code-reviewer subagent; no high/medium findings
- ci: npm test green (19 tooling + 114 python tests)
- verbosity gate: 2 prose findings on my own added lines; tightened both rules
- opened draft PR #76, commented on issue #74
