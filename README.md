# jira-sdlc-tools

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A Claude Code plugin marketplace for Jira-tracked, parallel feature
delivery via git worktrees.

## What's here

This repo currently hosts one plugin, **[`jira-sdlc`](plugins/jira-sdlc)**
— three coupled skills (`jira-task-assigner`, `jira-task-executor`,
`jira-task-reviewer`) that turn a feature request into Jira issues and
git worktrees, implement each piece in parallel, and then review and
merge the result as a single unit, leaving only the final release merge
for a human.

This page is the front door. Everything about how the plugin actually
works — architecture, prerequisites, configuration, a full usage
walkthrough, safety model, and troubleshooting — lives in
[`plugins/jira-sdlc/README.md`](plugins/jira-sdlc/README.md).

The three skills, one per stage of the lifecycle:

- **[`jira-task-assigner`](plugins/jira-sdlc/skills/jira-task-assigner/SKILL.md)** — turns a feature/task/bug description into
  Jira issues with matching git branches and worktrees. Investigates the
  codebase, asks clarifying questions, decides whether the request is one
  self-contained task or a multistep split into parallel sub-tasks, and
  gives every leaf issue its own branch and worktree so parallel work can
  start immediately.
- **[`jira-task-executor`](plugins/jira-sdlc/skills/jira-task-executor/SKILL.md)** — implements the issue implied by the current
  worktree's branch, end to end: status transition, investigation,
  implementation, tests, commit, push, and PR. No issue-key argument —
  run it from inside the issue's own worktree.
- **[`jira-task-reviewer`](plugins/jira-sdlc/skills/jira-task-reviewer/SKILL.md)** — run from the parent issue's worktree.
  Reviews each sub-task PR into the parent branch (approve or request
  changes), posts findings to Jira, and reviews the parent PR into the
  base branch once the sub-task PRs are merged. Never merges anything
  itself.

## Other AI assistants

The skills target the Claude skills spec, so `jira-sdlc` also works —
natively or through the [Agent Skills](https://agentskills.io)
adaptation — in a growing set of other AI coding assistants: Cursor, Kilo
Code, NVIDIA NIM (via fcc), Codex, Antigravity, OpenCode, Grok Build, and
Pi. See [**Integrations**](INTEGRATIONS.md) for the platform-by-platform
table — each one's spec, wiring, integration status, and a link to its
detailed doc.

| Platform | Specification | How it loads | Integration status | Verified | Documentation |
|---|---|---|---|---|---|
| [Claude Code](plugins/jira-sdlc/README.md) | Native Claude skills | plugin marketplace or `--plugin-dir` | First-class (reference) | ✅ | [`plugins/jira-sdlc/README.md`](plugins/jira-sdlc/README.md) |
| [Cursor](plugins/jira-sdlc/docs/integrations/CURSOR.md) | Native Claude skills | shares the `~/.claude/` tree with Claude Code | Verified — Linux/macOS | ✅ | [`CURSOR.md`](plugins/jira-sdlc/docs/integrations/CURSOR.md) |
| [Kilo Code](plugins/jira-sdlc/docs/integrations/KILO.md) | Native Claude skills | `kilo.jsonc` skills path | Working | ⚠️ | [`KILO.md`](plugins/jira-sdlc/docs/integrations/KILO.md) |
| [NVIDIA NIM](plugins/jira-sdlc/docs/integrations/NVIDIA-NIM.md) | Native Claude skills, via fcc | Anthropic-compatible model proxy → Claude Code loads the skills | Draft — architecture verified; live NIM run unverified | ❌ | [`NVIDIA-NIM.md`](plugins/jira-sdlc/docs/integrations/NVIDIA-NIM.md) |
| [Codex (CLI)](plugins/jira-sdlc/docs/integrations/CODEX.md) | Agent Skills | `.codex/skills/` copy + per-skill `agents/openai.yml` | Verified — sandbox caveats | ✅ | [`CODEX.md`](plugins/jira-sdlc/docs/integrations/CODEX.md) |
| [Antigravity](plugins/jira-sdlc/docs/integrations/ANTIGRAVITY.md) | Agent Skills | `.agent/skills/` discovery (live-tested) | Verified | ✅ | [`ANTIGRAVITY.md`](plugins/jira-sdlc/docs/integrations/ANTIGRAVITY.md) |
| [OpenCode](plugins/jira-sdlc/docs/integrations/OPENCODE.md) | Native Claude skills | `.opencode/skills/` discovery + `opencode.json` override | Draft — not run in this environment | ❌ | [`OPENCODE.md`](plugins/jira-sdlc/docs/integrations/OPENCODE.md) |
| [Grok Build (xAI)](plugins/jira-sdlc/docs/integrations/GROK.md) | Native Claude skills | reads Claude Code skills, plugins, and hooks zero-config | Working — flag honour unverified | ⚠️ | [`GROK.md`](plugins/jira-sdlc/docs/integrations/GROK.md) |
| [Pi (pi.dev)](plugins/jira-sdlc/docs/integrations/PI.md) | Native Claude skills | `settings.json` skills path | Draft — not run in this environment | ❌ | [`PI.md`](plugins/jira-sdlc/docs/integrations/PI.md) |

**Verified:** ✅ first-class or verified in a live session · ⚠️ working, not
run end-to-end here · ❌ draft, not yet exercised in this environment. See
[Integrations](INTEGRATIONS.md) for the full status legend.

## Task lifecycle preview

The three skills map to three phases of a task's life. The Jira states
below use the default Kanban board names (To Do / In Progress / In
Review) — these are configurable per project, so map them to your own
workflow's status names.

```mermaid
flowchart LR
    Kickoff([👤<br/>Phase 0 · Kickoff<br/>Human<br/>invokes /jira-task-assigner]) -->|feature · task · bug| Plan
    Plan([🤖<br/>Phase 1 · Plan<br/>jira-task-assigner<br/>To Do]) -->|create issues<br/>branches<br/>worktrees| Execute([🤖<br/>Phase 2 · Implement<br/>jira-task-executor<br/>In Progress])
    Execute -->|implement<br/>run tests<br/>open PRs| Review([🤖<br/>Phase 3 · Review<br/>jira-task-reviewer<br/>In Review])
    Review -->|changes requested<br/>back to In Progress| Execute
    Review -->|approved<br/>verdicts posted| Merge([👤<br/>Phase 4 · Merge<br/>Human<br/>Done])
```

<table>
<tr>
<td align="center" valign="top" width="33%">
<strong>Phase 1 · Plan</strong><br>
<code>jira-task-assigner</code><br>
<a href="plugins/jira-sdlc/docs/TASK-LIFECYCLE-PHASE-1.md">Full diagram &amp; notes →</a><br><br>
<a href="plugins/jira-sdlc/docs/TASK-LIFECYCLE-PHASE-1.md"><img src="plugins/jira-sdlc/docs/assets/task-lifecycle-phase-1.svg" alt="Phase 1 (Plan) sequence diagram" width="260"></a>
</td>
<td align="center" valign="top" width="33%">
<strong>Phase 2 · Implement</strong><br>
<code>jira-task-executor</code><br>
<a href="plugins/jira-sdlc/docs/TASK-LIFECYCLE-PHASE-2.md">Full diagram &amp; notes →</a><br><br>
<a href="plugins/jira-sdlc/docs/TASK-LIFECYCLE-PHASE-2.md"><img src="plugins/jira-sdlc/docs/assets/task-lifecycle-phase-2.svg" alt="Phase 2 (Implement) sequence diagram" width="260"></a>
</td>
<td align="center" valign="top" width="33%">
<strong>Phase 3 · Review &amp; aggregate approval</strong><br>
<code>jira-task-reviewer</code><br>
<a href="plugins/jira-sdlc/docs/TASK-LIFECYCLE-PHASE-3.md">Full diagram &amp; notes →</a><br><br>
<a href="plugins/jira-sdlc/docs/TASK-LIFECYCLE-PHASE-3.md"><img src="plugins/jira-sdlc/docs/assets/task-lifecycle-phase-3-single-step.svg" alt="Phase 3 (Review) sequence diagram" width="260"></a>
</td>
</tr>
</table>

See **[Task lifecycle](plugins/jira-sdlc/docs/TASK-LIFECYCLE.md)** for the
full phase-by-phase breakdown (skills, Jira states, and per-phase steps).

## Install

In a hurry? **[Step by step](plugins/jira-sdlc/docs/STEP-BY-STEP.md)** is the
short, ordered walkthrough — tools, tokens, settings, and a healthcheck, in
the order you actually do them.

### Prerequisites

Three CLIs must be installed and authenticated on your machine first.

**Install tools**

| Tool   | Title           | Uses                       | Install URL                                                              | Auth method | Token link                                                                        | Local docs                                                                          |
| ------ | --------------- | -------------------------- | ----------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `git`  | Version control | commit/push                | [git-scm.com/downloads](https://git-scm.com/downloads)                  | global auth | —                                                                                 | —                                                                                   |
| `gh`   | GitHub CLI      | pr create/update           | [cli.github.com](https://cli.github.com/)                               | token       | [GitHub fine-grained PAT](https://github.com/settings/personal-access-tokens/new) | [GH-PAT-SESSION-LOGIN.md](plugins/jira-sdlc/docs/github/GH-PAT-SESSION-LOGIN.md)     |
| `acli` | Atlassian CLI   | jira api (issues, comments)| [install acli](https://developer.atlassian.com/cloud/acli/guides/install-acli/) | token       | [Jira API token](https://id.atlassian.com/manage-profile/security/api-tokens)     | [JIRA-ACLI.md](plugins/jira-sdlc/docs/JIRA-ACLI.md)                                  |

`git` uses your machine's existing global credentials. `gh` authenticates
with a GitHub PAT (`GITHUB_PAT_TOKEN`) and `acli` with a Jira API token
(`JIRA_TOKEN`) — both set per repo in `jira-sdlc-tools.local.env` (see
[Either way](#either-way) below).

**Helper tools**

The skills run bundled scripts that need a shell runtime plus a JSON parser —
which ones depend on your OS.

**Windows** — one of:

| Tool         | Uses                                            | Install URL                                                                                              |
| ------------ | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `pwsh`       | run skill scripts (`win/*.ps1`), PowerShell 7+  | [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) |
| `powershell` | run skill scripts (`win/*.ps1`), PowerShell 5.1 | ships with Windows                                                                                       |

**Linux / macOS:** the scripts are bash, which has no native JSON parsing, so
they shell out to an external tool for it:

| Tool      | Uses                                 | Install URL                                                 |
| --------- | ------------------------------------ | ---------------------------------------------------------- |
| `jq`      | parse Jira JSON                      | [jqlang.github.io/jq](https://jqlang.github.io/jq/download/) |
| `python3` | scripting (`jq` fallback for JSON)   | [python.org/downloads](https://www.python.org/downloads/)  |

### Remote — from the marketplace (recommended)

```
/plugin marketplace add kantorv/jira-sdlc-tools
/plugin install jira-sdlc@jira-sdlc-tools
```

### Local — clone, then load with `--plugin-dir`

```bash
git clone https://github.com/kantorv/jira-sdlc-tools.git
claude --plugin-dir ./jira-sdlc-tools/plugins/jira-sdlc
```

No marketplace step and nothing gets installed — this loads the plugin
directly from your local clone for that Claude Code session. Point
`--plugin-dir` at the plugin's own root (`plugins/jira-sdlc`), not the
toolkit repo root — the toolkit root only holds `marketplace.json`,
not a `plugin.json`. Useful if you'd rather track updates via `git pull`
than a marketplace, or if you're testing a change before publishing it.
If you're planning to actively edit the plugin rather than just run it,
see [Development](#development) below for the edit-reload loop.

### Either way

Create two files in the root of the repo you're building features in:

1. **`jira-sdlc-tools.env`** — team-shared settings (project key, status names, default branch). A filled-in template ships at [`jira-sdlc-tools.env`](jira-sdlc-tools.env) in this repo's root; copy it over and fill in the blanks.
2. **`jira-sdlc-tools.local.env`** — developer/machine-specific settings (worktrees path, Jira URL, email, token path). This file is **gitignored**; each developer creates their own copy. See [`jira-sdlc-tools.local.env.example`](jira-sdlc-tools.local.env.example) for the template.

The plugin README explains what each value means. Then you're ready to run `/jira-sdlc:jira-task-assigner`.

## Repository layout

```
jira-sdlc-tools/
├── .claude-plugin/
│   └── marketplace.json        # lists every plugin this repo offers
├── plugins/
│   └── jira-sdlc/              # the plugin itself
│       ├── .claude-plugin/
│       │   └── plugin.json
│       ├── skills/
│       ├── docs/
│       ├── LICENSE
│       └── README.md           # full plugin documentation
├── jira-sdlc-tools.env         # template — team-shared settings (committed)
├── jira-sdlc-tools.local.env.example  # template — machine-specific settings (gitignored)
├── AGENTS.md                   # repo-wide instructions for AI coding agents
├── CLAUDE.md                   # imports AGENTS.md + Claude Code–specific notes
├── LICENSE
└── README.md                   # this file
```

It's split into a marketplace layer (this level) and a plugin layer
(`plugins/jira-sdlc/`) so the marketplace can grow to host more
Jira/SDLC-related plugins later without another reorganization — right
now there's just the one.

## Development

Editing a skill needs a tighter loop than a marketplace install gives
you: Claude Code copies a plugin snapshot into its cache at install
time, so changes to your clone won't show up in an installed copy until
you reinstall.

1. **Clone the repo:**
   ```bash
   git clone https://github.com/kantorv/jira-sdlc-tools.git
   cd jira-sdlc-tools
   ```

2. **Load it manually**, pointing at the plugin's own root — not the
   toolkit repo root, which only holds `marketplace.json`:
   ```bash
   claude --plugin-dir ./plugins/jira-sdlc
   ```
   No install step, no marketplace. If `jira-sdlc` is already installed
   from a marketplace elsewhere on the same machine, `--plugin-dir`
   takes precedence for that session, so you're never testing against a
   stale cached copy without realizing it.

3. **After each edit, reload instead of restarting:**
   ```
   /reload-plugins
   ```
   Picks up changes to skills, agents, hooks, and MCP/LSP servers
   without a full session restart.

There's no build or test suite to run — these are prompt files for an
LLM agent plus two JSON manifests, not compiled code. See
[`AGENTS.md`](AGENTS.md) for what actually counts as validating a
change. Note too that this toolkit repo isn't a valid target for its
own skills — you'll need a separate application repo, with its own
`jira-sdlc-tools.env`, to actually exercise one against.

### Run your own

For anyone who wants to customize the skills and run their own version
rather than track this one.

This repo is [MIT-licensed](LICENSE) and is already a ready-to-use Claude
Code marketplace — it's only a few clicks from being cloned or forked into
your own copy, then registered as a marketplace in your local Claude Code.
Fork or clone it, edit the skills to taste, and install from your local
folder:

1. **Fork it on GitHub** (if you want your own upstream to push to), then
   clone your copy:
   ```bash
   git clone https://github.com/<you>/jira-sdlc-tools.git
   ```
2. **Add the local folder as a marketplace**, pointing at the repo root
   (the directory holding `.claude-plugin/marketplace.json`):
   ```
   /plugin marketplace add ./jira-sdlc-tools
   /plugin install jira-sdlc@jira-sdlc-tools
   ```
   From here it behaves like the remote install — your fork is the source.
   While actively editing, use the `--plugin-dir` edit-reload loop above
   instead, since a marketplace install copies a snapshot into the cache.

## Contributing

Read [`AGENTS.md`](AGENTS.md) first, especially if an AI coding agent is
doing the work — it covers the constraints that are easy to break
without realizing it (the `_shared/` reference-path relationship, what
else to update if you rename a skill or the plugin, how to validate a
change with no test suite to run).

## Trademarks

Jira and Atlassian are trademarks or registered trademarks of Atlassian
Pty Ltd, in the United States and/or other countries. This is an
independent, community-built project that integrates with Jira through
its public CLI and APIs; it is not affiliated with, endorsed by, or
sponsored by Atlassian, and its references to Jira are solely to
describe compatibility.

## License

[MIT](LICENSE), covering the whole repo, including the plugin.

## Lab channel

Everything above describes the **main** channel — this repo's default
branch, and what every install command on this page gives you: the three
core skills, reviewed, released, and tagged.

The **lab** channel is the same plugin sourced from the `lab` branch
instead. It's kept synced with the default branch, so it's never *behind*
main — it's main plus work that hasn't landed yet: more advanced scripts,
wider permissions, and two extra skills.

- **`jira-task-helper`** — the around-the-task plumbing the core three
  leave out: a cross-worktree `status` dashboard, `cleanup` of worktrees
  whose work is already merged, `dump_changes`, `sync_conversations`, and
  `setup`.
- **`conversation-debugger`** — post-mortems a recorded run of one of the
  three core skills against its own prose, verdicting each instruction as
  followed / diverged / skipped / not-reached.

To install it, suffix the marketplace repo with `@lab`:

```
/plugin marketplace add kantorv/jira-sdlc-tools@lab
/plugin install jira-sdlc@jira-sdlc-tools
```

Worth knowing before you switch: the extras aren't release-gated, and they
reach wider than the core three do — into your whole workspace rather than
a single issue's worktree, with the scripts and permissions to match.

See [**LAB-CHANNEL.md**](https://github.com/kantorv/jira-sdlc-tools/blob/lab/LAB-CHANNEL.md)
on the lab branch for the full description, both install routes, and the
lab-only configuration step.