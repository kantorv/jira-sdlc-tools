# Full setup checklist

Tick these off before the first `/jira-sdlc:jira-task-assigner` run. Each item
says how to check it, not just what to have. The last section is a single
command that verifies most of the list for you.

Prose walkthrough of the same ground: [STEP-BY-STEP.md](STEP-BY-STEP.md).
Guided version of it: `/jira-sdlc:jst-install`
([`SKILL.md`](../skills/jst-install/SKILL.md)), which ticks these items off
with you and runs the healthcheck between stages.

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
- [ ] **`curl` / `Invoke-RestMethod`** — issues, comments, transitions (via `jira.sh` / `jira.ps1`).
      Authenticates per-request with the calling role's `JIRA_<ROLE>_TOKEN`.
      [JIRA-REST.md](JIRA-REST.md)

Helper tools — which ones depends on your OS:

- [ ] **Windows: `pwsh` (PowerShell 7+) or `powershell` (5.1)** — runs the
      `win/*.ps1` ports. 5.1 ships with Windows, so this is usually already
      ticked.
      [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
- [ ] **Linux / macOS: `jq`** — the scripts are bash, which can't parse JSON on
      its own. `check_assignee` uses it as its fast path (falling back to
      `grep`/`sed`), and the `list_subtasks` helper requires it outright.
      [jqlang.github.io/jq](https://jqlang.github.io/jq/download/)
- [ ] **Linux / macOS: `python3`** — recommended (required by the
      [lab channel](../../../README.md#lab-channel)).
      [python.org/downloads](https://www.python.org/downloads/)

Verify in one go — **macOS / Linux**:

```bash
git --version && gh --version && jq --version
python3 --version   # lab channel only
```

**Windows** (PowerShell) — `jq` and `python3` aren't needed here, the `.ps1`
ports parse JSON natively:

```powershell
git --version; gh --version; $PSVersionTable.PSVersion
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
- [ ] **It can follow Gitflow.** The skills assume `<prefix>/<KEY>-<slug>`
      branches — `feature/`, `bugfix/`, `chore/` off the base branch and
      `hotfix/` off production — PRs into the base branch, and releases
      merging into production. If your repo uses trunk-based development with
      no long-lived integration branch, decide now whether to add one — the
      full policy is in [SDLC.md](SDLC.md).
- [ ] **You have a `GITHUB_PAT_TOKEN`.** A fine-grained PAT with **Contents →
      Read and write** and **Pull requests → Read and write** on the target
      repo (Metadata → Read-only is added for you). It logs `gh` in at session
      start; without it the `gh_auth` healthcheck row FAILs and the run halts.
      Where to click:
      [GH-PAT-SESSION-LOGIN.md](github/GH-PAT-SESSION-LOGIN.md).
- [ ] **…and the PAT can actually reach *this* repo.** A fine-grained token
      scoped to *only selected repositories* logs in green while 404-ing on a
      repo missing from that list — 404, not 403, so it reads like a typo — and
      with an SSH `origin` nothing breaks until `gh pr create` fails mid-task.
      The `gh_repo_access` row probes it; by hand:
      ```bash
      gh api repos/<OWNER>/<REPO> >/dev/null && echo "PAT can see it"
      ```

## Jira

- [ ] **You have a Jira account** on a Cloud site (`your-site.atlassian.net`).
      Note the site URL and the account email — both go in the local env file.
- [ ] **You have a board and a project key.** The key is the prefix on every
      issue (`PROJ-123` → `PROJ`), and it's what the skills match branch names
      against, so a branch for the wrong project is caught rather than worked.
      List the ones your credential can see rather than typing one blind:
      ```bash
      bash _shared/scripts/posix/jira.sh --role executor raw GET /project/search \
        | jq -r '.values[] | "\(.key)\t\(.name)"'
      ```
- [ ] **Each of the four `STATUS_*` settings names a status your board really
      has.** `To Do` / `In Progress` / `In Review` / `Done` are the Kanban
      template's names, not a requirement — read yours and map onto them, since
      matching is literal and a name that doesn't exist fails the transition at
      runtime rather than at setup:
      ```bash
      bash _shared/scripts/posix/jira.sh --role executor raw GET /project/<KEY>/statuses \
        | jq -r '[.[].statuses[].name] | unique | .[]'
      ```
      Expect mismatches: `In Review` is missing from several templates, and a
      board with `Backlog` / `Selected for Development` and no `To Do` at all is
      normal. Point `STATUS_TODO` at the status new issues actually land in.
- [ ] **You have a Jira API token.** Create it at
      [id.atlassian.com → API tokens](https://id.atlassian.com/manage-profile/security/api-tokens).
      Use a **plain API token** — Basic auth on the `*.atlassian.net` domain (which `jira.sh` uses) rejects scoped tokens. If you must use a scoped token via the REST gateway, see
      [JIRA-REST.md](JIRA-REST.md) for the required scopes and URL changes.
- [ ] **Per-role Jira accounts (required)** — an email **and** a token for each
      of the assigner, executor and reviewer, so the board shows who did what.
      There is no default account behind them; point all three pairs at the
      same Atlassian account if you'd rather not split them.

## Project

- [ ] **A `.jst/` folder exists at your project root.** Both settings files
      live inside it, and it is the only location the skills read — a copy at
      the root itself is ignored. The healthcheck's `jst_dir` row FAILs before
      every other check when it's missing.
- [ ] **`.jst/jira-sdlc-tools.env` exists** — team-shared
      settings, committed. Copy
      [`.jst/jira-sdlc-tools.env`](../../../.jst/jira-sdlc-tools.env) from this
      repo and fill in the blanks.
- [ ] **`.jst/jira-sdlc-tools.local.env` exists** —
      machine-specific settings *and secrets*. Copy
      [`.jst/jira-sdlc-tools.local.env.example`](../../../.jst/jira-sdlc-tools.local.env.example).
- [ ] **`.jst/jira-sdlc-tools.local.env` is gitignored.** It holds your raw Jira
      token and GitHub PAT, so committing it leaks both. The rule goes *inside*
      `.jst/`, not in your root `.gitignore` — it then travels with any copy of
      the folder, so a worktree that gets `.jst/` gets the protection with it:
      ```bash
      echo 'jira-sdlc-tools.local.env' >> .jst/.gitignore
      git check-ignore -v .jst/jira-sdlc-tools.local.env   # prints the rule if ignored
      ```
      The healthcheck's `env_local_ignored` row checks this too — but it checks
      it *after* the file already exists, so do it in this order.
- [ ] **`WORKTREES_DIR` is an absolute path** — a sibling of your repo is the
      sensible place, but write it out in full, e.g.
      `/home/you/src/myapp-worktrees`. A relative value means a different
      directory depending on which checkout a skill runs from, so the
      healthcheck FAILs on one. Every issue gets its own worktree there.

## Settings files

Two files, both in the `.jst/` folder at **your project's** root — never in
this toolkit's. Every `<TOKEN>` in the skills resolves from them. Full per-variable reference:
[project-config.md](../skills/_shared/project-config.md).

**`.jst/jira-sdlc-tools.env`** — team-shared, committed:

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

**`.jst/jira-sdlc-tools.local.env`** — machine-specific, **gitignored**, holds
secrets:

```bash
# GITHUB SETTINGS (machine-specific)
WORKTREES_DIR=/home/you/src/myapp-worktrees
GITHUB_PAT_TOKEN="github_pat_…"

# JIRA SITE
JIRA_ACCOUNT_URL=your-site.atlassian.net

# PER-ROLE JIRA ACCOUNTS — all three required, each with its own email AND token
JIRA_ASSIGNER_EMAIL=assigner@example.com
JIRA_ASSIGNER_TOKEN=…
JIRA_EXECUTOR_EMAIL=executor@example.com
JIRA_EXECUTOR_TOKEN=…
JIRA_REVIEWER_EMAIL=reviewer@example.com
JIRA_REVIEWER_TOKEN=…
```

Two traps worth knowing: each `JIRA_<ROLE>_TOKEN` is the **raw token value**,
not a path to a file holding it — and there is no default account behind the
three roles, so a role missing either half stops the run rather than falling
back to somebody else's credential. (Pointing all three at one Atlassian
account is fine; just fill in all six values.)

## Verify it

Rather than re-reading the list, run the healthcheck from your **main
repository** — it's the same script the skills run before they do anything, and
it confirms both logins, your settings, and the platform in one pass. The
settings it reads are documented in
[project-config.md](../skills/_shared/project-config.md); what it does to log
`gh` in, and why that session lasts the whole conversation, is in
[What the healthcheck does](github/GH-PAT-SESSION-LOGIN.md#what-the-healthcheck-does).

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

Both are plain and dependency-free: they read config and check auth, and the
only thing either writes is `.jst/jira-sdlc-tools.local.env`, copied into a worktree
from your main checkout when it's missing. If you already have the plugin
installed, run your local copy instead of downloading:
`bash <path-to-plugin>/skills/_shared/scripts/posix/statuscheck.sh --role executor`.

It prints one table and exits non-zero if anything is broken. The rows that map
onto this checklist:

| Row | Covers |
|---|---|
| `jst_dir` | the `.jst/` settings folder exists at the repo root |
| `git_repo` | you're in a git repository |
| `env_config` | `.jst/jira-sdlc-tools.env` found and parsed |
| `env_local` | `.jst/jira-sdlc-tools.local.env` found |
| `env_local_ignored` | the local env file is gitignored |
| `gh_auth` | `GITHUB_PAT_TOKEN` logs `gh` in — a login, and nothing more |
| `gh_repo_access` | that PAT can actually see the repo `origin` points at (`gh api repos/<OWNER>/<REPO>`) |
| `jira_auth` | the `--role` you passed authenticates — `jira.sh --role <role> whoami` |
| `jira_project` | `PROJECT_KEY` resolves to a real Jira project |
| `base_branch` | `DEFAULT_BASE_BRANCH` is set |
| `worktrees_dir` | `WORKTREES_DIR` is absolute (FAIL if not) and exists (WARN if missing — the assigner won't create it) |
| `branch_pair` | `DEFAULT_BASE_BRANCH` and `PRODUCTION_BRANCH` are two *different* branches |

Every FAIL row prints its own remedy line under the table. Relay those rather
than guessing — and note the checklist items the script *can't* see: whether
your four `STATUS_*` names are the ones your board actually uses (the two
`raw GET` calls above answer that, and `/jira-sdlc:jst-install` §3d proves the
transitions too), and whether your two branches are the ones you meant.
