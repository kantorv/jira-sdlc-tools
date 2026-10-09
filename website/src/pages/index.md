---
title: jira-sdlc-tools
description: An SDLC layer for AI coding assistants — the Jira API, the Gitflow model, and git worktrees as isolated per-issue workspaces.
hide_table_of_contents: true
---

# jira-sdlc-tools

An SDLC layer for AI coding assistants — the Jira API, the Gitflow model, and
git worktrees as isolated per-issue workspaces.

Shipped as a Claude Code plugin (installable from its own marketplace) and as a
loose skill set for coding-assistant platforms that respect the Claude or
[agentskills.io](https://agentskills.io) specifications. The skills are
explicit-invocation only by design — never auto-triggered.

## Start here

- **[Step-by-step installation](/docs/step-by-step-installation)** — install
  the plugin from its marketplace, point it at your project, and take one
  feature all the way through, from request to merged pull request.
- **[Full setup checklist](/docs/step-by-step-installation/full-setup-checklist)** — every credential,
  settings file and Jira/GitHub prerequisite in one list.
- **[Task lifecycle](/docs/task-lifecycle)** — what the three skills do to an
  issue, and where a human still decides.

## Installation map

The whole step-by-step installation at a glance — every entry is a link.

<!-- doc-tree: STEP-BY-STEP-INSTALLATION -->

<div class="doc-tree">

[Step-by-step installation](/docs/step-by-step-installation)\
├── [Environment setup](/docs/step-by-step-installation/environment-setup)\
│   ├── [Software](/docs/step-by-step-installation/software)\
│   ├── [GitHub](/docs/step-by-step-installation/github)\
│   │   ├── [Account and Repository](/docs/step-by-step-installation/account-and-repository)\
│   │   ├── [Authentication](/docs/step-by-step-installation/github-authentication)\
│   │   │   ├── [git](/docs/step-by-step-installation/git-authentication)\
│   │   │   │   ├── [Credentials manager](/docs/step-by-step-installation/credentials-manager)\
│   │   │   │   └── [SSH key](/docs/step-by-step-installation/ssh-key)\
│   │   │   └── [gh](/docs/step-by-step-installation/gh-authentication)\
│   │   │       ├── [PAT](/docs/step-by-step-installation/pat)\
│   │   │       └── [gh auth login](/docs/step-by-step-installation/gh-auth-login)\
│   │   ├── [Post install](/docs/step-by-step-installation/github-post-install)\
│   │   │   └── [Optional: git branch in prompt](/docs/step-by-step-installation/add-git-branch-to-prompt)\
│   │   ├── [Verify GitHub authentication](/docs/step-by-step-installation/verify-github-authentication)\
│   │   ├── [Repository branching model](/docs/step-by-step-installation/repository-branching-model)\
│   │   ├── [Split production from base](/docs/step-by-step-installation/split-production-from-base)\
│   │   ├── [Verify GitHub access](/docs/step-by-step-installation/verify-github-access)\
│   │   ├── [Clone the base branch](/docs/step-by-step-installation/clone-the-base-branch)\
│   │   ├── [Verify the project repository](/docs/step-by-step-installation/verify-the-project-repository)\
│   │   └── [GitHub setup gate](/docs/step-by-step-installation/github-setup-gate)\
│   └── [Jira](/docs/step-by-step-installation/jira)\
│       ├── [Account, project, and board](/docs/step-by-step-installation/jira-account-project-and-board)\
│       ├── [Project key and four statuses](/docs/step-by-step-installation/project-key-and-four-statuses)\
│       ├── [Read the project key and statuses from Jira](/docs/step-by-step-installation/read-the-project-key-and-statuses)\
│       ├── [Jira users](/docs/step-by-step-installation/jira-users)\
│       ├── [Jira tokens](/docs/step-by-step-installation/jira-tokens)\
│       ├── [Verify Jira authentication](/docs/step-by-step-installation/verify-jira-authentication)\
│       ├── [Record the Jira settings](/docs/step-by-step-installation/record-the-jira-settings)\
│       ├── [Prove the Jira workflow](/docs/step-by-step-installation/prove-the-jira-workflow)\
│       └── [Jira setup gate](/docs/step-by-step-installation/jira-setup-gate)\
├── [Configuration](/docs/step-by-step-installation/configuration)\
│   ├── [Create the .jst/ scaffold](/docs/step-by-step-installation/create-the-jst-scaffold)\
│   └── [Fill .jst/jira-sdlc-tools.local.env](/docs/step-by-step-installation/fill-the-local-env)\
├── [Coding Assistant](/docs/step-by-step-installation/coding-assistant)\
│   ├── [Claude Code (extended)](/docs/integrations/claude-code)\
│   └── [Non Claude clients](/docs/step-by-step-installation/non-claude-clients)\
│       ├── [Codex](/docs/integrations/codex)\
│       ├── [Cursor](/docs/integrations/cursor)\
│       ├── [Antigravity](/docs/integrations/antigravity)\
│       ├── [Grok](/docs/integrations/grok)\
│       ├── [Kilo Code](/docs/integrations/kilo)\
│       ├── [Kimi Code](/docs/integrations/kimi-code)\
│       ├── [NVIDIA NIM](/docs/integrations/nvidia-nim)\
│       ├── [OpenCode](/docs/integrations/opencode)\
│       └── [Pi](/docs/integrations/pi)\
├── [Healthcheck](/docs/step-by-step-installation/healthcheck)\
├── [First tasks](/docs/step-by-step-installation/first-tasks)\
│   ├── [Commit the setup](/docs/step-by-step-installation/commit-the-setup)\
│   ├── [Add bootstrap and teardown scripts](/docs/step-by-step-installation/add-bootstrap-and-teardown-scripts)\
│   └── [Create a release cycle](/docs/step-by-step-installation/create-a-release-cycle)\
├── [Optional: parallel worktrees](/docs/step-by-step-installation/optional-parallel-worktrees)\
└── [Full setup checklist](/docs/step-by-step-installation/full-setup-checklist)

</div>
<!-- /doc-tree -->

## The four skills

| Skill | What it does |
| -- | -- |
| `jst-install` | Sets a project up for the other three. Run once. |
| `jira-task-assigner` | Turns a feature request into Jira issues, branches and per-issue worktrees. |
| `jira-task-executor` | Implements one issue end-to-end in its own worktree and opens its pull request. |
| `jira-task-reviewer` | Reviews the resulting pull requests and merges the set as a unit. |

## Caution

This plugin acts as an authenticated user in both git and Jira. Given
credentials, it will commit, push branches, open pull requests, and create,
transition and comment on issues. Read
[Security](/docs/security) and the
[full setup checklist](/docs/step-by-step-installation/full-setup-checklist) before the first run, and
point it at a project you are comfortable having changed.

Source, issues and releases live on
[GitHub](https://github.com/kantorv/jira-sdlc-tools).
