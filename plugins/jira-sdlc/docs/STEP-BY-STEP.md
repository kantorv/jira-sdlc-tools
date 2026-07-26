# Step by step

## How it works

Detailed setup lives in [INSTALLATION.md](INSTALLATION.md) — this page is the
short, ordered version.

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
4. **Define your main repository and worktrees dir in the settings**, e.g.:
   ```
   WORKTREES_DIR=/home/lalala/src/skills-dev/JST-worktrees
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
[../skills/_shared/project-config.md](../skills/_shared/project-config.md).

## Section 2. GitHub repository preparation

### 2.1 The branching model

The skills are written against **Gitflow** — they don't invent branch names,
they follow the policy in [SDLC.md](SDLC.md). The five branches that matter:

| Branch | Source | Merges to | Purpose |
|---|---|---|---|
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

Gitflow needs two long-lived branches. If your repo only has `main`, create
the base branch off it once:

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

**`jira-task-assigner` runs only from the base branch.** Invoked from a
feature or hotfix branch, it stops and tells you to switch back — it plans
work *from* the base branch, then hands each issue its own branch and
worktree. So the clone you work in should sit on `development`:

```bash
git clone -b development git@github.com:<OWNER>/<REPO>.git myapp
cd myapp
```

The worktrees directory is a **sibling** of that clone, and must already
exist — the assigner refuses to create it:

```bash
mkdir -p ../myapp-worktrees
```

Then point `WORKTREES_DIR` at it in `.jst/jira-sdlc-tools.local.env`. From here
on, the loop is: run the assigner in this clone, then run the executor from
inside each issue's worktree.

## Section 3. Jira board preparation

### 3.1 Create the board

Create a Jira project and its board. **This plugin was tested on a simple
Kanban board** — the default Kanban template, with its default columns, is
the known-good setup. Scrum boards and custom workflows should work provided
step 3.2 holds, but they aren't what was exercised.

### 3.2 Confirm the four statuses exist

The skills move issues through four workflow statuses. Open your board's
column/workflow settings and confirm each one exists, then copy the names
**exactly** as Jira spells them — matching is literal, so `In progress` and
`In Progress` are different statuses:

| Setting | Default Kanban name | Who sets it |
|---|---|---|
| `STATUS_TODO` | `To Do` | `jira-task-assigner`, on newly created issues |
| `STATUS_IN_PROGRESS` | `In Progress` | `jira-task-executor`, when it starts work |
| `STATUS_IN_REVIEW` | `In Review` | `jira-task-executor`, when its PR opens |
| `STATUS_DONE` | `Done` | `jira-task-reviewer` step 7, but only for approved issues and only if you say yes — otherwise GitHub-for-Jira automation on merge, or you, by hand |

`In Review` is the one most likely to be missing: several Jira templates ship
`To Do` / `In Progress` / `Done` only. Add the column, or point the setting at
whatever your workflow calls that stage.

To prove a name is right rather than assume it, transition a throwaway issue
with the plugin's own Jira client. Run it from your skills folder (Section
"Loading the skills" in the README says where that is on your platform):

```bash
bash _shared/scripts/posix/jira.sh issue transition <KEY> --to "In Review"
```
```powershell
pwsh -File _shared\scripts\win\jira.ps1 issue transition <KEY> --to "In Review"
```

A wrong name fails here, at setup, instead of mid-run.

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

`PROJECT_KEY` is the prefix in your issue keys — `PROJ` in `PROJ-278`.

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

