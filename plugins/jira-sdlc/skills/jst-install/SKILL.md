---
name: jst-install
description: Guided first-time setup of the jira-sdlc plugin in your own project. Walks the four sections of docs/STEP-BY-STEP.md in order — local tooling, GitHub repo preparation, Jira board preparation, healthcheck — and verifies each one with the bundled statuscheck script before moving to the next, so a missing `development` branch or a misspelled status name surfaces at setup instead of mid-run. Writes the team-shared `.jst/jira-sdlc-tools.env` for you; never reads or writes the secrets in `.jst/jira-sdlc-tools.local.env` — it tells you which file to copy and which keys to fill in by hand. Run it once per project, from the project root, before the first `jira-task-assigner` run.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, AskUserQuestion
---

You are walking a new user through first-time setup of this plugin **in their
own project**. Everything below follows `../../docs/STEP-BY-STEP.md` — same four
sections, same order — with a verification gate between each, which is the
whole point: the prose docs let someone work the whole list and only discover at
the first real run that the board has no `In Review` column.

Re-running this later — after a token rotation, a branch rename, a half-finished
first attempt — is normal and safe. Finding `.jst/` already populated means
confirm what's there and move on, not start over: every write below is
create-if-missing or an overwrite of a value the user just confirmed, and
`.jst/jira-sdlc-tools.local.env` is never touched once it exists.

**Conventions used below:**
- Run from the **project root of the repo the user will build features in** —
  not a clone of this toolkit itself, which is the easy mistake: the skills read
  config from *your project's* root. If `git remote get-url origin` names
  `jira-sdlc-tools`, you're in the toolkit clone — stop and ask.
- **`CLAUDE_PLUGIN_ROOT`** is this plugin's root; every script path below hangs
  off it. If it isn't set — reading this skill on a non-Claude client — resolve
  it against the platform's skills folder, keeping `../_shared/scripts/posix/`
  relative to this skill as the default.
- **Script dispatch — settle it before the first script call.** Every script
  ships twice: POSIX `…/scripts/posix/X.sh` and the Windows twin
  `…/scripts/win/X.ps1` (identical args, output, exit codes). Pick the branch
  from your own runtime now — you know your OS without running anything — and
  use it throughout. The blocks below are the POSIX form.
- **`<TOKEN>`s** (`<PROJECT-KEY>`, `<DEFAULT_BASE_BRANCH>`, `<STATUS_*>`, …)
  are what you are *collecting* here; they don't exist yet. Every one of them
  is described in `../_shared/project-config.md`.
- **`../../docs/…` paths** point inside the plugin, and a drop-in install that
  copied only `skills/` won't have them. They're reading material rather than
  inputs, so nothing breaks — just cite the GitHub copy under
  `kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/docs/` instead.
- **Ask, don't assume.** A project key, a status name and a branch name are
  facts about the user's Jira and GitHub, not defaults you can derive. Use
  AskUserQuestion, offering the documented default as one option.

## The two env files — the rule that shapes this whole skill

| file | what's in it | what you may do |
|---|---|---|
| `.jst/jira-sdlc-tools.env` | project key, branch names, the four status names — **committed, secret-free** | **Write it directly.** Create it, edit it, read it back freely |
| `.jst/jira-sdlc-tools.local.env` | `WORKTREES_DIR`, `JIRA_ACCOUNT_URL`, **plus three Jira role tokens and a GitHub PAT** | **Never open it and never edit it.** Copy the `.example` into place when it's absent, then hand the user the key list and wait |

One `cat` of the second file writes four live credentials into the transcript,
and a redaction filter doesn't save you — `sed 's/=.*TOKEN.*/…/'` matches
nothing here (the word `TOKEN` is *before* the `=`), exits 0, and leaks
silently. So the user fills that file in by hand, in their editor; you supply
the path, the key list, and the docs link. `../_shared/project-config.md`
§ *Reading config safely* is the full version.

## Verification: statuscheck, read backwards

Each section ends by running the same script the three skills run:

```bash
STATUSCHECK_RERUN='rerun /jira-sdlc:jst-install' \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role executor
```

Call that **the gate command**; the sections below say "run the gate" rather
than repeating it. Keep the `STATUSCHECK_RERUN` override on every call — its
default ends each remedy line with "…then rerun `/jira-sdlc:jira-task-executor`",
sending a half-installed user to the skill that can't run yet.

For the other skills a FAIL means *stop*. **Here a FAIL is the worklist** —
mid-install most rows are supposed to be red, and the run ends when they
aren't. Two consequences worth knowing before you're surprised by them:

- It exits non-zero while rows are still failing. Expected. Don't treat the
  exit code as a broken environment.
- A missing `.jst/` folder aborts it after one row, before every other check.
  That's why section 1 creates `.jst/` early — until it exists the script can't
  tell you anything else.

Check only the rows that section owns; a later section's rows are still red on
purpose, and saying so keeps the user from chasing them:

| section | rows this section settles (OK, or INFO where the row has no OK form) | rows still expected to fail |
|---|---|---|
| 1 · tooling & scaffold | `jst_dir`, `env_local`, `env_local_ignored`, `platform` (OK on Windows, INFO on POSIX) | `env_config`, `gh_auth`, `jira_*` |
| 2 · GitHub | `gh_auth`, `git_repo`, `base_branch`, `worktrees_dir` | `jira_auth`, `jira_project` |
| 3 · Jira | `env_config`, `jira_auth`, `jira_project` | — |
| 4 · healthcheck | every row, for all three roles | — |

`worktree`, `branch`, `branch_project`, `issue_key`, `parent_branch`,
`working_tree` and `bootstrap` are about *running an issue*, not installing.
Ignore them here — a main checkout on the base branch with no issue key is
exactly right for this skill.

---

## Section 1 · Local tooling and the `.jst/` scaffold

**1a. Check the CLIs.** `git` and `gh` on every platform; `jq` additionally on
Linux/macOS (the bash scripts can't parse JSON without it), `python3`
recommended. Windows needs `pwsh` 7+ or `powershell` 5.1 instead — its ports
parse JSON natively, so `jq` isn't needed there. There is nothing to install
for Jira: the plugin ships its own REST client, `jira.sh` / `jira.ps1`.

```bash
git --version && gh --version && jq --version && python3 --version
```
```powershell
git --version; gh --version; $PSVersionTable.PSVersion
```
`&&` stops at the first missing tool and names it; PowerShell's `;` runs all of
them, so scan for the one that errored. Report what's missing with its install
URL (`../../docs/FULL-SETUP-CHECKLIST.md` § *Your PC* has them) and stop until
the user has it — the later sections all shell out to these.

**1b. Create the scaffold.** From the project root:

```bash
mkdir -p .jst
grep -qxF '.jst/jira-sdlc-tools.local.env' .gitignore 2>/dev/null \
  || echo '.jst/jira-sdlc-tools.local.env' >> .gitignore
[ -f .jst/jira-sdlc-tools.local.env ] \
  || cp "${CLAUDE_PLUGIN_ROOT}/skills/_shared/templates/jira-sdlc-tools.local.env.example" \
        .jst/jira-sdlc-tools.local.env
```

Gitignore *first*, then create the file: the order matters because a file
created first can be caught by a `git add -A` in the gap, and the
`env_local_ignored` row only checks a file that already exists.

That `[ -f ]` guard is load-bearing — **an existing local.env is never
overwritten**, since replacing a filled-in one costs the user four live
credentials. The template it copies is placeholders only, which is what makes
this the one safe write into that file; it ships inside `_shared/` rather than
being read from the toolkit repo's own `.jst/` precisely so the path survives
both install modes.

**1c. Hand the file over.** Tell the user to open
`.jst/jira-sdlc-tools.local.env` in their editor and fill in, by hand:

- `WORKTREES_DIR` — a sibling directory of this repo, e.g. `../myapp-worktrees`
  (section 2 creates it)
- `JIRA_ACCOUNT_URL` — their Cloud site, `your-site.atlassian.net`, no scheme
- `GITHUB_PAT_TOKEN` — a fine-grained PAT with **Contents: read/write** and
  **Pull requests: read/write** on this repo. Where to click:
  `../../docs/github/GH-PAT-SESSION-LOGIN.md`
- the six per-role Jira variables —
  `JIRA_{ASSIGNER,EXECUTOR,REVIEWER}_{EMAIL,TOKEN}`, tokens created at
  [id.atlassian.com → API tokens](https://id.atlassian.com/manage-profile/security/api-tokens).
  Each is the raw token **value**, never a path to a file holding it. All six
  are required and there is no default account behind them; pointing all three
  roles at one Atlassian account is fine, just say so in all three pairs. Three
  separate accounts is what makes the board show who did what.

Then **wait** for them to say it's filled in, and don't run the gate before they
do. The template ships a *non-empty placeholder* PAT, and statuscheck logs `gh`
out before logging in with whatever it finds — so gating early doesn't merely
fail a row, it costs the user the `gh` session they already had, with nothing
restored afterwards. You can't inspect their work either (this is the file you
don't open), which is why the `gh_auth` and `jira_auth` rows in the next two
sections are the real verification.

**1d. Gate.** Run the gate. Expect `jst_dir`, `platform`, `env_local` and
`env_local_ignored` OK; everything else red for now.

---

## Section 2 · GitHub repository preparation

The skills assume Gitflow (`../../docs/SDLC.md`): they never invent branch
names, they follow the policy. Two long-lived branches are yours to create —
`PRODUCTION_BRANCH` (releases land here, default `main`) and
`DEFAULT_BASE_BRANCH` (feature work branches from and merges back into it,
default `development`). The skills create `feature/<KEY>-<slug>` and
`hotfix/<KEY>-<slug>` themselves, one per issue.

**2a. Find out what exists** — `git branch -a` plus
`git remote get-url origin`. The base branch is the one people are missing: a
repo with only `main` gives the assigner nowhere to branch from.

**2b. Create the base branch if it's absent.** Ask first — this pushes a new
branch and changes the repo default, which is outward-facing and other people
see it:

```bash
git switch main && git switch -c development && git push -u origin development
gh repo edit <OWNER>/<REPO> --default-branch development
```

Substitute the two names the user confirmed — `main`/`development` are this
plugin's documented defaults, not a naming rule, and a repo using `master` or
`develop` keeps its own names in the env file.

Mention that protecting both branches is recommended — everything reaches them
through a reviewed PR, which is the flow the skills already produce — but don't
do it for them.

**2c. Create the worktrees directory** the user pointed `WORKTREES_DIR` at in
1c — a sibling of this repo, e.g. `mkdir -p ../myapp-worktrees`. You don't know
the path they typed, and this is the moment the forbidden file looks most
tempting: don't open it, read the path off the `worktrees_dir` row of the gate
you already ran in 1d, which prints it resolved for exactly this reason. The
directory must exist before the assigner runs — it refuses to create one, so a
missing directory is a first-run failure rather than a self-repair.

**2d. Record both branches** in the team-shared file — this one you write
yourself, so create `.jst/jira-sdlc-tools.env` now with the two confirmed
names (section 3 adds the Jira half):

```
DEFAULT_BASE_BRANCH=development
PRODUCTION_BRANCH=main
```

**2e. Gate.** Run the gate. `gh_auth` is the real test of the PAT from 1c —
the script logs `gh` out and back in with it, so a FAIL here means the token,
not the CLI. `base_branch` should now read what 2d wrote, and `worktrees_dir` the
directory 2c created. `jira_*` stays red; say so, so nobody goes looking.

---

## Section 3 · Jira board preparation

**3a. The board.** The user needs a Jira Cloud project and a board. This plugin
was tested against a plain **Kanban** board with its default columns — that's
the known-good setup; Scrum and custom workflows should work provided 3b holds,
but they aren't what was exercised.

**3b. Collect the project key and the four status names.** The key is the
prefix on every issue (`PROJ` in `PROJ-123`), and it's what the skills match
branch names against, so a branch for the wrong project gets caught instead of
worked. The four statuses are matched **literally** — `In progress` and
`In Progress` are different statuses — so ask the user to copy them exactly as
the board spells them, offering the Kanban defaults as the likely answer:

| variable | default | who moves the card there |
|---|---|---|
| `STATUS_TODO` | `To Do` | `jira-task-assigner`, on issues it creates |
| `STATUS_IN_PROGRESS` | `In Progress` | `jira-task-executor`, when it starts |
| `STATUS_IN_REVIEW` | `In Review` | `jira-task-executor`, when its PR opens |
| `STATUS_DONE` | `Done` | the reviewer's closing offer, GitHub-for-Jira on merge, or by hand |

`In Review` is the one that's usually missing — several Jira templates ship
`To Do` / `In Progress` / `Done` only. Either add the column, or point
`STATUS_IN_REVIEW` at whatever the board calls that stage.

**3c. Append them** to `.jst/jira-sdlc-tools.env`:

```
PROJECT_KEY=PROJ
STATUS_TODO=To Do
STATUS_IN_PROGRESS=In Progress
STATUS_IN_REVIEW=In Review
STATUS_DONE=Done
```

Those are the defaults to *offer*, not values to copy: write the key and the
four names the user confirmed in 3b. A literal `PROJECT_KEY=PROJ` left in a real
project's config fails on the first branch-name check the skills make.

**3d. Prove a status name rather than trusting it.** A name that doesn't exist
fails the transition at runtime — mid-task, after work is committed — so spend
one call proving it now. Ask the user for a throwaway issue key on the board
and transition it, then put it back:

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
bash "$S/jira.sh" --role executor issue transition <KEY> --to "In Review"
```

A wrong name fails here, at setup, where the cost is one retyped string. Then
move the issue back where it was, if the workflow allows that transition — some
don't, which is a fact about the board and not a problem to solve here. This
doubles as the first real end-to-end test of the executor credential. If the
user has no disposable issue, say plainly that the status names are unverified
and move on — that's a warning, not a blocker.

**3e. Gate.** Run the gate. `env_config`, `jira_auth` and `jira_project`
should all be OK now.

---

## Section 4 · Full healthcheck

**4a. Run it once per role**, because auth is role-scoped and per-request —
each role has its own credential pair, and only the row for the `--role` you
passed proves anything about it. A pair that's missing its email half, or a
token pasted into the wrong variable, shows up here and nowhere earlier:

```bash
for r in assigner executor reviewer; do
  STATUSCHECK_RERUN='rerun /jira-sdlc:jst-install' \
    bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role "$r"
done
```

**4b. Read the result.** Every row should be OK or INFO. The install-irrelevant
rows named in the row map stay INFO, and `worktrees_dir` may WARN if the user
skipped 2c. For anything still FAILing, relay the script's own remedy line
rather than improvising — and name the two things the script structurally
cannot see: whether the board really has the `In Review` column (3d is the only
proof), and whether the two branch names in the env file are the branches the
user actually meant.

**4c. Hand off.** Setup is done. Tell them the loop from here:

```
/jira-sdlc:jira-task-assigner "<describe the work>"   # from this checkout, on the base branch
/jira-sdlc:jira-task-executor                         # from inside each worktree it creates
/jira-sdlc:jira-task-reviewer                         # from the parent issue's worktree
```


Reference: `../../docs/STEP-BY-STEP.md` (the prose walkthrough this skill
follows), `../../docs/FULL-SETUP-CHECKLIST.md` (the same ground as a tickable
list, with each item's "how to check it"), `../_shared/project-config.md`
(every variable in both env files), `../../docs/SDLC.md` (the branching policy).
