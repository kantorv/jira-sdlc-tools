# Antigravity Integration (Agent Skills spec)

Antigravity implements the Agent Skills (agentskills.io) spec — a skill
folder with a `SKILL.md` file, `name`/`description` loaded up front, full
instructions loaded on activation. The spec itself does not mandate any
particular discovery directory (it defines the skill-folder format, not a
root path), and Antigravity's own native chat panel reads skills straight
from **`.agent/skills/`** — confirmed by a live test: placing this plugin's
three skills at `.agent/skills/<skill-name>/SKILL.md` and typing
`/jira-task-executor` in Antigravity's native (Gemini-based) chat ran it
immediately, no settings changed. Three working paths:

- **Method 1 (recommended) — the bundled Claude Code extension.** Antigravity
  ships the official `anthropic.claude-code` VS Code extension pre-installed.
  This is Claude Code itself running inside Antigravity — no adaptation
  layer, and `disable-model-invocation: true` works exactly as it does in
  plain Claude Code.
- **Method 2 — Antigravity's native `.agent/skills` discovery.** Works out
  of the box in Antigravity's own chat panel; no experimental setting to
  enable. `disable-model-invocation: true` is a Claude Code-specific
  frontmatter field that isn't part of the agentskills.io spec at all, and
  there's no confirmed evidence Antigravity reads it (see Caveats) — treat
  this as the gap that makes Method 1 the safer default for this plugin.
- **Method 3 — Antigravity's `chat.useClaudeSkills` scanner.** A second,
  separate native mechanism found by inspecting the installed product's
  code (not by a live test): an off-by-default setting that reads
  `.claude/skills/` instead of `.agent/skills/`. Real and independent of
  Method 2, but untested live — see its own section below.

> **Verification note.** The `.agent/skills` discovery path and its slash
> invocation (`/<skill-name>`, no setting toggle) are **live-verified** —
> confirmed by directly testing this plugin's skills in Antigravity's
> native chat panel. This directly overrides an earlier version of this doc,
> which claimed (from static analysis of the installed Antigravity 1.107.0
> build) that no `.agent/skills` reader existed — that search was
> exhaustive over literal string matches but evidently missed a
> dynamically-constructed path, since a live test is stronger evidence than
> a grep that can only prove absence of a literal substring, not absence of
> the feature. Static analysis of the same build *did* independently find
> a second, separate mechanism — an off-by-default `chat.useClaudeSkills`
> setting that reads `.claude/skills/` — which is real (confirmed in code)
> but wasn't needed for the live test to succeed, so it's documented as
> Method 3, a fallback rather than the primary path. Whether `disable-model-invocation`
> is honored for ambient (non-slash) invocation under Method 2 has **not**
> been live-tested either way — only explicit slash invocation was tested.

## Prerequisites

- `acli` (Atlassian CLI) authenticated — see [project-config.md](../../skills/_shared/project-config.md) for the one-time `acli jira auth login`
- `gh` (GitHub CLI) authenticated
- `jira-sdlc-tools.env` and `jira-sdlc-tools.local.env` in your **project** root — see [project-config.md](../../skills/_shared/project-config.md)
- **Method 1 only** — nothing extra: the Claude Code extension ships inside Antigravity already.
- **Method 2 only** — nothing extra: no setting to enable, no extension to install.
- **Method 3 only** — Antigravity Settings access to toggle an experimental setting (see below).

## Install / Wire-up Steps

### Method 1: Use the bundled Claude Code extension (recommended)

Antigravity is a VS Code–family IDE and ships `anthropic.claude-code` as a
built-in extension, so this is the same flow as [CURSOR.md](CURSOR.md)
Method 1:

1. Open the Claude Code panel/terminal inside Antigravity (**unverified**
   which exact UI surface — sidebar icon vs. integrated terminal running
   `claude` — this method was confirmed by inspecting the installed
   extension, not by clicking through the GUI; Method 2 below is the one
   that was live-tested end to end).
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

### Method 2: Antigravity's native `.agent/skills` discovery (live-verified)

1. Copy the skill folders into an `.agent/skills/` tree at your project
   root:
   ```bash
   mkdir -p .agent/skills
   cp -a </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>/plugins/jira-sdlc/skills/* .agent/skills/
   ```
2. No `chmod` step needed: every script call in these skills is written as
   `bash "<path>"`, never a bare `./script.sh`, so the executable bit is
   never required.
3. `.agent/skills/` is a manual copy, not committed — gitignore it (a
   single `*` inside a `.agent/.gitignore` works). There is no sync script;
   when the plugin updates, re-run step 1's copy.
4. Nothing to reload or toggle — Antigravity's native chat reads the
   directory directly.

### Method 3: `chat.useClaudeSkills` + `.claude/skills` (code-confirmed, not live-tested)

Found by inspecting the installed Antigravity 1.107.0 build's config
schema and skill-loading code — a second, independent native discovery
mechanism, separate from Method 2 and not required for it. Untested live;
included here in case Method 2 ever regresses or you'd rather use a path
that also covers other spec-compliant clients (Claude Code itself reads
project skills from this same `.claude/skills/` path).

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
2. Copy the skill folders into a `.claude/skills/` tree — the code scans
   this path both at the **workspace root** and in your **user home
   directory** (`~/.claude/skills/`); a user-home copy applies across every
   project, a workspace copy applies to this one only:
   ```bash
   mkdir -p .claude/skills
   cp -a </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>/plugins/jira-sdlc/skills/* .claude/skills/
   ```
   If you already did [CURSOR.md](CURSOR.md) Method 2 (drop-in symlinks
   under `~/.claude/skills/`), this scan picks that up too — no separate
   copy needed.
3. Same no-`chmod`-needed note as Method 2 applies.
4. `.claude/skills/` (the workspace copy) is a manual copy, not committed —
   gitignore it. No sync script here either.
5. Reload the window.
6. **Invocation syntax is unverified** — the code path that parses
   `.claude/skills/` frontmatter only extracts `name`/`description`, the
   same fields Method 2 exposes, so `/skill-name` slash invocation
   *plausibly* works the same way it does for Method 2, but this has not
   actually been tried. Confirm before relying on it.

## Invoking the Three Skills

**Method 1** — identical to Claude Code: type `/jira-sdlc:jira-task-assigner`,
`/jira-sdlc:jira-task-executor`, or `/jira-sdlc:jira-task-reviewer` in chat.

**Method 2** — type the bare skill name as a slash command in Antigravity's
native chat: `/jira-task-assigner`, `/jira-task-executor`, or
`/jira-task-reviewer` (no `jira-sdlc:` namespace — **live-verified** for
`/jira-task-executor`, the other two follow the same `.agent/skills/<name>/`
layout and are expected to match but were not individually retested).

**Method 3** — presumed identical bare-name slash invocation to Method 2
(`/jira-task-executor`, etc.), since the code exposes the same `name` field
the same way, but this is **unverified** — not tried live.

## Platform-Specific Caveats

### `disable-model-invocation: true`

- **Method 1**: honored — same runtime as Claude Code.
- **Method 2**: **no confirmed support**. This field is a Claude Code
  plugin-specific extension, not part of the agentskills.io spec's
  frontmatter (the published spec's table lists only `name`, `description`,
  `license`, `compatibility`, `metadata`, `allowed-tools`). Explicit slash
  invocation (`/jira-task-executor`) is live-verified to work; whether the
  model can *also* load the skill unprompted from ambient chat context —
  the exact thing this field exists to prevent — has not been tested either
  way. **Until that's tested, treat Method 2 as unconfirmed on this point**
  and prefer Method 1 for this plugin, whose three skills all set this field
  deliberately.

### Method 3 is a fallback, not a requirement

Method 2's live test succeeded via `.agent/skills/` without touching
`chat.useClaudeSkills` at all, so Method 3 is not a dependency of Method 2
— it's a separate, code-confirmed mechanism worth knowing about mainly if
`.agent/skills/` ever stops working across an Antigravity update.

### Drift — the Method 2 copy is not synced

Same caveat as Codex: `.agent/skills/` is a manual copy of
`plugins/jira-sdlc/skills/`. When the plugin updates, the copy goes stale
silently — there is no sync script or version pin. Re-run the copy recipe
(Install step 1) after every plugin update.

### `agents/openai.yml` has no confirmed effect in Antigravity

If you're copying from an existing Codex `.agent/`-style tree that includes
`agents/openai.yml` per skill, it's harmless to leave in place but has no
known effect here — an exhaustive search of the installed Antigravity
product found no code that reads `openai.yml` or an
`allow_implicit_invocation` field. Slash invocation worked without it in
the live test. It isn't required for Method 2.
