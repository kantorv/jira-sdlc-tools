# Project configuration reference

This file describes every variable used in `jira-sdlc-tools.env` and
`jira-sdlc-tools.local.env` (the `.env` files in the project root), plus the
optional `JIRA-SDLC-TOOLS-RULES.md` that sits beside them. All
project-specific values live in these files — nothing else under `skills/`
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

A third, **optional** file may sit beside them —
`JIRA-SDLC-TOOLS-RULES.md`, prose rather than values. It is described in
[Project rules file](#project-rules-file--jira-sdlc-tools-rulesmd) at the
end of this document.

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

## Optional — per-role Jira accounts (in `jira-sdlc-tools.local.env`)

Each skill can run as its **own** Jira account, so the board shows who did
what: the assigner filed it, the executor implemented it, the reviewer
approved it. Every variable below is optional and falls back to the default
account, so a project that configures none of them keeps working.

| Token | What it is | Example |
|---|---|---|
| `<JIRA_ASSIGNER_EMAIL>` / `<JIRA_ASSIGNER_TOKEN>` | The account `jira-task-assigner` runs as — it creates the issues and their comments. | `assigner@example.com` / `ATATT3xFfGF0…` |
| `<JIRA_EXECUTOR_EMAIL>` / `<JIRA_EXECUTOR_TOKEN>` | The account `jira-task-executor` runs as. Doubles as the **assignee**: the assigner puts this email on every issue it creates, and the executor refuses to work an issue that isn't assigned to it. | `executor@example.com` / `ATATT3xFfGF0…` |
| `<JIRA_REVIEWER_EMAIL>` / `<JIRA_REVIEWER_TOKEN>` | The account `jira-task-reviewer` runs as — it posts the verdict comments. | `reviewer@example.com` / `ATATT3xFfGF0…` |

Tokens are the raw API token **value**, never a path to a file (as with
`<JIRA_TOKEN>`). Email and token fall back **independently**: a role that
sets only `<ROLE>_EMAIL` shares the default token, which is useful when one
Atlassian account has several addresses.

**What this enables.** The assigner assigns every issue it creates
(top-level and sub-task) to the executor's email rather than leaving it
unassigned for board triage — the previous default. The executor then
**gates on ownership**: before any status transition or work, it refuses an
issue not assigned to the executor, prints the command to assign it, and
exits without transitioning, branching, committing, or commenting. With
nothing configured, all three roles resolve to the default account and the
gate still holds — issues are simply owned by that one account.

**It's in the scripts, not in skill prose.** All of them parse the env files
with the same `NAME = value` parser and local-overrides-team precedence as
`statuscheck.sh`, and all are driven by their **exit code**:

```bash
# any skill, first thing — idempotent, so call it unconditionally:
bash skills/_shared/scripts/posix/jira_acli_login.sh <executor|assigner|reviewer> || exit 1

# jira-task-assigner — the address to put on --assignee, and nothing else:
ASSIGNEE_EMAIL=$(bash skills/_shared/scripts/posix/get_assignee_email.sh) || exit 1

# jira-task-executor — the issue must belong to the account just logged in:
bash skills/_shared/scripts/posix/check_assignee.sh   # 0 = continue, non-zero = stop
```

`check_assignee.sh` compares the issue's assignee to whoever `acli` is
logged in as (read from acli's own config, not re-derived from the env), so
the login above is what decides which identity is demanded. Unassigned,
assigned to someone else, unreadable, or a hidden assignee email are all the
same answer: halt, with the `acli jira workitem assign …` command to fix it
on stderr.

`jira_acli_login.sh` is the one place a login happens. It is **idempotent**:
acli records the active account in `~/.config/acli/jira_config.yaml`, so if
that already matches the role, the call is a ~30ms no-op that never touches
the network. (It deliberately does *not* use `acli jira auth status`, which
takes ~20s per call and answers from cache anyway.) When a switch *is*
needed it runs `acli jira auth logout` **first** — a second `auth login` does
not overwrite acli's stored credential, so without the logout the old account
silently stays active while `auth status` still reports success. Tokens are
piped to acli on stdin: never printed, never on a command line.

⚠️ **Switching roles is machine-global.** acli's credential store is
single-account and shared by every shell on the machine, so whichever skill
ran last leaves its account active. That's accepted deliberately — restoring
the previous account would race with skills running in parallel — and it is
why each skill logs in for itself instead of assuming.

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
# Optional per-role accounts (each defaults to JIRA_ACCOUNT_EMAIL/JIRA_TOKEN above) —
# uncomment + fill to have each skill act as its own Jira user:
#JIRA_ASSIGNER_EMAIL   = assigner@example.com
#JIRA_ASSIGNER_TOKEN   = ATATT3xFfGF0…
#JIRA_EXECUTOR_EMAIL   = executor@example.com
#JIRA_EXECUTOR_TOKEN   = ATATT3xFfGF0…
#JIRA_REVIEWER_EMAIL   = reviewer@example.com
#JIRA_REVIEWER_TOKEN   = ATATT3xFfGF0…
```

## Project rules file — `JIRA-SDLC-TOOLS-RULES.md`

The prose counterpart to the two `.env` files: where those hold *values*
(keys, branch names, status names), this holds the *behavioural
conventions* between one codebase and these skills — "opening a PR is
enough, never transition to `<STATUS_IN_REVIEW>`", "transition to
`<STATUS_DONE>` yourself once the review approves", "our generated
directories are never hand-edited". It ships with the **destination
repo**, not with the plugin.

| | |
|---|---|
| Location | project root, next to `jira-sdlc-tools.env` |
| Committed? | **Yes** — team-shared, unlike `jira-sdlc-tools.local.env` |
| Required? | **No.** Absent is the normal case and never an error |

Start one by copying the template that ships in the plugin:

```bash
cp "${CLAUDE_PLUGIN_ROOT}/JIRA-SDLC-TOOLS-RULES.example.md" JIRA-SDLC-TOOLS-RULES.md
```

### Format

Markdown with exactly these four H2 sections, in this order. Any of them
may be empty; content is free-form prose instructions.

| Section | Applies to |
|---|---|
| `## COMMON` | all three skills |
| `## JIRA-TASK-ASSIGNER` | `jira-task-assigner` only |
| `## JIRA-TASK-EXECUTOR` | `jira-task-executor` only |
| `## JIRA-TASK-REVIEWER` | `jira-task-reviewer` only |

### Load contract

Each skill reads the file at the very start of its run — before its own
discovery/healthcheck work, so a project rule can shape the run from its
first step — and then:

1. **File absent** → proceed silently. No warning, no failure; it is optional.
2. **File present** → adopt `## COMMON` plus your own named section, and
   ignore the other two skills' sections. They belong to skills that
   aren't running.
3. Treat what you adopt as project conventions layered on top of the
   skill's own logic, and **where a rule and a `SKILL.md` instruction
   disagree, the rule wins** — the project knows its board, branches, and
   codebase; the skill only carries the generic default. Overriding skill
   behaviour is the entire point of the file, so a rule that contradicts a
   step is working as intended, not a conflict to resolve.

The read is deliberately prose and not a script: it is a single
conditional file read, so each skill just reads the path with its own
file-reading tool and there is no POSIX/Windows script pair to keep in
sync.