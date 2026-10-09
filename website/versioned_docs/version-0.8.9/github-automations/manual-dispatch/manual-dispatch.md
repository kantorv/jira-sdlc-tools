---
slug: /github-automations/manual-dispatch
sidebar_position: 1
sidebar_label: Overview
---

# Manual review (workflow dispatch)

This workflow runs from the **Actions tab** (`workflow_dispatch`), not from a
PR/issue comment. It carries **no author gate and no environment gate**: only
users with write access can dispatch a workflow at all, and an owner-only
`github.triggering_actor == github.repository_owner` check never matches on an
org-owned repo, where the owner is the org rather than a person (see
[GITHUB-AUTOMATIONS.md §3.1](../GITHUB-AUTOMATIONS.md#31-the-author-gate--a-cheap-precheck-before-any-assistant-job)).
Like every example workflow, it reads **repository secrets**.

| Workflow file | What it does | Deep dive |
| -- | -- | -- |
| [`demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml`](../example-workflows/demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml) | Runs `jira-task-reviewer` against an already-open PR, same as the `/review` chatops command, but with no comment trigger and the NIM model picked from the dispatch dropdown instead of pinned. | [ChatOps → `/review` command](../chatops/review/ci-review-pr-demo.md) covers the reviewer mechanics this workflow shares with `demo-claude-reviewer.yml` and `demo-fcc-nvidia-nim-reviewer.yml`; the only difference is the trigger and the model picker. |

Grouped as its own category because its trigger mechanism (a human picking a
run from the Actions tab, not a comment) sets it apart from the chatops
demos, even though it runs the same skill.
