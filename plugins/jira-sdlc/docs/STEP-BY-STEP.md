# Step by step

## How it works

Detailed setup lives in [INSTALLATION.md](INSTALLATION.md) — this page is the
short, ordered version.

## Section 1. Preparing environment

1. **Install the required tools** — `acli`, `git`, `gh`. On Windows, make sure
   `acli` is on your `PATH`.
2. **Have a git repository and a Jira account with a board created.**
   [GitHub for Jira](INSTALLING-GITHUB-FOR-JIRA.md) is a great, recommended
   integration — but it is **not** required.
3. **Generate your tokens:** a **granular** `GITHUB_PAT` and a **classic**
   `JIRA_TOKEN` (see the note in [SECURITY.md](SECURITY.md) on why the Jira
   token must be classic).
4. **Define your main repository and worktrees dir in the settings**, e.g.:
   ```
   WORKTREES_DIR=/home/lalala/src/skills-dev/JST-worktrees
   ```

### Verify your tokens

**Jira** — log `acli` in with your token:
```bash
echo "$JIRA_TOKEN" | acli jira auth login \
  --site your-jira-site.atlassian.net \
  --email yourmail@gmail.com \
  --token
```

**GitHub** — log `gh` in with your PAT:
```bash
echo "$GITHUB_PAT_TOKEN" | gh auth login --with-token && gh auth status
```

### Your settings should look like this

```
WORKTREES_DIR=/path/to/worktrees/PROJ-worktrees

JIRA_ACCOUNT_URL=your-jira-site.atlassian.net
JIRA_ACCOUNT_EMAIL=yourmail@gmail.com
JIRA_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX

#  acli jira auth login --site coolapp-dev.atlassian.net --email kantorvv@gmail.com < .jira/token.txt

GITHUB_PAT_TOKEN="XXXXXXXXXXXXX"
```

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
`hotfix/` branches themselves, one per issue, each with its own worktree.

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

Then record both in `jira-sdlc-tools.env` — the skills read these, never a
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

Then point `WORKTREES_DIR` at it in `jira-sdlc-tools.local.env`. From here
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

To prove a name is right rather than assume it, transition a throwaway issue:

```bash
acli jira workitem transition --key <KEY> --status "In Review" --yes
```

A wrong name fails here, at setup, instead of mid-run.

### 3.3 Record the project key and statuses

Put all five in `jira-sdlc-tools.env` (the shared/team file — the tokens and
paths from Section 1 live in `jira-sdlc-tools.local.env` instead):

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
bash statuscheck.sh
```

**Windows** (PowerShell 7+ `pwsh`, or 5.1 `powershell`) — read it first:
[`statuscheck.ps1`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/scripts/win/statuscheck.ps1)
```powershell
iwr -UseBasicParsing "https://raw.githubusercontent.com/kantorv/jira-sdlc-tools/main/plugins/jira-sdlc/skills/_shared/scripts/win/statuscheck.ps1" -OutFile statuscheck.ps1
pwsh -File statuscheck.ps1        # PowerShell 7+
powershell -File statuscheck.ps1  # PowerShell 5.1
```

