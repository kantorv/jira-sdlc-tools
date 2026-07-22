# Full setup checklist

Tick these off before the first `/jira-sdlc:jira-task-assigner` run. Each item
says how to check it, not just what to have. The last section is a single
command that verifies most of the list for you.

Prose walkthrough of the same ground: [STEP-BY-STEP.md](STEP-BY-STEP.md).

## Your PC

Three CLIs must be installed and authenticated on your machine, plus a couple
of helpers the bundled scripts shell out to.

- [ ] **`git`** — commit/push. Uses your machine's existing global credentials,
      so there's nothing extra to configure.
      [git-scm.com/downloads](https://git-scm.com/downloads)
- [ ] **`gh`** (GitHub CLI) — opens and updates PRs. Authenticates with
      `GITHUB_PAT_TOKEN` from your local env file.
      [cli.github.com](https://cli.github.com/) ·
      [GH-PAT-SESSION-LOGIN.md](github/GH-PAT-SESSION-LOGIN.md)
- [ ] **`acli`** (Atlassian CLI) — issues, comments, transitions.
      Authenticates with `JIRA_TOKEN`.
      [install acli](https://developer.atlassian.com/cloud/acli/guides/install-acli/) ·
      [JIRA-ACLI.md](JIRA-ACLI.md)

Helper tools — which ones depends on your OS:

- [ ] **Windows: `pwsh` (PowerShell 7+) or `powershell` (5.1)** — runs the
      `win/*.ps1` ports. 5.1 ships with Windows, so this is usually already
      ticked.
      [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
- [ ] **Linux / macOS: `jq`** — the scripts are bash, which can't parse JSON on
      its own. `check_assignee` uses it as its fast path (falling back to
      `grep`/`sed`), and the `acli-list-subtasks` helper requires it outright.
      [jqlang.github.io/jq](https://jqlang.github.io/jq/download/)
- [ ] **Linux / macOS: `python3`** — recommended (required by the
      [lab channel](../../../README.md#lab-channel)).
      [python.org/downloads](https://www.python.org/downloads/)

Verify in one go — **macOS / Linux**:

```bash
git --version && gh --version && acli --version && jq --version
python3 --version   # lab channel only
```

**Windows** (PowerShell) — `jq` and `python3` aren't needed here, the `.ps1`
ports parse JSON natively:

```powershell
git --version; gh --version; acli --version; $PSVersionTable.PSVersion
```

`&&` stops at the first missing tool, naming exactly what to install; PowerShell's
`;` runs them all, so scan the output for the one that errored.

## GitHub

- [ ] **You have a repository** — the one you'll be building features in. Not
      this toolkit repo: the skills run *in your project*, and read their
      config from your project's root.
- [ ] **It has a production branch and a base branch.** Two distinct branches:
      `PRODUCTION_BRANCH` (what releases land on, default `main`) and
      `DEFAULT_BASE_BRANCH` (what feature work branches from and merges back
      into, default `development`). The second is the one people are missing —
      a repo with only `main` needs a `development` branch created before the
      assigner has anywhere to branch from.
      ```bash
      git branch -a --list 'main' 'development'   # or your own two names
      ```
- [ ] **It can follow Gitflow.** The skills assume `feature/<KEY>-<slug>` and
      `hotfix/<KEY>-<slug>` branches, PRs into the base branch, and releases
      merging into production. If your repo uses trunk-based development with
      no long-lived integration branch, decide now whether to add one — the
      full policy is in [SDLC.md](SDLC.md).
- [ ] **You have a `GITHUB_PAT_TOKEN`.** A fine-grained PAT with **Contents →
      Read and write** and **Pull requests → Read and write** on the target
      repo (Metadata → Read-only is added for you). It logs `gh` in at session
      start; without it the `gh_auth` healthcheck row FAILs and the run halts.
      Where to click:
      [GH-PAT-SESSION-LOGIN.md](github/GH-PAT-SESSION-LOGIN.md).

## Jira

- [ ] **You have a Jira account** on a Cloud site (`your-site.atlassian.net`).
      Note the site URL and the account email — both go in the local env file.
- [ ] **You have a board and a project key.** The key is the prefix on every
      issue (`PROJ-123` → `PROJ`), and it's what the skills match branch names
      against, so a branch for the wrong project is caught rather than worked.
- [ ] **The board has all four statuses.** `To Do`, `In Progress`, `In Review`,
      `Done` by default — map them to whatever yours are really called. **`In
      Review` is the one that's usually missing**: several Jira templates ship
      only To Do / In Progress / Done. Add the column, or point
      `STATUS_IN_REVIEW` at an existing status. A name that doesn't exist on
      the board fails the transition at runtime, not at setup.
- [ ] **You have a Jira API token.** Create it at
      [id.atlassian.com → API tokens](https://id.atlassian.com/manage-profile/security/api-tokens).
      Use a **plain API token** — `acli` rejects granular per-issue scopes with
      *"scope does not match"*. If you must use a scoped token, give it the
      coarse `read:jira-work` and `write:jira-work`. Detail:
      [JIRA-ACLI.md](JIRA-ACLI.md).
- [ ] *(Optional)* **Per-role Jira accounts** — separate emails/tokens for the
      assigner, executor and reviewer, so the board shows who did what. Leave
      them commented out to run everything as one account.

## Project

- [ ] **`jira-sdlc-tools.env` exists in your project root** — team-shared
      settings, committed. Copy
      [`jira-sdlc-tools.env`](../../../jira-sdlc-tools.env) from this repo and
      fill in the blanks.
- [ ] **`jira-sdlc-tools.local.env` exists in your project root** —
      machine-specific settings *and secrets*. Copy
      [`jira-sdlc-tools.local.env.example`](../../../jira-sdlc-tools.local.env.example).
- [ ] **`jira-sdlc-tools.local.env` is gitignored.** It holds your raw Jira
      token and GitHub PAT, so committing it leaks both.
      ```bash
      echo 'jira-sdlc-tools.local.env' >> .gitignore
      git check-ignore -v jira-sdlc-tools.local.env   # prints the rule if ignored
      ```
      The healthcheck's `env_local_ignored` row checks this too — but it checks
      it *after* the file already exists, so do it in this order.
- [ ] **`WORKTREES_DIR` points somewhere sensible** — a sibling of your repo,
      e.g. `../myapp-worktrees`. Every issue gets its own worktree there.

## Settings files

Two files, both in **your project's** root — never in this toolkit's.
Every `<TOKEN>` in the skills resolves from them. Full per-variable reference:
[project-config.md](../skills/_shared/project-config.md).

**`jira-sdlc-tools.env`** — team-shared, committed:

```bash
# GITHUB SETTINGS (shared/team)
DEFAULT_BASE_BRANCH=development
PRODUCTION_BRANCH=main

# JIRA SETTINGS (shared/team)
PROJECT_KEY=PROJ
STATUS_TODO=To Do
STATUS_IN_PROGRESS=In Progress
STATUS_IN_REVIEW=In Review
STATUS_DONE=Done
```

**`jira-sdlc-tools.local.env`** — machine-specific, **gitignored**, holds
secrets:

```bash
# GITHUB SETTINGS (machine-specific)
WORKTREES_DIR=../myapp-worktrees
GITHUB_PAT_TOKEN="github_pat_…"

# JIRA DEFAULT SETTINGS
JIRA_ACCOUNT_URL=your-site.atlassian.net
JIRA_ACCOUNT_EMAIL=you@example.com
JIRA_TOKEN=your-api-token-value      # the raw token, not a path to a file

# PER-ROLE JIRA ACCOUNTS (optional) — omit to run as one account
#JIRA_ASSIGNER_EMAIL=assigner@example.com
#JIRA_ASSIGNER_TOKEN=…
#JIRA_EXECUTOR_EMAIL=executor@example.com
#JIRA_EXECUTOR_TOKEN=…
#JIRA_REVIEWER_EMAIL=reviewer@example.com
#JIRA_REVIEWER_TOKEN=…
```

Two traps worth knowing: `JIRA_TOKEN` is the **raw token value**, not a path to
a file holding it; and `JIRA_EXECUTOR_EMAIL`, if set, doubles as the
**assignee** — the assigner puts it on every issue it creates, and the executor
refuses to work an issue that isn't assigned to it.

## Verify it

Rather than re-reading the list, run the healthcheck from your project root —
it's the same script the skills run before they do anything:

```bash
bash <path-to-plugin>/skills/_shared/scripts/posix/statuscheck.sh
# Windows: pwsh -NoProfile -File <path-to-plugin>/skills/_shared/scripts/win/statuscheck.ps1
```

It prints one table and exits non-zero if anything is broken. The rows that map
onto this checklist:

| Row | Covers |
|---|---|
| `git_repo` | you're in a git repository |
| `env_config` | `jira-sdlc-tools.env` found and parsed |
| `env_local` | `jira-sdlc-tools.local.env` found |
| `env_local_ignored` | the local env file is gitignored |
| `gh_auth` | `GITHUB_PAT_TOKEN` works — `gh` is authenticated |
| `acli_auth` | `JIRA_TOKEN` works — `acli` is authenticated |
| `jira_project` | `PROJECT_KEY` resolves to a real Jira project |
| `base_branch` | `DEFAULT_BASE_BRANCH` is set |
| `worktrees_dir` | `WORKTREES_DIR` exists (WARN only — the assigner creates it) |

Every FAIL row prints its own remedy line under the table. Relay those rather
than guessing — and note the checklist items the script *can't* see: whether
your board really has an `In Review` column, and whether your two branches are
the ones you meant.
