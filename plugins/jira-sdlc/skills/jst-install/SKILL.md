---
name: jst-install
description: Guided first-time setup of the jira-sdlc plugin in your own project. Walks the four sections of https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step in order — local tooling, GitHub repo preparation, Jira board preparation, healthcheck — and verifies each one with the bundled statuscheck script before moving to the next, so a missing `development` branch or a misspelled status name surfaces at setup instead of mid-run. Writes the team-shared `.jst/jira-sdlc-tools.env` for you; never reads or writes the secrets in `.jst/jira-sdlc-tools.local.env` — it tells you which file to copy and which keys to fill in by hand. Run it once per project, from the project root, before the first `jira-task-assigner` run.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, AskUserQuestion
---

You are walking a new user through first-time setup of this plugin **in their
own project**. Everything below follows https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step — same four
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
  `jira-sdlc-tools`, you're in the toolkit clone — stop and ask. If that command
  *errors* instead, there is no origin at all: that's 1a's gate, not this one.
- **`CLAUDE_PLUGIN_ROOT`** is this plugin's root; every script path below hangs
  off it. If it isn't set (a non-Claude client), resolve the root yourself, in
  order: (1) this skill's own directory — given at the top of the loaded
  SKILL.md, or the folder containing it — so the scripts are at
  `../_shared/scripts/posix/` relative to it (correct on every platform); (2)
  if you can't derive that, probe the platform's default skills locations —
  project-root `.agent/skills/`, `.agents/skills/`, `.codex/skills/`,
  `.opencode/skills/`, `.claude/skills/`, `.grok/skills/`, the home global
  `~/.claude/skills/`, or the path named in the platform's config
  (`kilo.jsonc`, `settings.json`, `config.toml`). See INTEGRATIONS.md →
  "Locating the shared scripts".
- **Script dispatch — settle it before the first script call.** Every script
  ships twice: POSIX `…/scripts/posix/X.sh` and the Windows twin
  `…/scripts/win/X.ps1` (identical args, output, exit codes). Pick the branch
  from your own runtime now — you know your OS without running anything — and
  use it throughout. The blocks below are the POSIX form.
- **`<TOKEN>`s** (`<PROJECT-KEY>`, `<DEFAULT_BASE_BRANCH>`, `<STATUS_*>`, …)
  are what you are *collecting* here; they don't exist yet. Every one of them
  is described in `../_shared/project-config.md`.
- **Doc references are published-site URLs** under `https://kantorv.github.io/jira-sdlc-tools/docs/`, never plugin-relative
  paths: the docs live at the repo root and a marketplace install copies only the
  plugin, so nothing here can reach them on disk. They're reading material rather
  than inputs — cite the URL and carry on.
- **Ask, don't assume.** A project key, a status name and a branch name are
  facts about the user's Jira and GitHub, not defaults you can derive. Use
  AskUserQuestion, offering the documented default as one option — and where
  the API can list the *real* options instead (section 3b), offer those.

## The two env files — the rule that shapes this whole skill

| file | what's in it | what you may do |
| -- | -- | -- |
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
| -- | -- | -- |
| 1 · tooling & scaffold | `jst_dir`, `env_local`, `env_local_ignored`, `platform` (OK on Windows, INFO on POSIX) | `env_config`, `gh_auth`, `gh_repo_access`, `jira_*` |
| 2 · GitHub | `gh_auth`, `gh_repo_access`, `git_repo`, `base_branch`, `branch_pair`, `worktrees_dir` | `jira_auth`, `jira_project` |
| 3 · Jira | `env_config`, `jira_auth`, `jira_project` | — |
| 4 · healthcheck | every row, for all three roles | — |

`worktree`, `branch`, `branch_project`, `issue_key`, `parent_branch`,
`working_tree` and `bootstrap` are about *running an issue*, not installing.
Ignore them here — a main checkout on the base branch with no issue key is
exactly right for this skill.

______________________________________________________________________

## Section 1 · Local tooling and the `.jst/` scaffold

**1a. Check the CLIs *and the repository*.** `git` and `gh` on every platform; `jq` additionally on
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
URL (https://kantorv.github.io/jira-sdlc-tools/docs/full-setup-checklist § *Your PC* has them) and stop until
the user has it — the later sections all shell out to these.

Then check the prerequisite this skill **cannot create for them** — a git repo
with a GitHub remote attached:

```bash
git rev-parse --show-toplevel && git remote get-url origin
```

Either one failing is a **stop**, and it has to happen here, before 1b: `mkdir -p .jst`, the `.jst/.gitignore` write and the template copy all succeed happily in
whatever directory the user is standing in, and they'd only find out at 1d —
with a stray half-scaffold left behind. Say plainly what's missing: a GitHub
repository, created and then cloned (or `git init` plus
`git remote add origin git@github.com:<OWNER>/<REPO>.git`). This skill wires an
existing repo and an existing Jira board together; it makes neither.

**1b. Create the scaffold.** From the project root:

```bash
mkdir -p .jst
grep -qxF 'jira-sdlc-tools.local.env' .jst/.gitignore 2>/dev/null \
  || echo 'jira-sdlc-tools.local.env' >> .jst/.gitignore
[ -f .jst/jira-sdlc-tools.local.env ] \
  || cp "${CLAUDE_PLUGIN_ROOT}/skills/_shared/templates/jira-sdlc-tools.local.env.example" \
        .jst/jira-sdlc-tools.local.env
```

Gitignore *first*, then create the file: the order matters because a file
created first can be caught by a `git add -A` in the gap, and the
`env_local_ignored` row only checks a file that already exists.

The rule goes in **`.jst/.gitignore`**, never the project's root `.gitignore`:
the ignore then lives inside the folder it protects and travels with any copy
of `.jst/` — into a worktree, for instance — instead of being a second thing to
remember, and a `.gitignore` the team already curates is left alone. Statuscheck's
`env_local_ignored` row calls `git check-ignore`, which doesn't care which file
the rule came from. Appending rather than overwriting keeps a rule the user
added there themselves.

That `[ -f ]` guard is load-bearing — **an existing local.env is never
overwritten**, since replacing a filled-in one costs the user four live
credentials. The template it copies is placeholders only, which is what makes
this the one safe write into that file; it ships inside `_shared/` rather than
being read from the toolkit repo's own `.jst/` precisely so the path survives
both install modes.

**1c. Hand the file over.** Tell the user to open
`.jst/jira-sdlc-tools.local.env` in their editor and fill in, by hand:

- `WORKTREES_DIR` — an **absolute** path, e.g. `/home/you/src/myapp-worktrees`
  (a sibling of this repo is the sensible place; section 2 creates it). A
  relative value means a different directory depending on which checkout a
  skill runs from, so the gate FAILs on one
- `JIRA_ACCOUNT_URL` — their Cloud site, `your-site.atlassian.net`, no scheme
- `GITHUB_PAT_TOKEN` — a fine-grained PAT with **Contents: read/write** and
  **Pull requests: read/write** on this repo. Where to click:
  https://kantorv.github.io/jira-sdlc-tools/docs/gh-pat-session-login
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

______________________________________________________________________

## Section 2 · GitHub repository preparation

The skills assume Gitflow (https://kantorv.github.io/jira-sdlc-tools/docs/sdlc): they never invent branch
names, they follow the policy. Two **distinct** long-lived branches are yours to
create — `PRODUCTION_BRANCH` (releases land here, default `main`) and
`DEFAULT_BASE_BRANCH` (feature work branches from and merges back into it,
default `development`). The skills create the per-issue work branches
themselves, one per issue, prefixed `feature/`, `bugfix/`, `chore/` or
`hotfix/` according to what the work is
(https://kantorv.github.io/jira-sdlc-tools/docs/sdlc §2).

**A single-branch repo is not a configuration this plugin supports**, so never
offer one: collapse the pair and the assigner's planned path and its hotfix path
(step 5C) resolve to the same branch — every feature PR targets production, and
the emergency route stops being distinguishable from ordinary work — while the
release workflows, which key the version off `release/sprint-<X.Y.Z>` and
`hotfix/*` branch names and deliberately off nothing else, so that a `feature/`,
`bugfix/` or `chore/` merge never tags a release
(https://kantorv.github.io/jira-sdlc-tools/docs/sdlc §5), have nothing left to
key on.
When a repo has only `main`, the open question is what the *second* branch is
called, never whether to have one. Ask-don't-assume still holds for the names —
`development` is the documented default, `develop`/`staging`/anything else is
fine — but the choice on offer is two names, never one.

**2a. Find out what exists** — `git branch -a` plus
`git remote get-url origin`. The base branch is the one people are missing: a
repo with only `main` gives the assigner nowhere to branch from.

**2b. Create the base branch if it's absent** — not optional, per the rule
above; only its name is the user's call. Ask first anyway, because this pushes a
new branch and changes the repo default, which is outward-facing and other
people see it:

```bash
git switch main && git switch -c development && git push -u origin development
gh repo edit <OWNER>/<REPO> --default-branch development
```

Substitute the two names the user confirmed — `main`/`development` are this
plugin's documented defaults, not a naming rule, and a repo using `master` or
`develop` keeps its own names in the env file. A `404` from `gh repo edit` is
almost never a wrong repo name: it's the PAT that can't see this repository,
the same cause `gh_repo_access` names in 2e — fix the token's repository
access rather than retyping `<OWNER>/<REPO>`.

Mention that protecting both branches is recommended — everything reaches them
through a reviewed PR, which is the flow the skills already produce — but don't
do it for them.

**2c. Create the worktrees directory** the user pointed `WORKTREES_DIR` at in
1c — `mkdir -p` the absolute path they gave (a sibling of this repo is the
usual choice). You don't know the path they typed, and this is the moment the
forbidden file looks most tempting: don't open it, read the path off the
`worktrees_dir` row of the gate you already ran in 1d. If that row FAILed on a
relative value, its remedy line carries the absolute form — relay it and have
them fix the file before creating anything, since the relative path would
create the directory in the wrong place. The
directory must exist before the assigner runs — it refuses to create one, so a
missing directory is a first-run failure rather than a self-repair.

**2d. Record both branches** in the team-shared file — this one you write
yourself, so create `.jst/jira-sdlc-tools.env` now with the two confirmed
names (section 3 adds the Jira half):

```
DEFAULT_BASE_BRANCH=development
PRODUCTION_BRANCH=main
```

**2e. Gate.** Run the gate. Two rows cover the PAT from 1c and they prove
different things: `gh_auth` only proves a **login** succeeded, while
`gh_repo_access` calls `gh api repos/<OWNER>/<REPO>` and is the one that proves
the PAT can do the executor's job. A fine-grained token scoped to *selected
repositories* logs in green, reads the org, and still 404s on this repo — 404,
not 403, so it reads like a typo — and with an SSH `origin` nothing breaks until
`gh pr create` fails mid-task. On a FAIL there, relay the row's remedy: add the
repo at github.com/settings/personal-access-tokens, keeping Contents and Pull
requests at read/write, and expect org-owned repos to need admin approval.
`base_branch`/`production_branch` should now read what 2d wrote, with
`branch_pair` OK — it FAILs if those two names are equal — and `worktrees_dir`
the directory 2c created. `jira_*` stays red; say so, so nobody goes looking.

______________________________________________________________________

## Section 3 · Jira board preparation

**3a. The board.** The user needs a Jira Cloud project and a board. This plugin
was tested against a plain **Kanban** board with its default columns — that's
the known-good setup; Scrum and custom workflows should work provided 3b holds,
but they aren't what was exercised.

**3b. Read the project key and the four status names off the board, don't ask
for them from memory.** Both are facts about the user's Jira, and the plugin
already ships a client that can fetch them (`raw` is `jira.sh`'s escape hatch;
paths are under `/rest/api/3` — `../_shared/jira-api-reference.md`). Fetching
beats asking here because statuses are matched **literally** at runtime
(`In progress` and `In Progress` are different statuses) *and* because the
documented defaults are often simply absent: the first real install hit a board
whose statuses were `Backlog`, `Selected for Development`, `In Progress`,
`In Review`, `Done` — no `To Do` at all, so the documented default for
`STATUS_TODO` named a status that did not exist. Discovery removes that whole
class of wrong value instead of warning about it.

Four steps, **in this order** — the statuses call is per-project, so it cannot
happen until the key is settled.

**STEP 1 — fetch the projects this credential can see.**

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
bash "$S/jira.sh" --role executor raw GET /project/search \
  | jq -r '.values[] | "\(.key)\t\(.name)\t\(.projectTypeKey)/\(.style)"'
```

**STEP 2 — show that list and ask which project to wire this repo to.** One
AskUserQuestion option per project, labelled with the key, carrying name and
`type/style` in the description so two similarly named projects stay
distinguishable. This is the user's decision: **do not auto-select**, and do not
silently narrow the list — not even when one project's name closely matches the
repository's (on the first run `SUB` / `sublimationapp-mgmt-repo-v3`
*recommending* it was right; skipping the question would not have been). Many
visible projects → still show them rather than asking for a typed key; exactly
one → confirm it rather than assuming it.

**STEP 3 — only now, fetch the chosen project's statuses**, de-duplicated across
its issue types:

```bash
bash "$S/jira.sh" --role executor raw GET /project/<CHOSEN-KEY>/statuses \
  | jq -r '[.[].statuses[].name] | unique | .[]'
```

One call, for the one project that was chosen — don't fetch statuses for every
visible project up front.

**STEP 4 — ask the user to map each `STATUS_*` onto a name from that list.** The
options are the board's real statuses, so a name that doesn't exist can no
longer be chosen. Offer the closest documented default *first*, as an ordering
hint — never as the answer:

| variable | documented default | who moves the card there |
| -- | -- | -- |
| `STATUS_TODO` | `To Do` | no skill does — it names where new issues land, and it's the only status the optional branch-create Action will advance *from* |
| `STATUS_IN_PROGRESS` | `In Progress` | `jira-task-executor`, when it starts |
| `STATUS_IN_REVIEW` | `In Review` | `jira-task-executor`, when its PR opens |
| `STATUS_DONE` | `Done` | the reviewer's closing offer, GitHub-for-Jira on merge, or by hand |

A board with no match for a default is a **normal case**, not an error — so
present what the choice costs rather than just listing names. On that first run
`STATUS_TODO` had to become `Backlog` or `Selected for Development`, and the two
aren't equivalent: one is a holding area, the other the ready-to-be-worked
column. The one to pick is the status newly created issues actually land in,
since that's where the executor takes work from. The "who moves the card there"
column above is what makes that legible — keep it in front of the user. The
first run did, and the user chose `Backlog` knowingly.

**If a fetch fails** — the credential sees no projects, or the statuses call
errors — say so and fall back to asking the user to type the value by hand.
Discovery is the better path, not a hard dependency.

**But a fallback is a different *way* to get the answer, never a way to proceed
without one.** No project chosen at STEP 2 — declined, an answer that isn't one
of the listed keys, or an empty type-in — **halts this section**: say what's
missing and wait. Don't guess a key from the repository name, don't settle for
the single project that happened to be visible, don't write a placeholder into
`.jst/jira-sdlc-tools.env`, and don't advance to STEP 3 or to section 4. Every
downstream skill matches branch names against this key, so a guessed one doesn't
fail here — it fails later, as branches that belong to the wrong project. An
unanswered mapping at STEP 4 halts the same way instead of quietly taking the
documented default, which is exactly what the first run proved can be missing
from the board.

**3c. Append them** to `.jst/jira-sdlc-tools.env`:

```
PROJECT_KEY=PROJ
STATUS_TODO=To Do
STATUS_IN_PROGRESS=In Progress
STATUS_IN_REVIEW=In Review
STATUS_DONE=Done
```

That block is the *shape*, not the values: write the key the user chose at STEP
2 and the four names they mapped at STEP 4. A literal `PROJECT_KEY=PROJ` left in
a real project's config fails on the first branch-name check the skills make.

**3d. Prove the config against the real workflow.** 3b's names exist on the
board, but nothing has yet shown that the *workflow* permits the transitions the
skills make, or that the credentials can create and delete. One scratch issue
proves all of it — and unlike transitioning a borrowed issue, it doesn't depend
on a disposable one already existing.

**Ask first.** This touches a live board: a card appears and disappears,
teammates may see it, notifications may fire. Offer the alternatives — create a
scratch issue (the default), transition a disposable key the user names and put
it back, or skip. Don't create issues on someone's board unannounced.

On a yes, walk the **configured** names from 3c — not the documented defaults;
the point is to test the config, not the documentation:

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
KEY=$(bash "$S/jira.sh" --role assigner issue create --project <PROJECT-KEY> \
        --type Task --summary 'jst-install smoke test — safe to delete')
for s in "<STATUS_TODO>" "<STATUS_IN_PROGRESS>" "<STATUS_IN_REVIEW>" "<STATUS_DONE>"; do
  if bash "$S/jira.sh" --role executor issue transition "$KEY" --to "$s"
    then echo "allowed: $s"; else echo "not offered from the current status: $s"; fi
done
bash "$S/jira.sh" --role assigner issue delete "$KEY" --with-subtasks
bash "$S/jira.sh" --role executor issue view "$KEY" --fields summary
echo "deleted if that exited 4 (HTTP 404): $?"
```

(Use an issue type the project actually has if it has no `Task`.) That proves
the four names, every transition the workflow really permits, the assigner
credential via create/delete and the executor credential via transition.

Two things to get right when reading the output:

- **A refused transition is a fact about the board, not a setup error.** Report
  which ones the workflow allows and move on. The first name in the loop is
  often the status the issue was created in already, and workflows legitimately
  restrict which statuses reach which.
- **Verify the delete instead of trusting it.** `delete` prints nothing on
  success, so the follow-up `view` is the proof — exit 4 / HTTP 404 means gone.
  A scratch card left behind on a real board is this step's failure mode.

If the user skips, say plainly that the status names and the workflow are
unverified and move on — that's a warning, not a blocker.

**3e. Gate.** Run the gate. `env_config`, `jira_auth` and `jira_project`
should all be OK now.

______________________________________________________________________

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
skipped 2c — it FAILs, though, if they wrote a relative `WORKTREES_DIR`, and
that one has to be fixed in the file. For anything still FAILing, relay the script's own remedy line
rather than improvising — and name the two things the script structurally
cannot see: whether the workflow permits the transitions the skills make (3b
proved the names exist; 3d is the only proof of the transitions), and whether
the two branch names in the env file are the branches the user actually meant.

**4c. Hand off.** Setup is done. Tell them the loop from here:

```
/jira-sdlc:jira-task-assigner "<describe the work>"   # from this checkout, on the base branch
/jira-sdlc:jira-task-executor                         # from inside each worktree it creates
/jira-sdlc:jira-task-reviewer                         # from the parent issue's worktree
```

**4d. Name what's still uncommitted — and offer it as the first task.** The
whole `.jst/` folder is untracked: `jira-sdlc-tools.env` (2d and 3c wrote it —
team-shared, meant to be committed) and the `.gitignore` 1b put beside it. This
skill leaves them on purpose; they're the payload of the first task below. Say
so, because the consequence isn't one the user will predict — **a worktree cut
from `<DEFAULT_BASE_BRANCH>` is born without `.jst/` at all**, so the first
executor run FAILs statuscheck's `env_config` row there. `ensure_local_env.sh`
doesn't rescue it: it carries only the gitignored
`.jst/jira-sdlc-tools.local.env` over from the main checkout, and the tracked
files are git's job — git simply has nothing to carry yet.

Recommend committing them *as* this project's first real task, so the fix and
an end-to-end test of all three skills are the same run; committing the two
files by hand instead is a fine alternative, and setup is complete either way.
For the first-task route, hand them this to paste into a **new** Claude
session, run from the project root on `<DEFAULT_BASE_BRANCH>`:

```
/jira-sdlc:jira-task-assigner "JIRA-SDLC-TOOLS setup — a retroactive first
task, and this repo's first run of these skills. The plugin's config is
written but uncommitted: the whole .jst/ folder, holding jira-sdlc-tools.env
and a .gitignore covering jira-sdlc-tools.local.env. Create the issue, branch
and worktree as usual, then copy .jst/ into that worktree — the executor's job
is only to commit and push it, and the reviewer's is to confirm the settings
work. Copy the folder whole: the .gitignore inside it is what keeps
.jst/jira-sdlc-tools.local.env, which holds four live credentials, out of the
commit. Stage .jst/ explicitly rather than with 'git add -A'. Treat this run
as the smoke test that all three skills interact correctly."
```

"Copy the folder whole" is the load-bearing clause, and it's why 1b put the
rule inside `.jst/` in the first place: `git add .jst` then stages
`jira-sdlc-tools.env` and `.gitignore` and leaves `local.env` out on its own.
Copy across only the env file and that worktree ends up holding three Jira role
tokens and a GitHub PAT with nothing ignoring them.

Reference: https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step (the prose walkthrough this skill
follows), https://kantorv.github.io/jira-sdlc-tools/docs/full-setup-checklist (the same ground as a tickable
list, with each item's "how to check it"), `../_shared/project-config.md`
(every variable in both env files), https://kantorv.github.io/jira-sdlc-tools/docs/sdlc (the branching policy).
