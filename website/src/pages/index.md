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

- **[Installation](/docs/installation)** — install the plugin from its
  marketplace and point it at your project.
- **[Step by step](/docs/step-by-step)** — one feature all the way through, from
  request to merged pull request.
- **[Full setup checklist](/docs/full-setup-checklist)** — every credential,
  settings file and Jira/GitHub prerequisite in one list.
- **[Task lifecycle](/docs/task-lifecycle)** — what the three skills do to an
  issue, and where a human still decides.

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
[full setup checklist](/docs/full-setup-checklist) before the first run, and
point it at a project you are comfortable having changed.

Source, issues and releases live on
[GitHub](https://github.com/kantorv/jira-sdlc-tools).
