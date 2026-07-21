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
  frontmatter field that isn't part of the agentskills.io spec, so it does
  nothing here — its spec-side analogue is a per-skill
  `agents/openai.yml` carrying `policy: allow_implicit_invocation: false`,
  and this plugin's skills need it (install step 2 below).
- **⚠️ Method 3 (unconfirmed) — Antigravity's `chat.useClaudeSkills` scanner.** A second,
  separate native mechanism found by inspecting the installed product's
  code (not by a live test): an off-by-default setting that reads
  `.claude/skills/` instead of `.agent/skills/`. Real and independent of
  Method 2, but untested live — see its own section below.

> **Verification note.** The `.agent/skills` discovery path and its slash
> invocation (`/<skill-name>`, no setting toggle) are **live-verified** (specifically tested on Antigravity IDE 1.23.2 and agy 1.0.8; other releases are untested) —
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
> Method 3, a fallback rather than the primary path. What has **not** been
> live-tested under Method 2 is *ambient* (non-slash) invocation — only
> explicit slash invocation was tested — so the `agents/openai.yml` policy
> file that suppresses it is documented below as a required install step
> rather than as a verified behavior.

## Prerequisites

- `acli` (Atlassian CLI) authenticated — see [project-config.md](../../skills/_shared/project-config.md) for the one-time `acli jira auth login`
- `gh` (GitHub CLI) authenticated
- `jira-sdlc-tools.env` and `jira-sdlc-tools.local.env` in your **project** root — see [project-config.md](../../skills/_shared/project-config.md)
- **Method 1 only** — nothing extra: the Claude Code extension ships inside Antigravity already.
- **Method 2 only** — no setting to enable and no extension to install, but you do write one `agents/openai.yml` per skill (install step 2).
- **⚠️ Method 3 only (unconfirmed)** — Antigravity Settings access to toggle an experimental setting, plus the same per-skill `agents/openai.yml` (see below).

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
2. Add an `agents/openai.yml` policy file to each skill — this is the
   agentskills.io-side analogue of Claude Code's
   `disable-model-invocation: true`, which Antigravity does not read:
   ```bash
   for skill in jira-task-assigner jira-task-executor jira-task-reviewer; do
     mkdir -p ".agent/skills/$skill/agents"
     printf 'policy:\n  allow_implicit_invocation: false\n' \
       > ".agent/skills/$skill/agents/openai.yml"
   done
   ```
   Same content as [CODEX.md](CODEX.md) step 2 — the file is not part of the
   Claude plugin source, it's the adaptation you write per platform. All
   three skills are built to be run deliberately (they create Jira issues,
   push branches, open PRs), so leaving it out means the model may load one
   from ambient chat context on a prompt that merely *sounds* like the job.
3. No `chmod` step needed: every script call in these skills is written as
   `bash "<path>"`, never a bare `./script.sh`, so the executable bit is
   never required.
4. `.agent/skills/` is a manual copy, not committed — gitignore it (a
   single `*` inside a `.agent/.gitignore` works). There is no sync script;
   when the plugin updates, re-run step 1's copy.
5. Nothing to reload or toggle — Antigravity's native chat reads the
   directory directly.

### ⚠️ Method 3 (unconfirmed): `chat.useClaudeSkills` + `.claude/skills`

> **⚠️ Unconfirmed.** Every step below comes from reading the installed
> product's code, not from running it. No one has enabled the setting and
> invoked a skill this way end to end. Use Method 1 or 2 unless you are
> deliberately exploring this path.

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
3. Add the same per-skill `agents/openai.yml` as Method 2 step 2, under
   `.claude/skills/$skill/agents/` — this scanner reads only
   `name`/`description` out of the frontmatter, so
   `disable-model-invocation: true` is inert on this path too.
4. Same no-`chmod`-needed note as Method 2 applies.
5. `.claude/skills/` (the workspace copy) is a manual copy, not committed —
   gitignore it. No sync script here either.
6. Reload the window.
7. **Invocation syntax is unverified** — the code path that parses
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

**⚠️ Method 3 (unconfirmed)** — presumed identical bare-name slash invocation to Method 2
(`/jira-task-executor`, etc.), since the code exposes the same `name` field
the same way, but this is **unverified** — not tried live.

## Platform-Specific Caveats

### `disable-model-invocation: true`

- **Method 1**: honored as-is — same runtime as Claude Code, nothing to add.
- **Methods 2 and 3**: the frontmatter field itself does nothing. It is a
  Claude Code plugin-specific extension, not part of the agentskills.io
  spec's frontmatter (the published spec's table lists only `name`,
  `description`, `license`, `compatibility`, `metadata`, `allowed-tools`),
  so you re-express the intent in `agents/openai.yml` instead:
  ```yaml
  policy:
    allow_implicit_invocation: false
  ```
  Write it for all three skills (install step 2) — this plugin's skills are
  explicit-only by design and this file is what carries that across.
  Note what it does and doesn't buy you: explicit invocation
  (`/jira-task-executor`) works with or without the file — that much is
  live-verified — so the policy is not a prerequisite for *running* a skill.
  It's what stops the router from semantic-matching an ambient prompt onto a
  skill that creates Jira issues and opens PRs. Antigravity's enforcement of
  the flag has not been live-tested (see below), so on Methods 2/3 treat the
  suppression as intended-but-unconfirmed; Method 1 is the path where
  explicit-only is guaranteed.

### ⚠️ Method 3 is an unconfirmed fallback, not a requirement

Method 2's live test succeeded via `.agent/skills/` without touching
`chat.useClaudeSkills` at all, so Method 3 is not a dependency of Method 2
— it's a separate, code-confirmed mechanism worth knowing about mainly if
`.agent/skills/` ever stops working across an Antigravity update.

### Drift — the Method 2 copy is not synced

Same caveat as Codex: `.agent/skills/` is a manual copy of
`plugins/jira-sdlc/skills/`. When the plugin updates, the copy goes stale
silently — there is no sync script or version pin. Re-run the copy recipe
(Install step 1) after every plugin update.

### `agents/openai.yml` — write it, but don't over-trust it

A search of the installed Antigravity 1.107.0 build found no code reading
`openai.yml` or an `allow_implicit_invocation` field, and the live test
invoked a skill fine without one. Neither observation means the policy is
ignored: a grep over a shipped build can only prove a literal string is
absent, not a feature — the same reasoning that made this doc wrongly
declare `.agent/skills/` unsupported until a live test contradicted it (see
the Verification note). Nor does explicit invocation working tell you
anything about implicit invocation, which is the only thing the policy
governs.

So the file is part of the install for Methods 2 and 3, and it costs
nothing if Antigravity turns out to ignore it. What's still open is whether
ambient invocation is actually blocked — nobody has tried to provoke it.
Until someone does, Method 1 remains the recommended path for this plugin.
