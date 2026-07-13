# Project configuration reference

This file describes every variable used in `jira-sdlc-tools.env` and
`jira-sdlc-tools.local.env` (the `.env` files in the project root). All
project-specific values live in these two files — nothing else under `skills/`
should need editing after they're filled in.

Each skill's "Conventions used below" section names the tokens it needs
(e.g. `<PROJECT-KEY>`). Before following a skill's instructions, resolve
every token it references against **both** env files; the tables below
describe what each variable means.

## Two-file layout

| File | Purpose | Committed? |
|------|---------|------------|
| `jira-sdlc-tools.env` | Team-shared settings (project key, status names, default branch, semver labels). Same for every developer. | **Yes** — checked into the repo |
| `jira-sdlc-tools.local.env` | Developer/machine-specific settings (worktrees path, Jira URL, email, token path). Different per machine. | **No** — listed in `.gitignore` |

Both files are sourced by tools that need them. Values in
`jira-sdlc-tools.local.env` override those in `jira-sdlc-tools.env` if both
define the same variable (though they define disjoint sets by convention).

## Required (in `jira-sdlc-tools.env`)

| Token | What it is | Example |
|---|---|---|
| `<PROJECT-KEY>` | Your Jira project key. | `PROJ` |
| `<DEFAULT_BASE_BRANCH>` | The branch new top-level work starts from when there's no parent context yet. | `development` |
| `<PRODUCTION_BRANCH>` | The production branch that hotfixes branch from and target. | `main` |
| `<STATUS_TODO>` | Status used for newly created issues. | `To Do` |
| `<STATUS_IN_PROGRESS>` | Status the `jira_issue_transition_on_branch.yml` workflow moves an issue to when its branch is first pushed. No skill writes it — skills only read status; every transition is owned by the repo's `jira_issue_transition_*.yml` GitHub Actions workflows. | `In Progress` |
| `<STATUS_IN_REVIEW>` | Status the `jira_issue_transition_on_pr_open.yml` workflow moves an issue to when its PR is opened. A reviewer rejection does not move it back — the CHANGES REQUESTED verdict comment is the rejection signal. | `In Review` |
| `<STATUS_DONE>` | Final status, reached when the `jira_issue_transition_on_merge.yml` workflow fires on a PR merge into the base/parent branch. No skill transitions to this state (or any other) directly. Must match your workflow's real status name exactly. | `Done` |

## Required (in `jira-sdlc-tools.local.env`)

| Token | What it is | Example |
|---|---|---|
| `<WORKTREES_DIR>` | Path to the sibling directory where per-issue worktrees are created, relative to the repo root. Must already exist — `jira-task-assigner` will not create it. | `../myapp-worktrees` |
| `<JIRA_ACCOUNT_URL>` | Your Jira Cloud site URL (the `*.atlassian.net` domain). Used for the one-time `acli jira auth login` and for constructing issue browse links (`https://<JIRA_ACCOUNT_URL>/browse/<KEY>`). | `your-site.atlassian.net` |
| `<JIRA_ACCOUNT_EMAIL>` | The email address of the Jira account that owns the API token. Used for the one-time `acli jira auth login`. | `you@example.com` |
| `<JIRA_TOKEN>` | Jira API token value OR path to a file containing the token. `acli jira auth login --token` reads from stdin, so both forms work — use the one that matches how this variable is set on your machine:<br>• path form: `acli jira auth login … --token < <JIRA_TOKEN>`<br>• value form: `printf '%s' "<JIRA_TOKEN>" \| acli jira auth login … --token`<br>The default example below keeps `.jira/token.txt` (path still works); a raw token value is also accepted. | `.jira/token.txt` |

## Optional — sensible defaults, override if yours differ (in `jira-sdlc-tools.env`)

| Token | What it is | Default |
|---|---|---|
| `<SEMVER_LABELS>` | The three GitHub label names `jira-task-executor` applies to PRs for release automation. Must already exist on the repo. | `patch` / `minor` / `major` |

### acli auth (one-time setup)

`acli` stores credentials in its own keyring after a one-time login — no
per-command token prefix. Run this once before using any skill:

```bash
# path form — when JIRA_TOKEN is a file path:
acli jira auth login \
  --site "<JIRA_ACCOUNT_URL>" \
  --email "<JIRA_ACCOUNT_EMAIL>" \
  --token < <JIRA_TOKEN>

# value form — when JIRA_TOKEN holds the raw token:
printf '%s' "<JIRA_TOKEN>" | acli jira auth login \
  --site "<JIRA_ACCOUNT_URL>" \
  --email "<JIRA_ACCOUNT_EMAIL>" \
  --token
```

Verify with `acli jira auth status`.

`JIRA_API_TOKEN` (the `jira-cli` per-command env-var prefix) is no longer
used — skills assume stored acli credentials and do not mention it.
`JIRA_TOKEN` holds either the token value itself or a path to a token file
for the `--token` stdin redirect above.

## Worked example

The README's usage walkthrough assumes these filled-in files:

**`jira-sdlc-tools.env` (committed):**
```
PROJECT-KEY           = PROJ
DEFAULT_BASE_BRANCH   = development
PRODUCTION_BRANCH     = main
STATUS_TODO           = To Do
STATUS_IN_PROGRESS    = In Progress
STATUS_IN_REVIEW      = In Review
STATUS_DONE           = Done
SEMVER_LABELS         = patch / minor / major
```

**`jira-sdlc-tools.local.env` (gitignored):**
```
WORKTREES_DIR         = ../myapp-worktrees
JIRA_ACCOUNT_URL      = your-site.atlassian.net
JIRA_ACCOUNT_EMAIL    = you@example.com
JIRA_TOKEN             = .jira/token.txt
```