---
slug: /step-by-step
sidebar_position: 2
---

# Step by step

## How it works

Detailed setup lives in [INSTALLATION.md](INSTALLATION.md) — this page is the
short, ordered version.

Would rather be walked through it? `/jira-sdlc:jst-install`
([`SKILL.md`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jst-install/SKILL.md)) follows these same four
sections, in this order, and verifies each one with the Section 4 healthcheck
before moving to the next.

## Section 1. Preparing environment

1. **Install the required tools** — `git` and `gh`. There is nothing to
   install for Jira: the skills drive it over the REST API through their own
   client, `jira.sh` / `jira.ps1`, which ships with the plugin. On Linux and
   macOS that client needs `curl` and `jq` on your `PATH`; the Windows
   PowerShell port uses built-in cmdlets and needs neither.
2. **Have a git repository and a Jira account with a board created.**
   [GitHub for Jira](INSTALLING-GITHUB-FOR-JIRA.md) is a great, recommended
   integration — but it is **not** required.
3. **Generate your tokens:** a **granular** `GITHUB_PAT`, and a **classic**
   Jira API token for each of the three roles — assigner, executor, reviewer
   (see the note in [SECURITY.md](SECURITY.md) on why the Jira tokens must be
   classic).
4. **Define your main repository and worktrees dir in the settings** — an
   absolute path, never a relative one:
   ```
   WORKTREES_DIR=/home/you/src/myapp-worktrees
   ```

### Verify your tokens

**Jira** — there is no login step. The client sends your email and token as
Basic auth on each request, so "verifying" is just making one authenticated
call. `_edge/tenant_info` is unauthenticated and gives you the cloud id;
`/myself` is the part that proves the token:

```bash
CLOUD_ID=$(curl -fsSL "https://$JIRA_ACCOUNT_URL/_edge/tenant_info" | jq -r .cloudId)
curl -sS -u "$JIRA_EXECUTOR_EMAIL:$JIRA_EXECUTOR_TOKEN" -H "Accept: application/json" \
  "https://api.atlassian.com/ex/jira/$CLOUD_ID/rest/api/3/myself" | jq -r .emailAddress
```

Getting your own email back means the pair works. The Section 4 healthcheck
makes the same call, so you can also just skip ahead to it.

**GitHub** — log `gh` in with your PAT:

```bash
echo "$GITHUB_PAT_TOKEN" | gh auth login --with-token && gh auth status
```

### Your settings should look like this

```
WORKTREES_DIR=/path/to/worktrees/PROJ-worktrees

JIRA_ACCOUNT_URL=your-jira-site.atlassian.net

# Required — one Jira account per role, so the board shows who did what.
# All six values, no default pair behind them; point all three at the same
# Atlassian account if you'd rather not split them.
JIRA_ASSIGNER_EMAIL=assigner@example.com
JIRA_ASSIGNER_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX
JIRA_EXECUTOR_EMAIL=executor@example.com
JIRA_EXECUTOR_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX
JIRA_REVIEWER_EMAIL=reviewer@example.com
JIRA_REVIEWER_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX

GITHUB_PAT_TOKEN="XXXXXXXXXXXXX"
```

Each `JIRA_<ROLE>_TOKEN` is the token **value**, not a path to a file holding
it. Every variable above is described in
[plugins/jira-sdlc/skills/\_shared/project-config.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md).

## Section 2. GitHub repository preparation

### 2.1 The branching model

The skills are written against **Gitflow** — they don't invent branch names,
they follow the policy in [SDLC.md](SDLC.md). The five branches that matter:

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

### 2.2 Split production from base

Gitflow needs two **distinct** long-lived branches, and a single-branch repo
isn't a supported configuration: point `DEFAULT_BASE_BRANCH` and
`PRODUCTION_BRANCH` at the same branch and every feature PR targets production,
the assigner's hotfix path becomes indistinguishable from its planned one, and
the release workflows lose the branch name they key the version off ([SDLC.md
§5](SDLC.md)). The healthcheck's `branch_pair` row FAILs on it. The names are
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

### 2.3 Clone the base branch — this is the entry point

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

## Section 3. Jira board preparation

### 3.1 Create the board

Create a Jira project and its board. **This plugin was tested on a simple
Kanban board** — the default Kanban template, with its default columns, is
the known-good setup. Scrum boards and custom workflows should work provided
step 3.2 holds, but they aren't what was exercised.

### 3.2 Read the four statuses off your board

The skills move issues through four workflow statuses, and they match names
**literally** — `In progress` and `In Progress` are different statuses. So don't
type them from memory: ask your board what it actually has. Run these from your
skills folder (Section "Loading the skills" in the README says where that is on
your platform); the second one needs the key from the first:

```bash
# the projects this credential can see — key, name, type/style
bash _shared/scripts/posix/jira.sh --role executor raw GET /project/search \
  | jq -r '.values[] | "\(.key)\t\(.name)\t\(.projectTypeKey)/\(.style)"'
# the statuses your chosen project really has
bash _shared/scripts/posix/jira.sh --role executor raw GET /project/<KEY>/statuses \
  | jq -r '[.[].statuses[].name] | unique | .[]'
```

```powershell
pwsh -File _shared\scripts\win\jira.ps1 --role executor raw GET /project/search
pwsh -File _shared\scripts\win\jira.ps1 --role executor raw GET /project/<KEY>/statuses
```

Then map each setting onto a name from that list:

| Setting | Default Kanban name | Who sets it |
| -- | -- | -- |
| `STATUS_TODO` | `To Do` | no skill does — it names the status new issues land in, and it's the only status the optional branch-create Action advances *from* |
| `STATUS_IN_PROGRESS` | `In Progress` | `jira-task-executor`, when it starts work |
| `STATUS_IN_REVIEW` | `In Review` | `jira-task-executor`, when its PR opens |
| `STATUS_DONE` | `Done` | `jira-task-reviewer` step 7, but only for approved issues and only if you say yes — otherwise GitHub-for-Jira automation on merge, or you, by hand |

Those defaults are the **Kanban template's** names, not a requirement — treat
them as a hint for which real status to pick, not as the answer. Boards
routinely differ: `In Review` is missing from several Jira templates, and a
board with `Backlog` / `Selected for Development` instead of `To Do` is normal
too. Where two of your statuses could fit, pick by consequence — `STATUS_TODO`
should be the status your new issues actually land in, since that's where work
is picked up from.

To prove the names *and* the workflow rather than assume either, spend one
scratch issue: create it, walk it through your four configured names, delete it,
and confirm the delete came back 404. `/jira-sdlc:jst-install` §3d does exactly
that (after asking), and a wrong name or a transition your workflow forbids
surfaces there, at setup, instead of mid-run.

### 3.3 Record the project key and statuses

Put all five in `.jst/jira-sdlc-tools.env` (the shared/team file — the tokens
and paths from Section 1 live in `.jst/jira-sdlc-tools.local.env` instead):

```
PROJECT_KEY=PROJ
STATUS_TODO=To Do
STATUS_IN_PROGRESS=In Progress
STATUS_IN_REVIEW=In Review
STATUS_DONE=Done
```

That block is the shape, not the values — substitute the key and the four names
3.2 turned up on your own board. `PROJECT_KEY` is the prefix in your issue
keys — `PROJ` in `PROJ-278` — and the skills match branch names against it, so
a wrong one is caught rather than worked.

## Section 4. Run the healthcheck

From your **main repository**, run the statuscheck script — it confirms both
logins, your settings, and the platform in one pass:

**Linux / macOS** (bash) — read it first:
[`statuscheck.sh`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/scripts/posix/statuscheck.sh)

```bash
curl -fsSL "https://raw.githubusercontent.com/kantorv/jira-sdlc-tools/main/plugins/jira-sdlc/skills/_shared/scripts/posix/statuscheck.sh" -o statuscheck.sh
bash statuscheck.sh --role executor   # --role is required: assigner|executor|reviewer
```

**Windows** (PowerShell 7+ `pwsh`, or 5.1 `powershell`) — read it first:
[`statuscheck.ps1`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/scripts/win/statuscheck.ps1)

```powershell
iwr -UseBasicParsing "https://raw.githubusercontent.com/kantorv/jira-sdlc-tools/main/plugins/jira-sdlc/skills/_shared/scripts/win/statuscheck.ps1" -OutFile statuscheck.ps1
# --role is required: assigner|executor|reviewer
pwsh -File statuscheck.ps1 --role executor        # PowerShell 7+
powershell -File statuscheck.ps1 --role executor  # PowerShell 5.1
```

### What's still uncommitted — and the first task

A green healthcheck doesn't mean the config is in git. The whole `.jst/` folder
is still untracked — `jira-sdlc-tools.env` (Section 3.3, team-shared and meant
to be committed) and the `.gitignore` beside it. Leave it and the first worktree
`jira-task-assigner` cuts is born without `.jst/` at all, so the first executor
run fails statuscheck's `env_config` row there. Copy the folder **whole** when
you populate that worktree: the `.gitignore` inside it is what keeps
`jira-sdlc-tools.local.env` and its four credentials out of the commit, and
staging `.jst/` explicitly beats `git add -A` either way.

Commit it by hand, or — recommended — make it this project's first task, so the
fix doubles as an end-to-end smoke test of all three skills.
[`/jira-sdlc:jst-install`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jst-install/SKILL.md) §4d closes with a
ready-to-paste prompt for that: the assigner creates a retroactive
**JIRA-SDLC-TOOLS setup** issue and copies `.jst/` into its worktree, the
executor commits and pushes it, and the reviewer confirms the settings work.
