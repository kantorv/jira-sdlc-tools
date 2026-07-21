# Claude Code Integration (Native Claude skills)

Claude Code is the reference platform — it reads `SKILL.md` and the plugin
manifests as shipped, with no adaptation layer, so `disable-model-invocation:
true` and the `_shared/` relative paths behave exactly as written. Three
loading routes, all first-class: a **plugin marketplace** install, a
**drop-in copy** into a `.claude/skills/` tree, and **`--plugin-dir`** pointed
at a local clone. They differ in how the skills are invoked and in how you
pick up updates — pick by what you're doing, not by preference.

| | How it loads | Invocation | Updates | Best for |
|---|---|---|---|---|
| **Method 1 — marketplace** | `/plugin install` copies a snapshot into Claude Code's plugin cache | `/jira-sdlc:<skill-name>` | `/plugin` → update | Everyday use |
| **Method 2 — drop-in copy** | you copy `skills/*` into `~/.claude/skills/` or `<project>/.claude/skills/` | `/<skill-name>` (no namespace) | manual re-copy | No-marketplace setups; committing skills into a project repo |
| **Method 3 — `--plugin-dir`** | Claude Code loads the plugin live from your working copy | `/jira-sdlc:<skill-name>` | instant (`/reload-plugins`) | Editing the skills themselves |

For what the plugin *does* — architecture, the three skills, the worktree
model — see the plugin's own [README.md](../../README.md). This page is only
about getting it loaded.

## Prerequisites

- `acli` (Atlassian CLI) authenticated — see [project-config.md](../../skills/_shared/project-config.md) for the one-time `acli jira auth login`
- `gh` (GitHub CLI) authenticated
- `jira-sdlc-tools.env` and `jira-sdlc-tools.local.env` in your **project** root — see [project-config.md](../../skills/_shared/project-config.md)
- Claude Code itself, in any of its surfaces (CLI, desktop app, or the IDE extension — the extension is what Cursor and Antigravity re-use, see [CURSOR.md](CURSOR.md) and [ANTIGRAVITY.md](ANTIGRAVITY.md))
- **Methods 2 and 3 only** — a local clone of `kantorv/jira-sdlc-tools`

## Install / Wire-up Steps

### Method 1: Plugin marketplace (recommended)

1. Register the marketplace and install the plugin:
   ```
   /plugin marketplace add kantorv/jira-sdlc-tools
   /plugin install jira-sdlc@jira-sdlc-tools
   ```
   `/plugin` on its own opens the browser UI — the **Discover** tab lists
   `jira-sdlc` if you'd rather click than type the install line.
2. A local clone works as a marketplace source too — pass a path instead of
   an `owner/repo`, pointing at the **marketplace root** (the directory
   holding `.claude-plugin/marketplace.json`, i.e. the repo root):
   ```
   /plugin marketplace add </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>
   ```
3. Fill in `jira-sdlc-tools.env` in your project root.
4. The three skills are available as `/jira-sdlc:jira-task-assigner`,
   `/jira-sdlc:jira-task-executor`, `/jira-sdlc:jira-task-reviewer`.

> **Working from a fork, clone, or mirror?** Every command on this page
> names the canonical upstream, `kantorv/jira-sdlc-tools`. If you pushed
> your own copy, substitute *your* `<GITHUB_OWNER>/<GITHUB_REPO>` in the
> `marketplace add` lines — and note the install line's suffix is the
> **marketplace name**, not the repo name: it comes from the `name` field
> in your `.claude-plugin/marketplace.json` (`jira-sdlc-tools` upstream).
> Rename that field in your fork and the line becomes
> `/plugin install jira-sdlc@<MARKETPLACE_NAME>`. The plugin name
> (`jira-sdlc`, from `plugins/jira-sdlc/.claude-plugin/plugin.json`) is
> what makes the skills namespaced `/jira-sdlc:...`, so renaming *that*
> changes how you invoke them — see the plugin
> [README.md](../../README.md) for the other places a plugin rename has to
> be followed through.

### Method 2: Drop-in copy into a `.claude/skills/` tree

No marketplace, no plugin manifest — Claude Code reads skill folders
directly from a `skills/` directory. Run from the root of your clone:

```bash
cp -r plugins/jira-sdlc/skills/* ~/.claude/skills/    # personal — every project
# or
cp -r plugins/jira-sdlc/skills/* .claude/skills/      # project-level — commit it to your repo
```

Two things to get right:

- **Keep `_shared/` a sibling of the three skill folders.** Every `SKILL.md`
  reaches it by relative path (`../_shared/...`); moving or renaming it
  breaks all three. Don't double-nest into `.claude/skills/jira-sdlc/skills/`
  either — the tree Claude Code scans is one folder per skill, each holding
  a `SKILL.md`.
- **Invocation loses the namespace** — it's `/jira-task-assigner`, not
  `/jira-sdlc:jira-task-assigner`. The skills carry hardcoded
  `/jira-sdlc:...` self-references (in `jira-task-assigner` steps 1 and 8,
  `jira-task-executor` step 11 and its Discovery & healthcheck section,
  `jira-task-reviewer`'s Discovery & healthcheck section plus steps 4a/4b/4c
  and 6, and the rerun remedies in
  `_shared/scripts/posix/statuscheck.sh`) — edit those down to the bare form
  in your copy, or the skills will tell you to run a command that doesn't
  exist here.

The project-level variant is the one to use when you want the skills
committed alongside a repo so every contributor gets them; the personal
variant applies across all your projects and stays out of version control.
Cursor reads this same `~/.claude/` tree — see [CURSOR.md](CURSOR.md).

### Method 3: `--plugin-dir` against a local clone

The development loop. Point `--plugin-dir` at the **plugin's** root, not the
marketplace root — the repo root only carries `marketplace.json`, and
`plugin.json` lives one level down:

```bash
claude --plugin-dir </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>/plugins/jira-sdlc
```

Skills load straight from your working copy, so edits take effect with
`/reload-plugins` inside the running session — no reinstall, no restart. If
the plugin is *also* installed from a marketplace on the same machine,
`--plugin-dir` wins for that session, so you can test a change without
uninstalling anything.

Invocation stays namespaced (`/jira-sdlc:<skill-name>`), matching Method 1 —
which is why this is the right loop for editing skills that will ship
through the marketplace.

## Invoking the Three Skills

All three skills set `disable-model-invocation: true`, so Claude Code never
loads them on its own — you always invoke them explicitly:

| Skill | Method 1 / 3 | Method 2 |
|---|---|---|
| Plan a feature into Jira issues + worktrees | `/jira-sdlc:jira-task-assigner` | `/jira-task-assigner` |
| Implement one issue end to end | `/jira-sdlc:jira-task-executor` | `/jira-task-executor` |
| Review the finished set | `/jira-sdlc:jira-task-reviewer` | `/jira-task-reviewer` |

Most take an issue key: `/jira-sdlc:jira-task-executor PROJ-278`.

## Switching to the lab channel

Everything above installs the **main** channel: the three core skills,
reviewed, released, and tagged. The **lab** channel is the same plugin
sourced from the `lab` branch — never behind main, but carrying work that
hasn't landed yet, including extra skills.

> ⚠️ **Caution — lab is the bleeding edge.** It ships the newest code and
> experimental features, and those extras aren't release-gated. They also
> reach wider than the core three do: into your whole workspace rather than
> a single issue's worktree, with the scripts and permissions to match. **If
> you want a stable, released version, stay on main** — switch to lab only
> where you're comfortable with that.

**Method 1 (marketplace)** — re-add the repo with an `@lab` suffix, then
reinstall:

```
/plugin marketplace add kantorv/jira-sdlc-tools@lab
/plugin install jira-sdlc@jira-sdlc-tools
```

**Method 2 / 3 (local clone)** — switch the clone to the branch, then re-run
the copy or the `--plugin-dir` command:

```bash
git switch lab      # in an existing clone
# or a separate checkout, so main stays available:
git clone -b lab https://github.com/kantorv/jira-sdlc-tools.git jira-sdlc-tools-lab
```

**Switching back to main** — re-add the marketplace without the suffix
(`/plugin marketplace add kantorv/jira-sdlc-tools`) and reinstall, or
`git switch main` in the clone.

The lab branch's own
[`LAB-CHANNEL.md`](https://github.com/kantorv/jira-sdlc-tools/blob/lab/LAB-CHANNEL.md)
is the authority on what lab adds and its one lab-only configuration step.

## Platform-Specific Caveats and Known Gaps

### `disable-model-invocation: true`

**Verified** — honored natively; this is the platform the field is defined
by. All three skills set it deliberately, so they are explicit-invocation
only. Note the consequence when you're reading a `description:` field: it is
documentation for humans browsing `/plugin`, not auto-trigger bait, because
that mechanism is off here.

### A marketplace install is a snapshot — don't edit the cache

**Verified.** `/plugin install` copies the plugin into Claude Code's cache;
edits to your clone do not reach it until you reinstall, and edits made
*inside* the cache are lost on the next update. This is the single most
common way to lose skill changes — use Method 3 while editing.

### Method 2 changes the invocation syntax

**Verified.** The bare `/jira-task-executor` form is not cosmetic: the
skills' internal `/jira-sdlc:...` self-references become wrong, and their
healthcheck rerun instructions will name a command your session doesn't
have. Either patch them in the copy or accept the mismatch.

### `_shared/` must stay inside the plugin's `skills/`

**Verified by design.** A marketplace install copies only the plugin's own
root directory, so any relative path climbing above it (`../../_shared`)
stops resolving after install even though it worked from the clone. This
also rules out splitting the three skills into separate plugins that share
one external `_shared/`.

### Windows

The skills dispatch to `_shared/scripts/win/*.ps1` (PowerShell 5.1+) instead
of the POSIX `bash` scripts, decided per-session from the runtime. The ports
are a maintained contract pair — same arguments, output, and exit codes. See
the repo's `AGENTS.md` for the parity-check procedure.
