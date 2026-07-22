---
name: create-skill
description: Scaffold a new skill directory + SKILL.md under plugins/skillet/skills/, following this plugin's frontmatter conventions (name, description, optional argument-hint, model). Always infers or prompts for an appropriate model pin so new skills don't skip it. Use when asked to create/add/scaffold a new skill for this plugin.
argument-hint: "<skill-name> [description]"
---

# Create Skill Skill

Scaffold a new skill for this plugin: a directory under
`plugins/skillet/skills/<name>/` and a `SKILL.md` with correct frontmatter —
including a `model:` pin, so newly created skills never skip that decision the
way the original 19 did (see issue #110).

## When Invoked

Arguments: a skill name (kebab-case) and, optionally, a short description or
hint. If the description is missing, infer it from the conversation context.
If the skill name is missing, derive a kebab-case name from the description.

### 1. Validate the name

- Must be kebab-case (lowercase, hyphens), matching existing skills
  (`sync-repo-labels`, `explore-issue`, etc.).
- Check `plugins/skillet/skills/<name>/` doesn't already exist — if it does,
  stop and tell the user rather than overwriting.

### 2. Write the description

One paragraph, third person, imperative mood for the closing "Use when..."
clause — matching every existing skill:

- What it does (1-2 sentences).
- Any autonomy/scope notes worth flagging (e.g. "fully autonomous", "read-only",
  "never deletes").
- End with "Use when \<trigger condition\>." so the skill routes correctly.

### 3. Decide argument-hint

Include `argument-hint:` only if the skill takes arguments. Match the existing
bracket conventions: `<required>`, `[optional]`, `[--flag]`, `[a | b]` for
alternatives (see `sync-repo-labels`'s `"[owner/repo]"` or
`update-issue`'s `"[issue-number] [status message] [--noninteractive]"`).
Omit the field entirely for argument-less skills (see `question-sweeper`).

### 4. Decide the model pin — always make this decision explicitly

Do not silently skip this. Pick one of:

- **No `model:` field** (inherit the session default) — the right choice for
  most skills, especially ones with non-trivial judgment calls at a normal
  complexity level. This is the common case; only pin when there's a clear
  reason to diverge.
- **`model: haiku`** — cheap, mechanical, deterministic skills: fixed-format
  API calls, label/state syncing, status reporting, no multi-step judgment
  (e.g. `sync-repo-labels`, `worktree-status`, `update-issue`,
  `cleanup-worktrees`).
- **`model: opus`** — reasoning-heavy skills: long supervisor loops, deep
  multi-file investigation/synthesis, or decisions with wide blast radius
  (e.g. `issue-supervisor`, `explore-issue`, `create-epic`,
  `audit-permissions`).
- **`model: sonnet`** — only if you explicitly want to override a
  session default that might otherwise be lighter or heavier; rarely needed
  since sonnet is the typical session default already.

If invoked interactively and the right tier isn't obvious from the
description, ask the user directly: "Should this skill pin a model (haiku for
mechanical, opus for heavy reasoning), or inherit the session default?" If
invoked non-interactively (no way to prompt), infer from task complexity using
the guidance above and state the choice in your final summary.

### 5. Scaffold the files

```
plugins/skillet/skills/<name>/SKILL.md
```

Use this frontmatter shape (omit `argument-hint` if unused, omit `model` if
inheriting default):

```markdown
---
name: <name>
description: <description ending in "Use when ...">
argument-hint: "<hint>"
model: <haiku|sonnet|opus>
---

# <Title Case Name> Skill

<1-2 paragraph overview of what it does and why.>

## When Invoked

<arguments and how to resolve them>

## Workflow

### 1. <first step>

...

## Do not

- <explicit non-goals / guardrails, if any>
```

Only add a `scripts/` or `lib/` subdirectory if the skill needs deterministic
helper code (mirroring `check-pr-comments/scripts/` or
`issue-supervisor/lib/`) — most skills are markdown-only.

### 6. Wire it up

New skills are auto-discovered by directory — no plugin manifest registration
needed. But **update `README.md`** by hand so the skill is discoverable:

- Add a row to the `## Skills` table (`| /<name> | <one-line summary> |`),
  positioned near related skills.
- Add the file(s) to the `## Layout` tree under `skills/`.

### 7. Report back

Tell the user: the new skill's path, the model decision made (and why), and
confirm the README table + layout tree were updated.

## Do not

- Do not skip the model decision — every new skill must have it explicitly
  considered, even if the conclusion is "no pin, inherit default."
- Do not register the skill anywhere beyond `README.md` — this plugin has no
  separate skill-registration manifest.
- Do not overwrite an existing skill directory.
