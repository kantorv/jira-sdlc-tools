# OpenCode Integration (Native Claude Skills Spec)

Uses the native Claude skills specification — the same family as Kilo Code (and Pi): OpenCode auto-discovers `SKILL.md` files under project-local `.opencode/skills/`, `.claude/skills/`, and `.agents/skills/` (walking up from the working directory to the git worktree root) and under the global `~/.config/opencode/skills/`, `~/.claude/skills/`, and `~/.agents/skills/`, and also accepts explicit `skills.paths` in `opencode.json`. Unlike Kilo Code, **OpenCode does not honour `disable-model-invocation: true`** — only `name`, `description`, `license`, `compatibility`, and `metadata` are recognized skill-frontmatter fields; unknown fields are ignored — so the three skills' explicit-only invocation is reproduced through an `opencode.json` override. That override is the one real difference from a Kilo Code setup.

## Prerequisites

- `acli` (Atlassian CLI) authenticated — see [project-config.md](../../skills/_shared/project-config.md)
- `gh` (GitHub CLI) authenticated
- `jira-sdlc-tools.env` and `jira-sdlc-tools.local.env` — see [project-config.md](../../skills/_shared/project-config.md)
- **OpenCode** installed (`opencode` in your PATH). The OpenCode-specific steps below were **not** run in OpenCode in the environment this doc was written in (`opencode` was not installed there); the config keys and behaviours are taken from the OpenCode config JSON schema (`https://opencode.ai/config.json`) and the official skills / commands / permissions docs (opencode.ai/docs). See the Platform-Specific Caveats for what is verified vs. unverified.

## Install / Wire-up Steps

Everything lives in one project-root `opencode.json` (the direct analog of Kilo Code's `kilo.jsonc`). It does three things at once: points OpenCode at this plugin's skills, keeps the model from auto-invoking them, and registers the explicit slash commands that run them inline. It is a **copy-me template, not a committed file** — the same decision KILO.md made for `kilo.jsonc`: a checked-in copy would pin a machine-specific absolute path (and a model id that goes stale); the `</PATH>` token lets each user substitute their own install location, and the repo stays free of per-machine config.

1. Create `opencode.json` in your **project root** (OpenCode does not read it from `.opencode/`; JSONC `opencode.jsonc` is also accepted):

   ```json
   {
     "$schema": "https://opencode.ai/config.json",
     "skills": {
       "paths": ["</PATH>"]
     },
     "permission": {
       "skill": {
         "jira-task-assigner": "deny",
         "jira-task-executor": "deny",
         "jira-task-reviewer": "deny"
       }
     },
     "command": {
       "jira-task-assigner": {
         "description": "Break a feature/task/bug into Jira issues, branches, and worktrees.",
         "subtask": false,
         "template": "Read and execute the jira-task-assigner skill instructions in </PATH>/jira-task-assigner/SKILL.md. $ARGUMENTS"
       },
       "jira-task-executor": {
         "description": "Implement the issue implied by the current worktree's branch end-to-end.",
         "subtask": false,
         "template": "Read and execute the jira-task-executor skill instructions in </PATH>/jira-task-executor/SKILL.md. $ARGUMENTS"
       },
       "jira-task-reviewer": {
         "description": "Review sub-task PRs from the parent issue's worktree.",
         "subtask": false,
         "template": "Read and execute the jira-task-reviewer skill instructions in </PATH>/jira-task-reviewer/SKILL.md. $ARGUMENTS"
       }
     }
   }
   ```

   What each block does:

   - `skills.paths` — points OpenCode's skill discovery at this plugin's `skills` directory (this is the OpenCode analog of Kilo's `kilo.jsonc` `skills.paths`).
   - `permission.skill.<name>: "deny"` — keeps each of the three skills out of the agent's available-skills list so the model cannot auto-invoke it from ambient chat; this is how OpenCode reproduces `disable-model-invocation: true` (which it ignores).
   - `command.<name>` — registers the explicit `/<name>` slash command that runs the skill inline; its `template` points the model at the matching `SKILL.md`, and `subtask: false` keeps it in the primary session (see Caveats).

2. Replace `</PATH>` with the absolute path to this plugin's `skills` directory on your machine:
   - **Local clone** (stable, recommended): `…/jira-sdlc-tools/plugins/jira-sdlc/skills` — the directory that contains the three skill folders plus `_shared/`.
   - **Marketplace install**: `~/.claude/plugins/cache/<MARKETPLACE>/jira-sdlc/<version>/skills` — this path is version-stamped and changes on reinstall, so it is more fragile than a clone path.

3. Restart OpenCode (or reload its config) so the new `opencode.json`, skills, and commands take effect. The three `/jira-task-*` commands appear in the command list.

   Alternatively, drop a copy or symlink of the three skill folders plus `_shared/` into `.opencode/skills/` (or `.claude/skills/`) at your project root so OpenCode discovers them without a `paths` entry — in which case, drop the `skills.paths` line and adjust each command's `template` to the discovered location.

## Invoking the Three Skills

Call the explicit slash commands registered above. OpenCode has no plugin namespace, so the commands are bare (not `/jira-sdlc:…`):

- `/jira-task-assigner` — break down a task into Jira issues with branches
- `/jira-task-executor` — implement an issue from its worktree
- `/jira-task-reviewer` — review sub-task PRs from the parent worktree

Because `permission.skill.<name>: "deny"` keeps each skill out of the model's available-skills, the model will not auto-trigger these skills on ambient chat — they run only via the commands above.

## Platform-Specific Caveats

- **`disable-model-invocation: true` is not honoured.** Recognized skill frontmatter on OpenCode is `name`, `description`, `license`, `compatibility`, `metadata` only; unknown fields (including `disable-model-invocation`) are ignored. The reproduction is two-part: `permission.skill.<name>: "deny"` keeps each skill out of the agent's available-skills so the model cannot auto-invoke it, and `command.<name>` provides the explicit `/`-command. *Known gap:* OpenCode's `"deny"` blocks the skill's `skill`-tool load entirely — it does not distinguish auto- vs. explicit-tool invocation the way Claude's flag does — so the explicit surface comes **only** from the registered `command`, not from the skill tool. The net behaviour matches Claude's "explicit-only" intent, but the mechanism is "command-only," not "skill-registered-but-gated." If any user needs a skill callable *both* ways on OpenCode, that is not reproducible with `deny`; leave that skill out of the `permission.skill` block and rely on it being ignored by description only.
- **`allowed-tools` is also ignored.** The skills declare `allowed-tools: Bash, Read, Grep, Glob[, Edit, Write]` in frontmatter; OpenCode does not read this field. Tool access during a run is governed instead by OpenCode's own `permission` config (`bash`, `edit`, `read`, `webfetch`, etc. → `allow` / `ask` / `deny`). Expect approval prompts for `bash` / `edit` / `write` unless your config allows them up front.
- **`subtask: false` keeps each run inline (live context).** Each command sets `subtask: false` so it executes in the primary session rather than an isolated subagent; the scripts the skills run then see live session context (recent discussion, in-session variables). With `subtask: true` — or if the default agent runs in subagent mode — the skill runs in an isolated subagent without that context, which is not what these skills want, since they shell out to scripts that read local env and branch state.
- **No pinned model id.** The `model` field is deliberately omitted from each `command`, so commands inherit the session / default model instead of pinning a literal that goes stale. Add a `model` to a command only if you want to pin one; any literal written today will eventually read as stale.
- **The marketplace cache is not auto-discovered.** OpenCode discovers the `.opencode/skills/`, `.claude/skills/`, and `.agents/skills/` trees (project-local, walking up to the git worktree root) plus the `~/.config/opencode/skills/`, `~/.claude/skills/`, and `~/.agents/skills/` globals — but **not** Claude Code's `~/.claude/plugins/cache/`. A Claude-Code marketplace install of this plugin is therefore not picked up automatically; point `skills.paths` at the cache path explicitly (version-stamped — see step 2) or use a local clone. (The shared `~/.claude/skills/` global *is* discovered, so a global drop-in there is seen by both Claude Code and OpenCode.)
- **`external_directory` may gate reads of skills outside the project.** If `</PATH>` points outside your project root (the marketplace cache, or a clone elsewhere on disk), OpenCode's `external_directory` permission may prompt before the model reads the `SKILL.md`. Allow it in your config, or use the drop-in / symlink alternative in step 3 so the skills live inside the project.
- **The skill bodies cross-reference each other as `/jira-sdlc:…`.** Internally the three `SKILL.md` files refer to sibling skills by the Claude Code plugin namespace (e.g. "re-run `/jira-sdlc:jira-task-executor`"). Those are prose pointers, not commands OpenCode can invoke; on OpenCode the user re-runs the bare `/jira-task-…` command instead. (The same namespace-mismatch note applies to drop-in installs — see CURSOR.md Method 2.)
- **Unverified in OpenCode in this environment.** `opencode` was not installed where this doc was written, so the install and invocation steps were not run end-to-end in OpenCode. The config keys, the frontmatter-recognition list, the `subtask` semantics, and the `permission`-vs-`disable-model-invocation` distinction are taken from the OpenCode config JSON schema (`https://opencode.ai/config.json`) and the official skills / commands / permissions docs (opencode.ai/docs). The command `template` here uses a read-pointer for robustness; OpenCode templates also support `@<filepath>` inlining (see the commands doc), which is more idiomatic but was not tested here. Verify in a real OpenCode session before relying on it; the one Claude-Code-adjacent fact cited (the marketplace-cache path layout) was verified for Claude Code / Cursor on Linux, not for OpenCode.
