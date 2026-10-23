---
slug: /step-by-step-installation/fill-the-shared-env
sidebar_position: 2
sidebar_label: Fill .jst/jira-sdlc-tools.env
---

# Fill `.jst/jira-sdlc-tools.env`

`.jst/jira-sdlc-tools.env` is the team-shared half of the configuration: secret-free,
committed, and the same for every developer. If a teammate has already committed
it, there is nothing to do here — check the values and move on.

Otherwise create it with the values you settled during environment setup:

```text
# GITHUB SETTINGS (shared/team)
DEFAULT_BASE_BRANCH=development
PRODUCTION_BRANCH=main


# JIRA SETTINGS (shared/team)
PROJECT_KEY=PROJ
STATUS_TODO=To Do
STATUS_IN_PROGRESS=In Progress
STATUS_IN_REVIEW=In Review
STATUS_DONE=Done
```

| field | what it is | where the value comes from |
| -- | -- | -- |
| `DEFAULT_BASE_BRANCH` | The branch new top-level work is cut from and its PRs target. | [Split production from base](../environment-setup/github/split-production-from-base.md) |
| `PRODUCTION_BRANCH` | The production branch: hotfixes are cut from it and target it. Must differ from `DEFAULT_BASE_BRANCH`. | [Split production from base](../environment-setup/github/split-production-from-base.md) |
| `PROJECT_KEY` | The Jira project key — the prefix of every issue key (`PROJ-123`) and of the branch names the skills create. | [Read the project key and statuses from Jira](../environment-setup/jira/read-the-project-key-and-statuses.md) |
| `STATUS_TODO` | Status a newly created issue lands in. | [Project key and four statuses](../environment-setup/jira/project-key-and-four-statuses.md) |
| `STATUS_IN_PROGRESS` | Status `jira-task-executor` moves an issue to when it starts work. | same |
| `STATUS_IN_REVIEW` | Status an issue moves to once its PR is open. | same |
| `STATUS_DONE` | Final status, reached when the PR merges. | same |

Every value is your choice, not a fixed name: `main`/`development` and the four
statuses above are only the documented defaults. The status names must match
your Jira workflow **exactly**, including case — the skills transition by name.

Keep credentials out of this file; they belong in
[`.jst/jira-sdlc-tools.local.env`](./fill-the-local-env.md), which is never
committed. Every variable is described in
[project-config.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md).
