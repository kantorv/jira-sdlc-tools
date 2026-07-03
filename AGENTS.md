# AGENTS.md

This repo is a Claude Code plugin: three coupled skills
(`jira-task-assigner`, `jira-task-executor`, `jira-task-reviewer`) that
plan a feature into Jira issues + git worktrees, implement each piece in
parallel, and then review/merge the set. Full explanation, architecture
diagram, and usage walkthrough live in [README.md](README.md) — this
file is deliberately shorter and only covers what's easy to get wrong.

## The one rule that matters most

Every project-specific value (Jira project key, worktrees path, test
commands, workflow status names, review conventions) is a `<TOKEN>`
resolved from `skills/_shared/project-config.md` — never a literal.
**Never hardcode a real project's value into a skill file.** If you're
about to type an actual Jira key, a real path, or a specific framework
name into a `SKILL.md` body, it belongs in `project-config.md`'s example
table instead, referenced through a token. This repo's entire value is
being reusable across projects; a hardcoded literal quietly breaks that
for the next person who installs it.

## Structural constraints — easy to break while "tidying up"

- `skills/_shared/` must stay **inside** `skills/`, which is inside the
  plugin root. A marketplace install only copies the plugin's own root
  directory into its cache — anything reached by a relative path that
  climbs above the plugin root (e.g. splitting this into three separate
  plugins that each reach for an external `_shared/`) silently stops
  resolving after install. Don't move it up a level.
- `.claude-plugin/` holds only `plugin.json` and `marketplace.json`.
  `skills/` and `docs/` stay at the plugin root, not nested inside
  `.claude-plugin/`.
- Each `SKILL.md`'s `name:` frontmatter should match its folder name.

## If you rename a skill or the plugin

Renames aren't self-contained here — grep for the old name before
assuming you're done:
- Renaming the **plugin** (`name` in `.claude-plugin/plugin.json`) →
  update the three self-referential slash-command mentions hardcoded
  inside `jira-task-assigner` (step 8) and `jira-task-reviewer` (step 5,
  both report templates), which currently read `/jira-sdlc:...`.
- Renaming a **skill** → `jira-task-assigner` step 8 currently refers to
  `jira-task-executor` by name; check the other two skills and the
  README for any new cross-references before assuming a rename is
  isolated to one file.

## Validating a change

There's no build or test suite — this repo is prompt files for an LLM
agent plus two JSON manifests. Instead:

```bash
# manifests are well-formed JSON
python3 -m json.tool .claude-plugin/plugin.json > /dev/null
python3 -m json.tool .claude-plugin/marketplace.json > /dev/null

# no project-specific literals crept back in
grep -rn "SUB-\|cropapp\|XState\|MUI\b" skills/ docs/ README.md
```

Beyond that, "testing" a skill means tracing through which of the five
assignment cases, which review dimension, or which re-run phase your
change touches (see README → Core concepts), and re-reading that skill's
logic end to end for the scenario you changed. These files *are* the
behavior, not a description of it — there's no separate implementation
to run against them.

## This repo is the toolkit, not a target

Don't try to exercise a skill by running `/jira-task-assigner` *against
this repo*. There's no Jira project or worktrees directory configured
for `jira-sdlc-toolkit` itself, and there shouldn't be — these skills are
meant to be installed into, and pointed at, a separate application repo
that has its own `project-config.md` filled in.
