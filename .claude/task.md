# Task: Address PR review feedback on #41

## Issue
#35 — Sub-skill: check a PR for new/unaddressed comments (standalone)

## PR
https://github.com/mungbeanfanfiction/skillet/pull/41

## Labels
auto, feature, p2, loop-generated

## Feedback to address

Comment r3477313526 on `plugins/skillet/skills/check-pr-comments/scripts/check-pr-comments.sh`:
> "wait i dont want the self account to be excluded actually"

Remove the logic that excludes the bot/self account from comment results. All comments should be surfaced regardless of author.

## Pipeline stage
address-review-feedback

## Progress log
