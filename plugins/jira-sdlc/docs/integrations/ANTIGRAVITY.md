# Antigravity Integration (Agent Skills spec)

Antigravity does **not** implement the `.agent/` + `agents/openai.yml`
adaptation used by Codex — that tree has no reader anywhere in the shipped
product. Antigravity has two independent working paths instead:

- **Method 1 (recommended) — the bundled Claude Code extension.** Antigravity
  ships the official `anthropic.claude-code` VS Code extension pre-installed.
  This is the native Claude skills spec running unmodified — no adaptation
  layer, and `disable-model-invocation: true` works exactly as it does in
  Claude Code itself.
- **Method 2 — Antigravity's own native skill scanner.** An experimental,
  **off-by-default** setting (`chat.useClaudeSkills`) makes Antigravity read
  unmodified `SKILL.md` files from a `.claude/skills/` tree. It reuses the
  same file format (no `openai.yml` translation needed) but does **not**
  honor `disable-model-invocation` — see Caveats.

> **Verified by inspecting the installed build** (Antigravity 1.107.0,
> Linux): the bundled extension list, `product.json`, and the workbench
> bundle's skill-loading code (`findClaudeSkills`, config key
> `chat.useClaudeSkills`). This confirms the mechanism and its `.claude/skills`
> discovery path, the frontmatter fields it reads, and that no `.agent/` or
> `openai.yml` reader exists in the product. **Not verified**: driving an
> actual chat turn in the Antigravity GUI (no interactive display in the
> environment this doc was written from) — mark the exact UI click-path and
> live invocation behavior as **unverified** where noted below.

## Prerequisites

- `acli` (Atlassian CLI) authenticated — see [project-config.md](../../skills/_shared/project-config.md) for the one-time `acli jira auth login`
- `gh` (GitHub CLI) authenticated
- `jira-sdlc-tools.env` and `jira-sdlc-tools.local.env` in your **project** root — see [project-config.md](../../skills/_shared/project-config.md)
- **Method 1 only** — nothing extra: the Claude Code extension ships inside Antigravity already.
- **Method 2 only** — Antigravity Settings access to toggle an experimental setting (see below).

## Install / Wire-up Steps

### Method 1: Use the bundled Claude Code extension (recommended)

Antigravity is a VS Code–family IDE and ships `anthropic.claude-code` as a
built-in extension, so this is the same flow as [CURSOR.md](CURSOR.md)
Method 1:

1. Open the Claude Code panel/terminal inside Antigravity (**unverified**
   which exact UI surface — sidebar icon vs. integrated terminal running
   `claude` — since this was confirmed by inspecting the installed
   extension, not by clicking through the GUI).
2. Register the marketplace:
   ```
   /plugin marketplace add <GITHUB_OWNER>/<GITHUB_REPO>
   ```
   or, for a local clone:
   ```
   /plugin marketplace add </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>
   ```
3. Install the plugin: `/plugin`, Discover tab, select `jira-sdlc`
   (or `/plugin install jira-sdlc@<MARKETPLACE_NAME>`).
4. Reload the window. Skills are available as `/jira-sdlc:<skill-name>`,
   identical to plain Claude Code.

### Method 2: Antigravity's native `.claude/skills` scanner

1. Enable the experimental setting — search **"Claude Skills"** in
   Antigravity Settings (`chat.useClaudeSkills`), or set it directly:
   ```json
   // settings.json
   "chat.useClaudeSkills": true
   ```
   Default is `false`. The setting is flagged `restricted` in the product's
   config schema, meaning an untrusted workspace's own `.vscode/settings.json`
   cannot silently turn it on for you — enable it yourself in your user
   settings, then trust the workspace.
2. Copy the skill folders into a `.claude/skills/` tree — Antigravity scans
   this path both at the **workspace root** and in your **user home
   directory** (`~/.claude/skills/`); a user-home copy applies across every
   project, a workspace copy applies to this one only:
   ```bash
   mkdir -p .claude/skills
   cp -a </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>/plugins/jira-sdlc/skills/* .claude/skills/
   ```
   If you already did [CURSOR.md](CURSOR.md) Method 2 (drop-in symlinks
   under `~/.claude/skills/`), Antigravity's user-home scan picks that up
   too — no separate copy needed.
3. No `chmod` step needed here (unlike Codex): every script call in these
   skills is written as `bash "<path>"`, never a bare `./script.sh`, so the
   executable bit is never required.
4. `.claude/skills/` (the workspace copy) is a manual copy, not committed —
   gitignore it. There is no sync script; when the plugin updates, re-run
   step 2's copy.
5. Reload the window.

## Invoking the Three Skills

**Method 1** — identical to Claude Code: type `/jira-sdlc:jira-task-assigner`,
`/jira-sdlc:jira-task-executor`, or `/jira-sdlc:jira-task-reviewer` in chat.

**Method 2** — there is no typed invocation command. Antigravity's native
scanner injects each discovered skill's `name` + `description` into the
model's context and tells the model to read the full `SKILL.md` itself
"when a user asks to perform a task that falls within the domain of a
skill" — invocation is entirely model-decided, not user-typed. See the
next section for why that matters here.

## Platform-Specific Caveats

### `disable-model-invocation: true`

- **Method 1**: honored — same runtime as Claude Code.
- **Method 2**: **not reproduced, and cannot be** with this mechanism.
  Verified by inspecting the parser: it extracts only the `name` and
  `description` frontmatter fields when building the model's skill list;
  the string `disable-model-invocation` does not appear anywhere in the
  shipped product. Combined with Method 2's model-decided invocation (no
  slash command), a skill can be auto-loaded from ambient chat context —
  the opposite of what all three skills in this plugin deliberately set.
  **This is why Method 1 is the recommended path** for this plugin
  specifically; use Method 2 only if you understand and accept that gap.

### Drift — the Method 2 copy is not synced

Same caveat as Codex: `.claude/skills/` is a manual copy of
`plugins/jira-sdlc/skills/`. When the plugin updates, the copy goes stale
silently — there is no sync script or version pin. Re-run the copy recipe
(Install step 2) after every plugin update.

### `.agent/` is not a thing here

If you followed the Codex integration first, do not reuse its `.agent/`
tree for Antigravity — Antigravity has no reader for it. The two
mechanisms documented above (`~/.claude/`-family extension, or
`.claude/skills/`) are unrelated to `.agent/skills/`.

### Method 2 is experimental and off by default

Tagged `experimental` in Antigravity's own config schema; behavior may
change across Antigravity releases without notice. Method 1 does not carry
this risk — it rides on the stable, independently-versioned Claude Code
extension.
