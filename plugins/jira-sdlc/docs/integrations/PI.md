# Pi Integration (Native Claude Skills Spec)

Uses the native Claude skills specification.

## Prerequisites

- Jira auth configured — per-request Basic auth from `.jst/jira-sdlc-tools.local.env`, no login step (see [jira-api-reference.md](../../skills/_shared/jira-api-reference.md) §9)
- `gh` (GitHub CLI) authenticated
- `.jst/jira-sdlc-tools.env` and `.jst/jira-sdlc-tools.local.env` in your **project** root — see [project-config.md](../../skills/_shared/project-config.md)

## Install / Wire-up Steps

Pi loads Claude-spec skills natively by pointing at a skills path in `settings.json`. There are two locations — project settings override global settings with field-level merging:

| Scope | Path |
| -- | -- |
| **Project** (use this) | `.pi/settings.json` |
| Global | `~/.pi/agent/settings.json` |

This doc uses the **project** location. It is a **copy-me template, not a committed file** — a checked-in copy would pin a machine-specific absolute path and a stale Pi config; the `</PATH>` token lets each user substitute their own install location.

1. Create `.pi/settings.json` in your **project root**:

   ```json
   {
     "skills": ["</PATH>"]
   }
   ```

   Pi's `skills` is a flat array of paths — unlike Kilo Code's `kilo.jsonc` where skills are a `{ "paths": […] }` object.

2. Replace `</PATH>` with the absolute path to this plugin's `skills` directory on your machine:

   - **Installed via marketplace**: `~/.claude/plugins/jira-sdlc/skills`
   - **Local clone**: the absolute path to `plugins/jira-sdlc/skills`

   `_shared` sits alongside the three skill folders (no `SKILL.md`, so Pi doesn't load it as a skill), and the relative references inside each `SKILL.md` stay intact because they point within the same tree.

   **Path resolution note:** relative paths in `.pi/settings.json` resolve against `.pi/`, not the project root — use an absolute path or `~` for locations outside `.pi/`.

3. Pi automatically discovers and loads the skills on next startup. The three skill descriptions appear in the agent's context; full instructions load on demand when a skill is invoked.

## Invoking the Three Skills

Pi registers skills as slash commands in the format `/skill:<name>` — there is no plugin namespace:

- `/skill:jira-task-assigner` — break down a task into Jira issues with branches + worktrees
- `/skill:jira-task-executor` — implement an issue end-to-end from its worktree
- `/skill:jira-task-reviewer` — review sub-task PRs from the parent worktree

This is a bare-name invocation, not the `/jira-sdlc:…` namespace Claude Code uses. The cross-references inside the skill bodies (`/jira-sdlc:jira-task-executor`, etc.) are prose pointers — on Pi the user reruns the bare `/skill:jira-task-…` command instead. Same namespace-mismatch caveat documented for Cursor drop-in installs.

## Platform-Specific Caveats

- **`disable-model-invocation: true` — honoured (verified against Pi docs, not a live run).** Pi recognizes this frontmatter field: when true, the skill is hidden from the system prompt and the model cannot auto-invoke it; users must explicitly call `/skill:<name>`. All three skills ship with this flag set deliberately (explicit invocation only — see root `CLAUDE.md`), and Pi honours it natively — no per-skill override file or `permission` block needed, unlike OpenCode or Codex. Known gap: Pi's docs list recognized frontmatter as `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`, and `disable-model-invocation` — same recognition set as Kilo Code, with one addition (`allowed-tools` is Pi-experimental).
- **`allowed-tools` — Pi recognizes it (experimental).** The three skills declare `allowed-tools: Bash, Read, Grep, Glob[, Edit], Write, AskUserQuestion` in frontmatter (`Edit` on the executor only); Pi's docs list this as a recognized experimental field — described there as a *space*-delimited list, where these skills use the comma-delimited Claude Code form. Two things are undocumented on Pi's side and therefore unverified here: whether it accepts the comma form, and what it does with a tool name it doesn't recognize — `AskUserQuestion` is Claude-side and has no Pi equivalent, so it is assumed inert rather than an error. Unverified on a live Pi run.
- **No plugin namespace — bare `/skill:name` invocation.** The skill bodies cross-reference each other as `/jira-sdlc:…` (the Claude Code namespace); those are prose-only on Pi. Re-invoke with the bare `/skill:jira-task-…` form.
- **Prefixed paths (`+`/`-`/`!`) — Pi supports glob patterns with exclusions and force-include/force-exclude prefixes in the skills array.** Not needed for a single-directory install like this one; documented here for completeness.
- **`defaultProjectTrust` — non-interactive Pi sessions (`-p`, `--mode json/rpc`) need this set to `"always"`** in the global `~/.pi/agent/settings.json` or they won't load project-local `.pi/settings.json` (and therefore won't discover these skills). The default is `"ask"`, which shows a trust prompt; non-interactive modes skip the prompt and default to not loading project settings.
- **Does not respect skill arguments (Input expansion)**: Pi appends the user's argument text to the bottom of the loaded SKILL.md content as a "User:" prompt rather than an isolated programmatic input. This often causes the model to abandon the skill's workflow and attempt to solve the task directly. **Workaround**: Invoke the skill with NO arguments first (e.g. run `/skill:jira-task-assigner` on its own) so the skill loads its context, then send the task description as a separate follow-up message. Optionally, use Pi's global `APPEND_SYSTEM.md` approach to prioritize the active-skill workflow over default behavior.
- **Verified on a live Pi run in this environment.** The settings paths, precedence, and invocation format were confirmed on a live run. The frontmatter-recognition list is taken from Pi's official docs (`pi.dev/docs/latest/settings`, `pi.dev/docs/latest/skills`). The marketplace-cache path layout was verified for Claude Code on Linux.
