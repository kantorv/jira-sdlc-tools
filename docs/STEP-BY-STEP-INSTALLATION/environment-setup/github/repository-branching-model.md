---
slug: /step-by-step-installation/repository-branching-model
sidebar_position: 4
sidebar_label: Repository branching model
---

# Repository branching model

The skills are written against **Gitflow** — they follow the policy in
[SDLC.md](../../../process/SDLC.md). The five branches that matter:

| Branch | Source | Merges to | Purpose |
| -- | -- | -- | -- |
| `main` | `release/*`, `hotfix/*` | `development` | Production state, tagged `vX.Y.Z` |
| `development` | `main` | `release/*` | The **base branch** — where day-to-day work starts and lands |
| `feature/<KEY>-slug` | `development` | `development` | One per Jira issue, created by `jira-task-assigner` |
| `hotfix/<KEY>-slug` | `main` | `main` + `development` | Critical production fixes only |
| `release/sprint-<X.Y.Z>` | `development` | `main` | Sprint QA branch, cut at release time |

You only create the first two by hand. The skills create `feature/` and
`hotfix/` branches themselves, one per issue, each with its own worktree —
`feature/` by default, and `hotfix/` when you explicitly ask
`jira-task-assigner` for an emergency production fix.
