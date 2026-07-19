# Grok Build Integration (Native Claude Skills Spec)

Uses the native Claude skills specification. Grok Build (xAI's terminal coding
agent) reads Claude Code marketplaces, plugins, skills, MCP servers, agents,
hooks, and instruction files (`CLAUDE.md`, `CLAUDE.local.md`, `.claude/rules/`)
with zero configuration — same mechanism family as Kilo and Cursor. There is no
`.agent/` tree and no per-skill adaptation file to maintain.

## Prerequisites

- A **SuperGrok** or **X Premium+** subscription (Grok Build requirement)
- **Grok Build** installed — `curl -fsSL https://x.ai/cli/install.sh | bash`
  (macOS/Linux/WSL) or `irm https://x.ai/cli/install.ps1 | iex` (Windows
  PowerShell); the command is `grok`, first launch signs in via browser or
  `XAI_API_KEY`
- `acli` (Atlassian CLI) authenticated — see [project-config.md](../../skills/_shared/project-config.md) for the one-time `acli jira auth login`
- `gh` (GitHub CLI) authenticated
- `jira-sdlc-tools.env` and `jira-sdlc-tools.local.env` in your **project** root — see [project-config.md](../../skills/_shared/project-config.md)

## Install / Wire-up Steps

**Structural rule preserved by every method:** the three skill folders and
`_shared` must stay **siblings**. The `SKILL.md` files reach `_shared` by
relative path, so moving or renaming it breaks them — and never double-nest
(`cp -r plugins/jira-sdlc .grok/skills/` produces
`.grok/skills/jira-sdlc/skills/…`, which Grok does not discover). Copy the
*contents* of `skills/`, not the plugin root.

Pick one method. **Method A leads — it's the least work.**

### Method A — Already installed as a Claude Code plugin (recommended, nothing to do)

If this plugin is installed in Claude Code (it lives under `~/.claude/plugins/…`),
Grok Build reads it automatically. Run `grok` in your project and confirm with
`grok inspect`. Invocation keeps the plugin namespace (`/jira-sdlc:…`, below).

### Method B — Point Grok at the repo, no copying

Add the skills folder to `~/.grok/config.toml` (Windows:
`%USERPROFILE%\.grok\config.toml`):

```toml
[skills]
paths = ["</PATH>/plugins/jira-sdlc/skills"]
```

Replace `</PATH>` with the absolute path where this plugin lives. `_shared`
sits alongside the three skills (no `SKILL.md`, so it isn't loaded as a skill).
No duplication, references intact.

### Method C / D — Copy into a project (C) or globally (D)

Copy the **contents** of `skills/` (trailing `/.`) so the skill folders land
directly under the skills root:

```bash
mkdir -p .grok/skills   && cp -r plugins/jira-sdlc/skills/. .grok/skills/    # C: per-repo
mkdir -p ~/.grok/skills && cp -r plugins/jira-sdlc/skills/. ~/.grok/skills/  # D: every project
```

## Invoking the Three Skills

Open the extensions modal with `/skills` to confirm the three are listed
(`grok inspect` prints the same discovery from the shell), then invoke:

- `/jira-sdlc:jira-task-assigner` — break down a task into Jira issues with branches + worktrees
- `/jira-sdlc:jira-task-executor` — implement an issue end-to-end from its worktree
- `/jira-sdlc:jira-task-reviewer` — review sub-task PRs from the parent worktree

The `/jira-sdlc:…` namespace applies to **Method A** (installed plugin). With a
copy-in / config-path install (Methods B–D) the skills load by folder name, so
invocation is the **bare** form (`/jira-task-assigner`, etc.), and the
`/jira-sdlc:…` cross-references inside the skill bodies must be read as their
bare equivalents — same drop-in caveat documented for Cursor. Reopen `/skills`
(or restart the session) after adding skills so they're picked up.

## Platform-Specific Caveats

- **`disable-model-invocation: true` — expected honoured, verify locally
  (Unverified on a live Grok Build run: not tested this session).** All three
  skills set this deliberately (explicit invocation only — see root `CLAUDE.md`).
  xAI's docs confirm Grok reads Claude skills zero-config and honour
  `user-invocable` (→ `/<skill-name>` slash command) but **do not document
  `disable-model-invocation`**. Because Grok Build targets Anthropic-skill-format
  compatibility, the expected behaviour is that it honours the flag the same way
  the other native-spec platforms do (Kilo and Cursor both honour it — verified
  for those). The native spec has **no per-skill override file** (unlike Codex's
  `agents/openai.yml`), so there is nothing to add: the flag in the shipped
  frontmatter *is* the gate. **Known gap to check:** a cross-platform bug
  ([anthropics/claude-code#38969](https://github.com/anthropics/claude-code/issues/38969),
  mirrored as [openai/codex-plugin-cc#211](https://github.com/openai/codex-plugin-cc/issues/211))
  can make `disable-model-invocation: true` *hide the skill from the command list
  entirely*, blocking even user-initiated invocation. Confirm via `grok inspect`
  / the `/skills` modal that all three skills appear; if one is missing, that's
  the hide-bug — and since native spec offers no alternative mechanism to
  reproduce the gate, a Grok version that ignores the flag while needing the gate
  is a genuine gap to file rather than something this doc can work around.
- **Windows** — Grok installs via the PowerShell one-liner above; config lives at
  `%USERPROFILE%\.grok\config.toml`. Discovery rules are identical; the skills'
  own OS dispatch runs the `_shared/scripts/win/*.ps1` PowerShell twins instead
  of the `posix/*.sh` scripts (see [windows-scripts.md](../windows-scripts.md)).
- **Environment files** are read by the plugin's own scripts (e.g.
  `ensure_local_env.sh`), not by Grok Build — no Grok-specific env support to
  configure; keep them where the scripts expect them.
- **`.grokignore` / `.grok/AGENTS.md`** are not documented Grok features — use
  `.gitignore` for VCS and keep project rules in the `AGENTS.md`/`CLAUDE.md`
  families Grok walks from the working directory up to the repo root.
