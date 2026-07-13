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
| `jira-sdlc-tools.env` | Team-shared settings (project key, status names, default branch). Same for every developer. | **Yes** — checked into the repo |
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
| `<STATUS_IN_PROGRESS>` | Status `jira-task-executor` transitions an issue to when it starts work. | `In Progress` |
| `<STATUS_IN_REVIEW>` | Status used when a PR is opened and under review. | `In Review` |
| `<STATUS_DONE>` | Final status reached when PRs are merged (typically by GitHub-for-Jira automation when a PR is merged into the base/parent branch). No skill transitions to this state directly; it is handled by automation or a manual `acli jira workitem transition --key <KEY> --status "<STATUS_DONE>" --yes`. Must match your workflow's real status name exactly. | `Done` |

## Required (in `jira-sdlc-tools.local.env`)

| Token | What it is | Example |
|---|---|---|
| `<WORKTREES_DIR>` | Path to the sibling directory where per-issue worktrees are created, relative to the repo root. Must already exist — `jira-task-assigner` will not create it. | `../myapp-worktrees` |
| `<JIRA_ACCOUNT_URL>` | Your Jira Cloud site URL (the `*.atlassian.net` domain). Used for the one-time `acli jira auth login` and for constructing issue browse links (`https://<JIRA_ACCOUNT_URL>/browse/<KEY>`). | `your-site.atlassian.net` |
| `<JIRA_ACCOUNT_EMAIL>` | The email address of the Jira account that owns the API token. Used for the one-time `acli jira auth login`. | `you@example.com` |
| `<JIRA_TOKEN>` | The Jira API token **value** itself — not a path to a file containing it. `acli jira auth login --token` reads from stdin: `printf '%s' "<JIRA_TOKEN>" \| acli jira auth login … --token`. | `ATATT3xFfGF0…` |

### acli auth (one-time setup)

`acli` stores credentials in its own keyring after a one-time login — no
per-command token prefix. Run this once before using any skill:

```bash
printf '%s' "<JIRA_TOKEN>" | acli jira auth login \
  --site "<JIRA_ACCOUNT_URL>" \
  --email "<JIRA_ACCOUNT_EMAIL>" \
  --token
```

Verify with `acli jira auth status`.

`JIRA_API_TOKEN` (the `jira-cli` per-command env-var prefix) is no longer
used — skills assume stored acli credentials and do not mention it.
`JIRA_TOKEN` holds the raw token value; a file path is not accepted.

The `jira-task-executor` skill re-runs this login as the optional
"executor" worker account before working an issue (`acli jira auth
logout` first, so the new credential actually takes effect — the §0
gotcha above) — see the **Optional** section below for the executor
variables and the machine-global side effect of that re-login.

## Optional (in `jira-sdlc-tools.local.env`)

Both variables below are **optional**. When unset or empty, the skills
fall back to the corresponding `<JIRA_ACCOUNT_*>` value above, so an
existing setup keeps working — with one deliberate behavior shift
documented under "What this enables" below.

| Token | What it is | Example |
|---|---|---|
| `<JIRA_EXECUTOR_EMAIL>` | Email of an optional dedicated "executor" worker account that owns every issue the skills create and act on. Falls back to `<JIRA_ACCOUNT_EMAIL>` when unset/empty. | `someworker@example.com` |
| `<JIRA_EXECUTOR_TOKEN>` | The executor account's Jira API token **value** itself — not a path to a file containing it, exactly as with `<JIRA_TOKEN>`. Falls back to `<JIRA_TOKEN>` when unset/empty. | `ATATT3xFfGF0…` |

**What this enables.** When `jira-task-assigner` creates an issue
(top-level or sub-task), it assigns it to the executor email (falling
back to `<JIRA_ACCOUNT_EMAIL>` when no executor is configured) — instead
of leaving it unassigned for board triage, the previous default. Then
`jira-task-executor`, after its Discovery healthcheck and before any
status transition or work, re-logs `acli` in as that identity and
**gates on ownership**: it refuses to work an issue that is not assigned
to the executor email, tells the user to assign it (or assign it
explicitly in Jira) and rerun, and exits without transitioning,
branching, committing, or commenting. This is the default even with
nothing configured — issues are owned by the default account instead of
being unassigned.

**Resolution lives in a shell script, not in skill prose.**
`skills/_shared/scripts/get_executor_creds.sh` greps
`jira-sdlc-tools.local.env` then `jira-sdlc-tools.env` using the same
`NAME = value` parser and local-overrides-team precedence as
`statuscheck.sh`, and emits shell-eval-able `EXECUTOR_*` variables the
skills consume:

```bash
eval "$(bash skills/_shared/scripts/get_executor_creds.sh)"
# sets: EXECUTOR_EMAIL, EXECUTOR_TOKEN, EXECUTOR_SITE, EXECUTOR_FALLBACK
```

Capture **stdout only** (its diagnostics go to stderr); `EXECUTOR_FALLBACK=1`
means the identity fell back to the default account. The token is on
stdout by necessity (eval must load it for the re-login) — never echo
`$EXECUTOR_TOKEN`, redirect the script's stdout, or merge stderr
(`2>&1`) into the eval capture, or the token lands in a Jira comment or
chat transcript. `get_executor_creds.sh` exits non-zero with a message
on stderr if it cannot resolve an email (also if the token or site are
missing — all three are required to actually log in).

⚠️ **Machine-global side effect of the re-login.** `acli`'s credential
store is single-active-account and shared across every shell on the
machine, so `acli jira auth logout` + `acli jira auth login` as the
executor makes that account the active one for *every* other shell and
skill until something re-logs it. The executor accepts this deliberately
and does **not** restore the default account at the end of a run —
restoring it would race with parallel executors — and calls the side
effect out in its run report. (`acli jira auth switch` was considered as
a non-destructive alternative but deferred: it requires both accounts to
be pre-authenticated.)

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
```

**`jira-sdlc-tools.local.env` (gitignored):**
```
WORKTREES_DIR         = ../myapp-worktrees
JIRA_ACCOUNT_URL      = your-site.atlassian.net
JIRA_ACCOUNT_EMAIL    = you@example.com
JIRA_TOKEN            = ATATT3xFfGF0…
# Optional executor worker identity (defaults to JIRA_ACCOUNT_EMAIL/JIRA_TOKEN above) —
# uncomment + fill to run the skills as a dedicated account:
#JIRA_EXECUTOR_EMAIL   = someworker@example.com
#JIRA_EXECUTOR_TOKEN   = ATATT3xFfGF0…
```