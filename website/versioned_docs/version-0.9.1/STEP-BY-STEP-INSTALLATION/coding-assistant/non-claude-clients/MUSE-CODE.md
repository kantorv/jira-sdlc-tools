---
slug: /integrations/muse-code
sidebar_position: 11
sidebar_label: Muse Code
---

# Muse Code Integration (Native Claude Skills Spec)

Uses the native Claude skills specification via Muse Code's own plugin marketplace: `muse plugins marketplace add` + `muse plugins install` load the plugin as a `claude-compatible` bundle, `_shared/` included.

## Prerequisites

- Jira auth configured — per-request Basic auth from `.jst/jira-sdlc-tools.local.env`, no login step (see [jira-api-reference.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/jira-api-reference.md) §9)
- `gh` (GitHub CLI) authenticated
- `.jst/jira-sdlc-tools.env` and `.jst/jira-sdlc-tools.local.env` in your **project** root — see [project-config.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md)
- Meta's Muse Code CLI installed (`muse` on `PATH`) and logged in (`muse login`), with an active subscription — `muse usage` shows the allowance. Written against **Muse Code 1.4.13** (`1.4.13-R6996.1`) on Linux.
- Muse's credentials live in `~/.config/muse/auth.json`. Never print or paste that file.

## Install / Wire-up Steps

Muse Code reads Claude Code plugin bundles natively, so the install mirrors Claude Code's marketplace flow. No copy step, no per-skill adaptation file.

1. Check the bundle (optional, read-only):

   ```bash
   muse plugins validate </PATH>/plugins/jira-sdlc
   ```

   Expect `valid jira-sdlc claude-compatible skills=4`. The eight warnings are expected (see the caveats below).

2. Register this repo as a marketplace and install the plugin from it:

   ```bash
   muse plugins marketplace add jira-sdlc-tools </PATH-OR-GIT-URL>   # the repo root, which holds .claude-plugin/marketplace.json
   muse plugins install jira-sdlc@jira-sdlc-tools
   ```

   Replace `</PATH-OR-GIT-URL>` with the absolute path to a local clone, or with the repo's git URL. Muse snapshots the marketplace, then copies the whole plugin root into its own cache (`~/.local/share/muse/plugins/cache/local/jira-sdlc/<hash>/package/`). `_shared/` arrives intact, next to the four skill folders.

3. Confirm the skills are registered:

   ```bash
   muse skills list --source plugin
   ```

   Each of the four shows as `plugin:jira-sdlc:<skill>` with activation **`user-invocable-only`**, which is the `disable-model-invocation: true` frontmatter honoured.

`muse plugins install <path> --scope user|project` (a local bundle, no marketplace) and `muse skills install` / `muse skills import --from claude` are also listed by the CLI. They are not covered here, because the marketplace route is the one that keeps `_shared/` next to the skills and was run live.

## Invoking the Three Skills

Start the interactive TUI (`muse`) from where each skill expects to run, and use the same slash commands as Claude Code:

- `/jira-sdlc:jira-task-assigner` — break down a task into Jira issues with branches + worktrees (from the main checkout)
- `/jira-sdlc:jira-task-executor` — implement an issue end-to-end from its worktree
- `/jira-sdlc:jira-task-reviewer` — review the issue's PRs from its worktree

`/jira-sdlc:jst-install` sets a project up. Muse also offers a bare alias for each (`/jira-task-assigner`, `/jst-install`, …), but the namespaced form is the one the skills' own cross-references use. Text after the command reaches the model: Muse leaves `$ARGUMENTS` unexpanded in the skill body and appends the arguments after it, which is enough for the assigner's free-form task and the notes the other skills accept. **Verified** in the TUI.

The first run in a directory asks whether to trust the workspace. Trusting only loads project-local skills and rules — the plugin's skills load either way.

## Platform-Specific Caveats and Known Gaps

- **`disable-model-invocation: true` — honoured natively (Verified).** The skills register as `user-invocable-only`. When the model tries to load one itself, `read_skill` returns `code: disabled-skill`, and the model stops and asks rather than improvising. Only the user's slash command loads them.
- **No headless route (Verified).** The flip side of the point above: `muse exec` passes `/jira-sdlc:<skill>`, `/plugin:jira-sdlc:<skill>` and `/skill <id>` to the model as plain text, the model's `read_skill` is refused, and the run ends asking for confirmation. These skills therefore run in the TUI only, so there is no Muse equivalent of the `claude -p` CI demos.
- **Script paths resolve with no fallback (Verified).** Muse substitutes `${CLAUDE_PLUGIN_ROOT}` in the skill body with the cached plugin root and passes the skill's own `skill-dir`, so every `_shared/scripts/posix/` call hits the cache copy directly. The skills' "Locating the shared scripts" fallback never runs, and Muse needs no entry in its skills-locations list.
- **Sandbox needs unprivileged user namespaces.** Muse's Linux sandbox is Bubblewrap. On Ubuntu 24.04, AppArmor restricts unprivileged user namespaces (`kernel.apparmor_restrict_unprivileged_userns = 1`) and every sandboxed command fails with `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`. Muse then offers to rerun the command outside the sandbox, which needs approval. Approved, `ensure_local_env`, `check_assignee`, `statuscheck` (Jira REST, `gh auth`, `gh api`) all ran (**Verified**). Whether git, `gh` and Jira calls work *inside* a working sandbox — whose network mode defaults to `proxy-only` — and whether it allows writes to `WORKTREES_DIR` outside the workspace is **Unverified**. Compare Codex's `writable_roots` caveat.
- **`allowed-tools` is not enforced.** Muse reports that the skills' `allowed-tools` lists can't be represented exactly and runs them under ordinary approval, so you approve each command, as with any other Muse tool call. The `plugin.json` `author`/`keywords`/`license`/`repository` warnings are presentation-only.
- **The cache is a snapshot.** Like Claude Code, Muse copies the plugin at install time, so edits to your clone don't reach it. `muse plugins marketplace update jira-sdlc-tools` then `muse plugins update jira-sdlc` should refresh it (**Unverified**).
- **What was run.** Under Muse Code 1.4.13 on this repo: the marketplace install, `/jira-sdlc:jira-task-executor` up to its credential gate (it stopped as designed, outside any project), and the assigner's step 1 healthcheck from the main checkout — every row as expected, and the skill stopped when told to. **Not yet run under Muse:** the assigner's issue creation and a full executor or reviewer pass.
