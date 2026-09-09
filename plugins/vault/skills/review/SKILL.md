---
name: review
description: Roll up sessions across a date range into a review note in the Obsidian vault's `50 Reviews/` — what moved, what stalled, recurring themes, insights worth revisiting. Use for a weekly or monthly review, a progress summary, or when asked what you've been working on lately.
argument-hint: "[weekly|monthly] [date-or-range]"
model: sonnet
---

# Review

Look back across sessions and say what actually happened, including the parts
that didn't work.

Read `../_shared/vault-schema.md` first.

## When invoked

- **`weekly`** (default) covers the week containing the given date, otherwise the
  last completed week, Monday to Sunday.
- **`monthly`** covers that calendar month.
- **`[date-or-range]`** accepts `2026-09-07`, `2026-09`, or
  `2026-09-01..2026-09-14`.

## 1. Collect

Read every note in `10 Sessions/` whose `date` falls in range, plus insights
whose `date` matches. Read the notes, not just their frontmatter; the stalls are
in the prose.

If the range is empty, say so and stop. Don't write an empty review.

## 2. Find the shape

Group sessions by project, then look for what a single session can't show.

- **Themes**: the same problem across several sessions, especially under
  different names.
- **Repeats**: something solved twice because the first fix didn't hold, or
  wasn't found. A repeat means the insight is missing or badly titled.
- **Stalls**: loose ends still unchecked, projects that went quiet.
- **Drift**: time going somewhere other than where you thought.

## 3. Write

`50 Reviews/Weekly/YYYY-Www.md` or `50 Reviews/Monthly/YYYY-MM.md`, from
`90 Meta/Templates/Weekly Review.md`.

- **Sessions this week**: wikilinks grouped by project, one line each.
- **What moved**: shipped or decided, concretely.
- **What stalled, and why**: the reason matters more than the fact. A review that
  only lists wins is one you stop trusting.
- **Insights worth keeping**: wikilinks, noting which are proving durable.
- **Next**: what the stalls suggest, not a wish list.

Counts and durations come from the session notes' frontmatter. Don't recompute
them, and don't turn a single week's number into a trend.

Apply `/deslop`. A review is read once, quickly, so it cannot afford scaffolding.

## 4. Report

The review path, then the two or three findings actually worth acting on.
