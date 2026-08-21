---
slug: /github-repository-preparation
sidebar_position: 3
sidebar_label: 2. GitHub repository preparation
---

# Section 2. GitHub repository preparation

## 2.1 The branching model

The skills are written against **Gitflow** — they don't invent branch names,
they follow the policy in [SDLC.md](../process/SDLC.md). The five branches that matter:

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

## 2.2 Split production from base

Gitflow needs two **distinct** long-lived branches, and a single-branch repo
isn't a supported configuration: point `DEFAULT_BASE_BRANCH` and
`PRODUCTION_BRANCH` at the same branch and every feature PR targets production,
the assigner's hotfix path becomes indistinguishable from its planned one, and
the release workflows lose the branch name they key the version off ([SDLC.md
§5](../process/SDLC.md)). The healthcheck's `branch_pair` row FAILs on it. The names are
yours — `master`/`develop` or anything else works — but there have to be two.

If your repo only has `main`, create the base branch off it once:

```bash
git switch main
git switch -c development
git push -u origin development
```

Make `development` the repository default so PRs target it automatically:

```bash
gh repo edit <OWNER>/<REPO> --default-branch development
```

Then record both in `.jst/jira-sdlc-tools.env` — the skills read these, never a
hardcoded branch name:

```
DEFAULT_BASE_BRANCH=development
PRODUCTION_BRANCH=main
```

Protecting both branches is recommended: everything reaches them through a
reviewed PR, which is exactly the flow the skills produce.

## 2.3 Clone the base branch — this is the entry point

**`jira-task-assigner` runs from a long-lived branch, not an issue branch.**
Invoked from a feature or hotfix branch, it stops and tells you to switch
back — it plans work *from* a long-lived branch, then hands each issue its own
branch and worktree. Normally that's the base branch, so the clone you work in
should sit on `development` (`main` is accepted too, but only when you're
asking for an emergency hotfix — and even then it isn't required, since the
hotfix is cut from `origin/main` regardless):

```bash
git clone -b development git@github.com:<OWNER>/<REPO>.git myapp
cd myapp
```

The worktrees directory is a **sibling** of that clone, and must already
exist — the assigner refuses to create it:

```bash
mkdir -p ../myapp-worktrees
cd ../myapp-worktrees && pwd   # the absolute path to paste below
```

Then point `WORKTREES_DIR` at it in `.jst/jira-sdlc-tools.local.env`, **as an
absolute path** — `/home/you/src/myapp-worktrees`, not `../myapp-worktrees`.
A relative value resolves against a different base from inside a worktree than
from this clone, so the healthcheck FAILs on one. From here
on, the loop is: run the assigner in this clone, then run the executor from
inside each issue's worktree.

Next: [Section 3. Jira board preparation](JIRA-BOARD-PREPARATION.md).
