# AGENTS.md

This repo is a private Claude Code plugin **marketplace** that ships one
plugin, `jira-sdlc` — three coupled skills (`jira-task-assigner`,
`jira-task-executor`, `jira-task-reviewer`) that plan a feature into Jira
issues + git worktrees, implement each piece in parallel, and then
review/merge the set. Full explanation, architecture diagram, and usage
walkthrough live in [README.md](plugins/jira-sdlc/README.md) — this file
is deliberately shorter and only covers what's easy to get wrong.

## The one rule that matters most

Every project-specific value (Jira project key, worktrees path, test
commands, workflow status names, review conventions) is a `<TOKEN>`
resolved from `jira-tools-plugin.env` in the project root
(see `plugins/jira-sdlc/skills/_shared/project-config.md` for a description of
each variable) — never a literal.
**Never hardcode a real project's value into a skill file.** If you're
about to type an actual Jira key, a real path, or a specific framework
name into a `SKILL.md` body, it belongs in `jira-tools-plugin.env`'s example
table instead, referenced through a token. This repo's entire value is
being reusable across projects; a hardcoded literal quietly breaks that
for the next person who installs it.

## Structural constraints — easy to break while "tidying up"

This repo is a **marketplace**, so there are *two* `.claude-plugin/`
directories — one at the marketplace root, one inside the plugin — and
each holds a single manifest. Don't merge them into one.

- **Marketplace root** (this repo's root) ships
  `.claude-plugin/marketplace.json`. Its plugin entry's `source` is a
  path relative to the marketplace root (here `"./plugins/jira-sdlc"`),
  *not* relative to `.claude-plugin/` itself — Claude Code resolves it
  against the directory that contains `.claude-plugin/`.
- **Plugin root** (`plugins/jira-sdlc/`) ships
  `.claude-plugin/plugin.json`, and that's the only file allowed in it.
  `skills/` and `docs/` live at the plugin root, as siblings of
  `.claude-plugin/`, never nested inside it.
- `skills/_shared/` must stay **inside** `skills/` (which is inside the
  plugin root). A marketplace install only copies the plugin's own root
  directory into its cache — anything reached by a relative path that
  climbs above the plugin root (e.g. splitting this into three separate
  plugins that each reach for an external `_shared/` across a `../`
  boundary) silently stops resolving after install. Don't move it up a
  level.
- Each `SKILL.md`'s `name:` frontmatter should match its folder name.

## If you rename a skill or the plugin

Renames aren't self-contained here — grep for the old name before
assuming you're done:
- Renaming the **plugin** (`name` in
  `plugins/jira-sdlc/.claude-plugin/plugin.json`, which is also the
  skill namespace in `/jira-sdlc:...`) → rename the directory under
  `plugins/`, update that entry's `name` and `source` in
  `.claude-plugin/marketplace.json`, *and* update the three
  self-referential slash-command mentions hardcoded inside
  `jira-task-assigner` (step 8) and `jira-task-reviewer` (step 5, both
  report templates), which currently read `/jira-sdlc:...`.
- Renaming a **skill** → `jira-task-assigner` step 8 currently refers to
  `jira-task-executor` by name; check the other two skills and the
  README for any new cross-references before assuming a rename is
  isolated to one file.

## Validating a change

There's no build or test suite — this repo is prompt files for an LLM
agent plus two JSON manifests (one per `.claude-plugin/` directory).
Instead:

```bash
# canonical structural validation — checks marketplace.json schema,
# source path traversal, and each plugin's plugin.json in one pass
claude plugin validate .

# manifests are well-formed JSON (fallback if the claude CLI is unavailable)
python3 -m json.tool .claude-plugin/marketplace.json > /dev/null
python3 -m json.tool plugins/jira-sdlc/.claude-plugin/plugin.json > /dev/null

# no project-specific literals crept back in. project-config.md is
# excluded because its example table is the sanctioned home for them
grep -rn --exclude=project-config.md "SUB-\|cropapp\|XState\|MUI\b" \
  plugins/jira-sdlc/skills/ plugins/jira-sdlc/docs/ plugins/jira-sdlc/README.md
```

Beyond that, "testing" a skill means tracing through which of the five
assignment cases, which review dimension, or which re-run phase your
change touches (see README → Core concepts), and re-reading that skill's
logic end to end for the scenario you changed. These files *are* the
behavior, not a description of it — there's no separate implementation
to run against them.

## Releasing (tagging + GitHub Releases)

There's no deploy pipeline — for a plugin marketplace, a *release* is just a
SemVer git tag plus the GitHub Release that the marketplace install command
consumes. The version lives only in git tags (no `package.json`/`VERSION` file
to bump), which is what makes the workflow generic enough to lift into any
repo, not just the JS app these skills came from. The branching and release
policy is [docs/SDLC.md](plugins/jira-sdlc/docs/SDLC.md); two workflows
automate it:

- **`cut-release.yml`** — manual `workflow_dispatch`. Derives the next sprint
  number (or takes one), cuts `release/sprint-<N>` from `development`, opens a
  **draft** PR into `main` carrying the `minor` label (the sprint-default bump,
  SDLC §5). SDLC Phase 2.
- **`release.yml`** — on a PR merge into `main` whose head is `release/*` or
  `hotfix/*`. In order: resolves the bump → tags `vX.Y.Z` on the merge commit
  → publishes the GitHub Release → back-merges `main` into `development`
  (opens a sync PR instead if it conflicts, never force-pushing) → deletes the
  `release/*`/`hotfix/*` branch. SDLC Phase 4 + §4.

Order of operations, the short version:
1. Run `cut-release` → `release/sprint-<N>` and a draft PR appear.
2. QA on that branch; fix PRs land back into `release/sprint-<N>` (SDLC Phase 3).
3. Mark the draft PR ready and merge it into `main`.
4. `release.yml` tags, releases, syncs back to `development`, and deletes the
   branch automatically.

Bump resolution (SDLC §5): branch-type default — `release/*` → **minor**,
`hotfix/*` → **patch** — overridden by a `patch`/`minor`/`major` label on the
merged PR (the same labels `jira-task-executor` already stamps, and that
already exist on this repo). Tags are pure SemVer, no sprint suffix. The
first release (no `v*` tag exists) is `v0.1.0`. A `hotfix/*` merge defaults to
a `patch` bump and runs the same sync-back + cleanup steps.

Auth: the default `GITHUB_TOKEN` suffices while `main`/`development` are
unprotected (the workflows push tags, delete branches, create releases, and
push the back-merge with it). If you enable branch protection on `main`, or
want the back-merge commit to re-trigger the `validator` workflow, define a
`RELEASE_PAT` secret and swap the `GH_TOKEN`/remote in `release.yml`'s
back-merge step.

## This repo is the toolkit, not a target

Don't try to exercise a skill by running `/jira-task-assigner` *against
this repo*. There's no Jira project or worktrees directory configured
for `claude-code-plugins` itself, and there shouldn't be — these skills are
meant to be installed into, and pointed at, a separate application repo
that has its own `.env` file filled in.
