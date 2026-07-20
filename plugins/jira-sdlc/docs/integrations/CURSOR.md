# Cursor Integration (Native Claude Skills Spec)

Uses the native Claude skills specification. Cursor reads plugin and skill configuration from your system's `~/.claude/` directory (the same tree Claude Code uses), so a marketplace install performed once in Claude Code is available in Cursor after a window reload.

## Prerequisites

- `acli` (Atlassian CLI) authenticated — see [project-config.md](../../skills/_shared/project-config.md)
- `gh` (GitHub CLI) authenticated
- `jira-sdlc-tools.env` and `jira-sdlc-tools.local.env` in your **project** root — see [project-config.md](../../skills/_shared/project-config.md)
- **Claude Code CLI** — required for Method 1 only (`/plugin marketplace add`, `/plugin install`). Cursor does not replace this step; it picks up what Claude Code writes under `~/.claude/`.

## Install / Wire-up Steps

Choose one method. Method 1 is verified on Linux with Cursor loading skills from `~/.claude/plugins/cache/` after install.

### Method 1: Register via Claude Code marketplace (recommended)

1. **Register the marketplace** — in a **Claude Code** session (not a plain shell), add this repo as a known marketplace source. Use either a git remote or a local clone path:

   ```
   /plugin marketplace add <GITHUB_OWNER>/<GITHUB_REPO>
   ```

   or, for a local clone:

   ```
   /plugin marketplace add </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>
   ```

   The marketplace root is the directory that contains `.claude-plugin/marketplace.json` (not the `plugins/jira-sdlc/` plugin root).

2. **Install the plugin** — still in Claude Code, open the plugin manager:

   ```
   /plugin
   ```

   Switch to the **Discover** tab, select the `jira-sdlc` entry, and install it (`/plugin install jira-sdlc@<MARKETPLACE_NAME>` also works if you know the marketplace name from step 1).

   Verified install layout: `~/.claude/plugins/cache/<marketplace>/jira-sdlc/<version>/skills/` (three skill folders plus `_shared/`).

3. **Reload Cursor** — Command Palette → **Developer: Reload Window**. Skills appear in Chat/Composer as `/jira-sdlc:<skill-name>`.

### Method 2: Drop-in skill folders (no marketplace)

Use this when you want a working copy of the skills without registering a marketplace. This follows the plugin README's "Option B — Drop-in" layout, not a symlink of the plugin root.

1. **Copy or symlink the skill directories** — the contents of `plugins/jira-sdlc/skills/`, not the plugin root:

   ```bash
   mkdir -p ~/.claude/skills/
   cp -r </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>/plugins/jira-sdlc/skills/* ~/.claude/skills/
   ```

   Or symlink each folder individually if you prefer to track a local clone:

   ```bash
   ln -s </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>/plugins/jira-sdlc/skills/jira-task-assigner ~/.claude/skills/jira-task-assigner
   ln -s </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>/plugins/jira-sdlc/skills/jira-task-executor ~/.claude/skills/jira-task-executor
   ln -s </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>/plugins/jira-sdlc/skills/jira-task-reviewer ~/.claude/skills/jira-task-reviewer
   ln -s </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>/plugins/jira-sdlc/skills/_shared ~/.claude/skills/_shared
   ```

   **Do not** symlink the plugin root (`plugins/jira-sdlc/`) into `~/.claude/skills/` — that directory expects one folder per skill (each containing `SKILL.md`), not a plugin manifest tree. Verified by inspecting the installed cache layout under `~/.claude/plugins/cache/`.

2. **Reload Cursor** — Command Palette → **Developer: Reload Window**.

   **Unverified:** whether Cursor loads drop-in folders from `~/.claude/skills/` the same way Claude Code does. Method 1 is the path verified in Cursor on Linux for this plugin.

## Invoking the Three Skills

With a marketplace install (Method 1), call each skill using the plugin namespace:

- `/jira-sdlc:jira-task-assigner` — break down a task into Jira issues with branches
- `/jira-sdlc:jira-task-executor` — implement an issue from its worktree
- `/jira-sdlc:jira-task-reviewer` — review sub-task PRs from the parent worktree

With drop-in install (Method 2), invocation is the bare form (`/jira-task-assigner`, etc.) and the three `/jira-sdlc:…` cross-references inside the skill bodies must be edited back to bare names — see the plugin README "Option B — Drop-in".

## Platform-Specific Caveats

- **`disable-model-invocation: true`** — all three skills set this deliberately. Cursor honours it: the model will not auto-load these skills from ambient chat context; invoke them explicitly via slash-command (attach or type `/jira-sdlc:…`). Same behaviour as documented for Kilo Code.
- **Method 1 needs Claude Code once** — marketplace registration and install are Claude Code `/plugin` commands. Cursor consumes the result from `~/.claude/`; there is no separate Cursor marketplace UI for this plugin (unverified whether one exists in future Cursor builds).
- **Active development** — editing a marketplace-installed copy does not update the cache. For local plugin work, use Claude Code's `--plugin-dir` pointed at `plugins/jira-sdlc/` (see root `CLAUDE.md`), or reinstall after changes.
- **Cursor-native skill paths** — Cursor also supports `~/.cursor/skills/` and `.cursor/skills/` for its own skill format. That path was **not** tested for this plugin; this doc covers the shared `~/.claude/` tree only.
- **Windows drop-in** — Linux/macOS paths above are what this doc was verified against. On Windows, the same copy layout applies under `%USERPROFILE%\.claude\skills\`; PowerShell one-liners for bulk copy were not tested here.
