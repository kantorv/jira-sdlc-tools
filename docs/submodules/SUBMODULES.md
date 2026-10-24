---
slug: /submodules
sidebar_position: 1
sidebar_label: Overview
---

# Submodules — projects whose repos are git submodules of a workspace

Some projects aren't one repository. A **workspace** repo holds a few **member** repos as git submodules: an app and
its server, say, each with its own GitHub repo. The jira-sdlc skills handle that layout. One Jira issue can change
several members, each member gets its own branch and PR, and the workspace records the result once they've all merged.

A project without submodules, or with submodules that are only vendored libraries, is unaffected. Nothing changes
until you list members.

## How one issue flows

```text
assigner  → the issue, plus the issue branch in the workspace and in every member it touches
executor  → one commit and one PR per member it changed (each PR lists the whole set)
reviewer  → reviews each member PR, checks the interfaces between them, states the merge order
you       → merge the member PRs, in that order
reviewer  → "lands" them: one workspace PR moving each member's pointer to its merged commit
you       → merge the landing PR — the issue is done
```

The branch name is the same everywhere: `feature/PROJ-42-…` in the app and in the server are one issue's two halves.
The commands are the usual ones, with no extra arguments: `/jira-sdlc:jira-task-assigner <task>` from the
workspace's main checkout, then `/jira-sdlc:jira-task-executor` and `/jira-sdlc:jira-task-reviewer` from the issue's
worktree.

## In this section

| Page | Read it when |
| -- | -- |
| [Setup](./setup.md) | You're turning a project with submodules into one the skills work across |
| [How the skills work](./how-the-skills-work.md) | You want to know what each skill does with members, step by step, and what you're expected to do |
| [Design and rules](./design.md) | You're changing the skills or scripts, or want the *why* behind a rule |
| [`repos.sh` reference](./repos-sh.md) | You're an agent or contributor reading or calling the script |
| [Troubleshooting](./troubleshooting.md) | A healthcheck row fails, a run stops, or something looks odd |
| [Other multi-repo layouts](./other-layouts.md) | Your project's repos aren't submodules (git-ignored clones, a monorepo, a manifest) |
| [History: choosing submodules](./history.md) | You want to know how the layouts were weighed and why submodules came first |

## What works, and what doesn't yet

| Works | Doesn't yet |
| -- | -- |
| Single-step, planned issues that change any members, the workspace, or both | **Multistep** issues (Jira sub-tasks) across members: the assigner, executor and reviewer stop with a clear message |
| Any merge method on member PRs (squash, rebase, merge commit) | **Hotfixes** across members: each member's production branch isn't modelled yet |
| Issues that touch only the workspace, multistep and hotfix included | Workspaces whose members are **git-ignored clones**, not submodules ([Other layouts](./other-layouts.md)) |
| Single-repo projects, exactly as before | A run on **real Windows** (the PowerShell port is tested under PowerShell on Linux) |

All of it was proven on a demo workspace with two members (an app and its server): a cross-repo issue went from a
plain task description through all three skills to a landed, merged change. Details are in
[Design and rules](./design.md#how-it-was-validated).
