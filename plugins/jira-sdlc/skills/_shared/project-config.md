# Project configuration reference

This file describes every variable used in `jira-sdlc-tools.env` and
`jira-sdlc-tools.local.env`. Both live in a **`.jst/` folder at the project
root** — `.jst/jira-sdlc-tools.env` and `.jst/jira-sdlc-tools.local.env` — and
that is the only location the skills read; a leftover copy at the root itself
is ignored. All project-specific values live in these two files — nothing else under `skills/`
should need editing after they're filled in.

Each skill's "Conventions used below" section names the tokens it needs
(e.g. `<PROJECT-KEY>`). Before following a skill's instructions, resolve
every token it references against **both** env files; the tables below
describe what each variable means.

## What lives in `.jst/`

| File | Purpose | Committed? |
|------|---------|------------|
| `.jst/jira-sdlc-tools.env` | Team-shared settings (project key, status names, default branch). Same for every developer. | **Yes** — checked into the repo |
| `.jst/jira-sdlc-tools.local.env` | Developer/machine-specific settings (worktrees path, Jira URL, email, token path). Different per machine. | **No** — listed in `.gitignore` as `.jst/jira-sdlc-tools.local.env` |
| `.jst/PARALLEL-INSTANCES.md` | **Optional.** Prose, not variables: how to turn one of this project's worktrees into a *running* instance. Absence is normal — see below. | **Yes** — checked into the repo |

Both env files are sourced by tools that need them. Values in
`jira-sdlc-tools.local.env` override those in `jira-sdlc-tools.env` if both
define the same variable (though they define disjoint sets by convention).

### `.jst/PARALLEL-INSTANCES.md` — optional, and free-form

The two env files above are required; this one is not, and **most projects
won't have it**. Nothing warns, blocks, or fails when it's missing — the
`parallel_instances` healthcheck row reports either way as INFO, and
`jira-task-assigner` simply says nothing about it.

Write one when a fresh worktree of your project isn't runnable until something
is provisioned for it — a cloned database, an instance index that picks the
ports, a compose stack scoped to the checkout. The plugin creates N worktrees;
it can't know what your stack needs to become N running instances, so this file
is where your project writes that down once instead of it living in one
developer's head. When it exists, the assigner reads it and folds its
instructions into the report for each worktree it creates, so whoever picks a
worktree up knows what's still to do before the app will start. The assigner
never *runs* any of it — provisioning is environment setup for whoever works
the issue.

It's **tracked**, unlike the gitignored `jira-sdlc-tools.local.env`, and that's
the point: a linked worktree is born with it, with no copy step to arrange (the
reason `ensure_local_env` exists for local.env).

Nothing parses the file — no schema, no tokens, no required headings. Write it
for a human. To draft one, start from the shipped example,
`plugins/jira-sdlc/docs/examples/PARALLEL-INSTANCES.example.md`.

The companion doc is [`docs/RUNNING-MULTIPLE-COPIES.md`](../../docs/RUNNING-MULTIPLE-COPIES.md):
that one is how to *decide* what each worktree's instance shares versus
isolates (database, cache, storage, queue, ports); this file is where your
project records the answer it landed on, in runnable terms.

Every skill's pre-flight healthcheck (`statuscheck`) has a `jst_dir` row that
FAILs — before any other check runs — when `.jst/` is missing, so a checkout
without it halts rather than running half-configured.

## Required (in `.jst/jira-sdlc-tools.env`)

| Token | What it is | Example |
|---|---|---|
| `<PROJECT-KEY>` | Your Jira project key. | `PROJ` |
| `<DEFAULT_BASE_BRANCH>` | The branch new top-level work starts from when there's no parent context yet. | `development` |
| `<PRODUCTION_BRANCH>` | The production branch that hotfixes branch from and target. | `main` |
| `<STATUS_TODO>` | Status used for newly created issues. | `To Do` |
| `<STATUS_IN_PROGRESS>` | Status `jira-task-executor` transitions an issue to when it starts work. | `In Progress` |
| `<STATUS_IN_REVIEW>` | Status used when a PR is opened and under review. | `In Review` |
| `<STATUS_DONE>` | Final status reached when PRs are merged (typically by GitHub-for-Jira automation when a PR is merged into the base/parent branch). No skill transitions to this state on its own: `jira-task-reviewer` step 7 offers it for approved issues at the end of a run and moves only what you approve; otherwise it is handled by automation or a manual `jira.sh issue transition <KEY> --to "<STATUS_DONE>"`. Must match your workflow's real status name exactly. | `Done` |

## Required (in `.jst/jira-sdlc-tools.local.env`)

| Token | What it is | Example |
|---|---|---|
| `<WORKTREES_DIR>` | Path to the sibling directory where per-issue worktrees are created, relative to the repo root. Must already exist — `jira-task-assigner` will not create it. | `../myapp-worktrees` |
| `<JIRA_ACCOUNT_URL>` | Your Jira Cloud site URL (the `*.atlassian.net` domain). `jira.sh` uses it to resolve the cloud id (from `_edge/tenant_info`), and it constructs issue browse links (`https://<JIRA_ACCOUNT_URL>/browse/<KEY>`). | `your-site.atlassian.net` |

The three **role credential pairs** are required too — they're the whole of the
auth model, so they get their own section below.

### Auth — per-request, no login step

There is **no login and no keyring**. The `jira.sh` / `jira.ps1` client
(`skills/_shared/jira-api-reference.md` §9) authenticates **per-request**:
every call resolves its credential from these env files and sends it as Basic
auth on that one request. Nothing to set up before first use — fill in the
variables above plus the three role pairs below and the skills work.

Every token is the raw token value; a file path is not accepted. Create the
tokens at `id.atlassian.com` → Security → API tokens (classic or scoped both
work through the gateway — see `jira-api-reference.md` §5).

Each skill picks its role identity per-request with `jira.sh --role
assigner|executor|reviewer`, which selects that role's pair below. `--role` is
**required** — there is no default account to fall back on. Because auth is
per-request, different roles can run **concurrently** as different identities
with no shared, machine-global "active account" to race over — the reason the
earlier login-based model was replaced.

## Required — per-role Jira accounts (in `.jst/jira-sdlc-tools.local.env`)

Each skill runs as its **own** Jira account, so the board shows who did
what: the assigner filed it, the executor implemented it, the reviewer
approved it. All six variables below are required — each role needs BOTH its
own email and its own token, and there is no default pair behind them. The
three accounts may of course be the same Atlassian account if you'd rather not
split them; state it explicitly in all three pairs.

| Token | What it is | Example |
|---|---|---|
| `<JIRA_ASSIGNER_EMAIL>` / `<JIRA_ASSIGNER_TOKEN>` | The account `jira-task-assigner` runs as — it creates the issues and their comments. | `assigner@example.com` / `ATATT3xFfGF0…` |
| `<JIRA_EXECUTOR_EMAIL>` / `<JIRA_EXECUTOR_TOKEN>` | The account `jira-task-executor` runs as. Doubles as the **assignee**: the assigner puts this email on every issue it creates, and the executor refuses to work an issue that isn't assigned to it. | `executor@example.com` / `ATATT3xFfGF0…` |
| `<JIRA_REVIEWER_EMAIL>` / `<JIRA_REVIEWER_TOKEN>` | The account `jira-task-reviewer` runs as — it posts the verdict comments. | `reviewer@example.com` / `ATATT3xFfGF0…` |

Tokens are the raw API token **value**, never a path to a file. A role missing
either half is an error, not a fallback: `jira.sh --role <role>` stops and
names the variable to set, rather than quietly acting as somebody else.

**What this enables.** The assigner assigns every issue it creates
(top-level and sub-task) to the executor's email rather than leaving it
unassigned for board triage — the previous default. The executor then
**gates on ownership**: before any status transition or work, it refuses an
issue not assigned to the executor, prints the command to assign it, and
exits without transitioning, branching, committing, or commenting. The gate
holds against whichever account `JIRA_EXECUTOR_EMAIL` names — including the
case where all three roles point at one Atlassian account.

**It's in the scripts, not in skill prose.** All of them parse the env files
with the same `NAME = value` parser and local-overrides-team precedence as
`statuscheck.sh`, and the gate scripts are driven by their **exit code**. There
is no login script to run first — each call simply picks its role:

```bash
# jira-task-assigner — the address to put on the new issues' assignee, and nothing else:
ASSIGNEE_EMAIL=$(bash skills/_shared/scripts/posix/get_assignee_email.sh) || exit 1

# jira-task-executor — the issue must belong to the executor identity:
bash skills/_shared/scripts/posix/check_assignee.sh --role executor   # 0 = continue, non-zero = stop
```

`check_assignee.sh` resolves its own identity by calling `jira.sh --role
<role> whoami` (the account that role's credential authenticates as) and
compares that account's `accountId` to the issue's assignee. `--role` is what
decides which identity is demanded — no ambient logged-in state to consult.
Unassigned, assigned to someone else, unreadable, or a hidden assignee email
are all the same answer: halt, with the `jira.sh issue assign …` command to fix
it on stderr.

Because auth is per-request, there is **no machine-global side effect** and
nothing to restore at the end of a run: the executor authenticating as the
executor for its own calls doesn't change what any other shell or a parallel
skill sees. This is the concrete payoff of the per-request model over the old
single-active-account login — parallel runs as distinct identities simply
can't race.

## Optional — conversation sync (lab-only, in `jira-sdlc-tools.local.env`)

Read only by the lab `jira-task-helper` `sync_conversations` builtin, which
attaches an issue's Claude Code transcripts to its Jira issue. Both are paths to
transcript folders under `~/.claude/projects` (Claude Code names each folder after
a session's cwd, with every path separator replaced by `-`). The core three skills
never read them, so a project that doesn't use the lab channel can omit both.

| Token | What it is | Example |
|---|---|---|
| `CONVERSATIONS_MAINREPO_PATH` | The main checkout's transcript folder, used as-is — where the assigner's issue-creating session lives. | `~/.claude/projects/-home-you-src-myapp` |
| `CONVERSATIONS_WORKTREES_PREFIX` | The **prefix** shared by every worktree's transcript folder; the script appends `worktree-<KEY>` to it to locate one issue's folder. Pinning a prefix (not per-issue paths) is what scopes the builtin to your worktrees tree and nothing else under `~/.claude/projects`. | `~/.claude/projects/-home-you-src-myapp-worktrees-` |

The builtin reads both from these files (not the process environment — so the
agent can't widen the scope by exporting a variable) and exits 1 if
`CONVERSATIONS_MAINREPO_PATH` isn't an existing directory, if
`CONVERSATIONS_WORKTREES_PREFIX` is unset, or if the resolved
`<prefix>worktree-<KEY>` doesn't exist (the issue had no worktree). See
[`../conversation-debugger/scripts/sync-conversation.md`](../conversation-debugger/scripts/sync-conversation.md).

## Worked example

The README's usage walkthrough assumes these filled-in files:

**`.jst/jira-sdlc-tools.env` (committed):**
```
PROJECT-KEY           = PROJ
DEFAULT_BASE_BRANCH   = development
PRODUCTION_BRANCH     = main
STATUS_TODO           = To Do
STATUS_IN_PROGRESS    = In Progress
STATUS_IN_REVIEW      = In Review
STATUS_DONE           = Done
```

**`.jst/jira-sdlc-tools.local.env` (gitignored):**
```
WORKTREES_DIR         = ../myapp-worktrees
JIRA_ACCOUNT_URL      = your-site.atlassian.net
# All three role pairs are required — one email + one token each, no default:
JIRA_ASSIGNER_EMAIL   = assigner@example.com
JIRA_ASSIGNER_TOKEN   = ATATT3xFfGF0…
JIRA_EXECUTOR_EMAIL   = executor@example.com
JIRA_EXECUTOR_TOKEN   = ATATT3xFfGF0…
JIRA_REVIEWER_EMAIL   = reviewer@example.com
JIRA_REVIEWER_TOKEN   = ATATT3xFfGF0…
# Optional — lab-only conversation sync (see "Optional — conversation sync" above):
#CONVERSATIONS_MAINREPO_PATH      = ~/.claude/projects/-home-you-src-myapp
#CONVERSATIONS_WORKTREES_PREFIX  = ~/.claude/projects/-home-you-src-myapp-worktrees-
```