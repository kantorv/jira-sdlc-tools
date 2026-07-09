# Project configuration reference

This file describes every variable used in `jira-tools-plugin.env`
(the `.env` file in the project root). All project-specific values
live in `jira-tools-plugin.env` — nothing else under `skills/` should need editing
after that.

Each skill's "Conventions used below" section names the tokens it needs
(e.g. `<PROJECT-KEY>`). Before following a skill's instructions, resolve
every token it references against `jira-tools-plugin.env`; the tables below describe
what each variable means.

## Required

| Token | What it is | Example |
|---|---|---|
| `<PROJECT-KEY>` | Your Jira project key. | `PROJ` |
| `<WORKTREES_DIR>` | Path to the sibling directory where per-issue worktrees are created, relative to the repo root. Must already exist — `jira-task-assigner` will not create it. | `../myapp-worktrees` |
| `<DEFAULT_BASE_BRANCH>` | The branch new top-level work starts from when there's no parent context yet. | `development` |
| `<JIRA_ACCOUNT_URL>` | Your Jira Cloud site URL (the `*.atlassian.net` domain). Used for the one-time `acli jira auth login` and for constructing issue browse links (`https://<JIRA_ACCOUNT_URL>/browse/<KEY>`). | `your-site.atlassian.net` |
| `<JIRA_ACCOUNT_EMAIL>` | The email address of the Jira account that owns the API token. Used for the one-time `acli jira auth login`. | `you@example.com` |
| `<JIRA_TOKEN_PATH>` | Path to the file containing the Jira API token (read by `acli jira auth login --token < <JIRA_TOKEN_PATH>`). Retained from the legacy `jira-cli` config. | `.jira/token.txt` |

## Testing

`jira-task-executor` step 7 reads the project's own `CLAUDE.md`,
`AGENTS.md`, or README for "run one test" / "run full suite"
commands — it does **not** take test commands from
`jira-tools-plugin.env`. See that step for the policy and the
discovery flow when the project hasn't documented them.

## Jira workflow status names

These are already flagged as "confirm once" inside the skills, because
Jira status *names* vary by project even when the underlying states are the
same. Check yours with `acli jira workitem view <any-existing-key> --json`.

| Token | What it is | Example |
|---|---|---|
| `<STATUS_TODO>` | Status used for newly created issues. | `To Do` |
| `<STATUS_IN_PROGRESS>` | Status `jira-task-executor` transitions an issue to when it starts work. | `In Progress` |
| `<STATUS_IN_REVIEW>` | Status used when a PR is opened and under review. | `In Review` |
| `<STATUS_DONE>` | Final status reached when PRs are merged (typically by GitHub-for-Jira automation when a PR is merged into the base/parent branch). No skill transitions to this state directly; it is handled by automation or a manual `acli jira workitem transition --key <KEY> --status "<STATUS_DONE>" --yes`. Must match your workflow's real status name exactly. | `Done` |

## Optional — sensible defaults, override if yours differ

| Token | What it is | Default |
|---|---|---|
| `<SEMVER_LABELS>` | The three GitHub label names `jira-task-executor` applies to PRs for release automation. Must already exist on the repo. | `patch` / `minor` / `major` |

### acli auth (one-time setup)

`acli` stores credentials in its own keyring after a one-time login — no
per-command token prefix. Run this once before using any skill:

```bash
acli jira auth login \
  --site "<JIRA_ACCOUNT_URL>" \
  --email "<JIRA_ACCOUNT_EMAIL>" \
  --token < <JIRA_TOKEN_PATH>
```

Verify with `acli jira auth status`.

`JIRA_API_TOKEN` (the `jira-cli` per-command env-var prefix) is no longer
used — skills assume stored acli credentials and do not mention it. The
token file at `<JIRA_TOKEN_PATH>` is retained for the `--token <` redirect
above.

## Worked example

The README's usage walkthrough assumes this filled-in `jira-tools-plugin.env`:

```
PROJECT-KEY           = PROJ
WORKTREES_DIR         = ../myapp-worktrees
DEFAULT_BASE_BRANCH   = development
JIRA_ACCOUNT_URL      = your-site.atlassian.net
JIRA_ACCOUNT_EMAIL    = you@example.com
JIRA_TOKEN_PATH       = .jira/token.txt
STATUS_TODO           = To Do
STATUS_IN_PROGRESS    = In Progress
STATUS_IN_REVIEW      = In Review
STATUS_DONE           = Done
SEMVER_LABELS         = patch / minor / major
```
