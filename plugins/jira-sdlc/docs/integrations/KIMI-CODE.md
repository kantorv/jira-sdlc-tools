# Kimi Code Integration (Native Claude Skills Spec)

Uses the native Claude skills specification via `extra_skill_dirs` in `~/.kimi-code/config.toml`.

## Prerequisites

- `acli` (Atlassian CLI) authenticated — see [project-config.md](../../skills/_shared/project-config.md) for the one-time `acli jira auth login`
- `gh` (GitHub CLI) authenticated
- `jira-sdlc-tools.env` and `jira-sdlc-tools.local.env` in your **project** root — see [project-config.md](../../skills/_shared/project-config.md)
- [Kimi Code CLI](https://www.kimi.com/code/) installed

## Install / Wire-up Steps

Kimi Code reads Claude-spec skills natively from paths declared in `extra_skill_dirs` at the top level of `~/.kimi-code/config.toml`. No copy step, no per-skill adaptation file.

1. Add the plugin's `skills` directory to `~/.kimi-code/config.toml`:

   ```toml
   extra_skill_dirs = [
       "</PATH>/plugins/jira-sdlc/skills"
   ]
   ```

2. Replace `</PATH>` with the absolute path where this plugin lives on your machine:
   - **Installed via marketplace**: `~/.claude/plugins/cache/jira-sdlc-tools/jira-sdlc/<version>/skills` — pin to a specific versioned directory (Kimi Code does not auto-update this path; re-point it after a plugin upgrade)
   - **Local clone**: the absolute path to `plugins/jira-sdlc/skills`

   `_shared` sits alongside the three skill folders (no `SKILL.md`, so Kimi Code does not load it as a skill), and the relative references inside each `SKILL.md` stay intact because they point within the same tree.

3. Start a new Kimi Code session — skills are discovered on startup. The three skill descriptions appear in the `/skill` listing.

## Invoking the Three Skills

Kimi Code registers skills as slash commands in the format `/skill:<name>` — there is no plugin namespace:

- `/skill:jira-task-assigner` — break down a task into Jira issues with branches + worktrees
- `/skill:jira-task-executor` — implement an issue end-to-end from its worktree
- `/skill:jira-task-reviewer` — review sub-task PRs from the parent worktree

This is a bare-name invocation, not the `/jira-sdlc:…` namespace Claude Code uses. The cross-references inside the skill bodies (`/jira-sdlc:jira-task-executor`, etc.) are prose pointers — on Kimi Code the user reruns the bare `/skill:jira-task-…` command instead. **Verified** in a live Kimi Code session — this doc was written from a Kimi Code run that loaded the skills via `extra_skill_dirs` and invoked `/skill:jira-task-executor`.

## Platform-Specific Caveats

- **`disable-model-invocation: true` — honoured natively (Verified).** Kimi Code recognizes this frontmatter field as an alias of `disableModelInvocation`: when true, the skill is hidden from automatic model invocation and must be called explicitly via `/skill:<name>`. All three jira-sdlc skills ship with this flag set deliberately (explicit invocation only), and Kimi Code honours it without any per-skill override or adaptation file. **Verified** — this very run exercised `/skill:jira-task-executor` with `disable-model-invocation: true` in its frontmatter, and the skill activated only on the explicit slash command.
- **Skill precedence — Extra tier.** `extra_skill_dirs` lands skills at the Extra tier: Project > User > Extra > Built-in. A project-local `.kimi-code/skills/` or user-level `~/.kimi-code/skills/` skill with the same name overrides one loaded from `extra_skill_dirs`. This matters when the plugin ships a future skill that a project also maintains independently. **Verified** from Kimi Code docs.
- **`KIMI_CODE_HOME` does not move `extra_skill_dirs`-sourced skills (Verified).** If you set `$KIMI_CODE_HOME`, the user-level skills scan directory (`~/.kimi-code/skills/`) moves with it, but `extra_skill_dirs` entries point at absolute paths outside that home — they are unaffected. Only the user-tier skills directory is relocated. **Verified** from Kimi Code docs.
- **Plugin-cache path pins to a version.** Marketplace-installed plugins live under `~/.claude/plugins/cache/jira-sdlc-tools/jira-sdlc/<version>/`. Kimi Code reads the skills directly from that path and does not auto-update the `extra_skill_dirs` entry. After a plugin upgrade (new version directory), re-point `extra_skill_dirs` to the new version path and restart. The manual-copy drift caveat of Mechanism B does not apply — the `extra_skill_dirs` path always reads the installed files as-is. **Verified** (observed with `ls ~/.claude/plugins/cache/jira-sdlc-tools/jira-sdlc/`).
- **Frontmatter field name aliasing.** Kimi Code accepts `disable-model-invocation`, `disableModelInvocation`, and `disable_model_invocation` as equivalent. Jira-sdlc ships with the hyphenated form `disable-model-invocation` (Claude Code canonical), and Kimi Code's docs list it as an explicit alias. **Verified** from Kimi Code docs.
- **Skill nesting limit — 3 levels.** Kimi Code allows up to 3 nested skill invocations; beyond that, invocations are terminated. The jira-sdlc skills do not nest beyond 2 levels (executor calls `ensure_local_env.sh` etc., but those are scripts, not skills). **Verified** from Kimi Code docs — no impact.