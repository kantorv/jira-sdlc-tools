---
slug: /step-by-step-installation/project-key-and-four-statuses
sidebar_position: 2
sidebar_label: Project key and four statuses
---

# Project key and four statuses

The skills move issues through four workflow statuses, and they match names
**literally** — `In progress` and `In Progress` are different statuses.

Create or choose the Jira board, then identify the project's key and the four
real workflow status names. When the project list is returned, choose the project
explicitly; do not silently pick one just because its name resembles the
repository.

- `STATUS_TODO`
- `STATUS_IN_PROGRESS`
- `STATUS_IN_REVIEW`
- `STATUS_DONE`

The default Kanban names are a useful reference:

| Setting | Default Kanban name | Who sets it |
| -- | -- | -- |
| `STATUS_TODO` | `To Do` | no skill does — it names the status new issues land in, and it's the only status the optional branch-create Action advances *from* |
| `STATUS_IN_PROGRESS` | `In Progress` | `jira-task-executor`, when it starts work |
| `STATUS_IN_REVIEW` | `In Review` | `jira-task-executor`, when its PR opens |
| `STATUS_DONE` | `Done` | `jira-task-reviewer` step 7, but only for approved issues and only if you say yes — otherwise GitHub-for-Jira automation on merge, or you, by hand |

Those defaults are the **Kanban template's** names, not a requirement. Boards
can differ: `In Review` is missing from several Jira templates, and a board
with `Backlog` / `Selected for Development` instead of `To Do` is normal too.
