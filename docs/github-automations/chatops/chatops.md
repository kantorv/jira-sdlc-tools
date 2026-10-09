---
slug: /github-automations/chatops
sidebar_position: 1
sidebar_label: Overview
---

# ChatOps

Workflows in this subfolder are triggered by a **comment** on a GitHub PR or
issue — the command is the first token of the comment body, and every
comment-triggered demo also accepts free-form prose after the command (see
[GITHUB-AUTOMATIONS.md — the trigger comment can carry prose](../GITHUB-AUTOMATIONS.md#2c-the-same-demos-by-scenario)).
Every one of them is gated by the OWNER-only author check described in
[GITHUB-AUTOMATIONS.md §3.2](../GITHUB-AUTOMATIONS.md#32-rule-2-owner-only-author-gate--cheap-precheck-before-the-environment-gate).

| Subfolder | Command | What it does |
| -- | -- | -- |
| [`/review` command](review/ci-review-pr-demo.md) | `/review` (or `/fcc-review`) | Runs `jira-task-reviewer` alone against an already-open PR. |
| [Issue to task / bug](issue-to-task/ci-issue-to-task-demo.md) | `/make-task` / `/make-bug` | Runs `jira-task-assigner` alone, turning the commented issue into a Jira Task or Bug plus its branch and worktree. Stops there — no implementation, no PR. |

Both are single-skill flows — no chained jobs, no multi-stage approval. For
the full chained assigner → executor → reviewer flow, see
[Autopilot mode](../autopilot/autopilot.md) instead, which is also
comment-triggered but is grouped separately because it fans out into three
jobs rather than one.
