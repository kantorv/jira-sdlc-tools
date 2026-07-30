---
name: jira-task-assigner
description: Turn a feature/task/bug description into Jira issues with matching git branches and worktrees, so the pieces can be worked on in parallel. Investigates the codebase, asks clarifying questions, decides whether the request is a single self-contained task or a multistep task split into parallel sub-tasks, and creates the issue(s) via the `jira.sh`/`jira.ps1` REST client. Every leaf issue (the single task, or each sub-task) gets its own dedicated branch and git worktree, so parallel work can start immediately and the executor always opens an individual PR per leaf. Branches are `feature/` off the default base branch; when the user explicitly asks for an emergency production fix it provisions a single-step `hotfix/` off the production branch instead.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are acting as a technical project manager for the **`<PROJECT-KEY>`**
project. Given a task description from the user ($ARGUMENTS):

**Conventions used below:**
- `<PROJECT-KEY>`, `<WORKTREES_DIR>`, `<DEFAULT_BASE_BRANCH>`,
  `<PRODUCTION_BRANCH>` — resolve these from `.jst/jira-sdlc-tools.env`
  (team-shared) and `.jst/jira-sdlc-tools.local.env` (machine-specific),
  both under the project root, before following the rest of this skill.
- `<WORKTREES_DIR>` — the directory where per-issue worktrees are created
  (see `../_shared/project-config.md`). It must already exist — this skill
  never `mkdir`s it; step 1's healthcheck (the `worktrees_dir` row)
  reports whether it's present.
- `<slug>` = short kebab-case summary of the issue title, same style as
  existing branches in this repo.
- **Branch prefix** — the prefix follows the **base branch, not the
  issue type** (`../_shared/jira-api-reference.md` §12; SDLC.md §2), so
  it falls out of step 5C's base decision and never out of picking `Bug`:
  branching from `<DEFAULT_BASE_BRANCH>` (`development`) → **`feature/`**,
  which covers all planned work, new features *and* bug fixes alike;
  branching from `<PRODUCTION_BRANCH>` (`main`) → **`hotfix/`**, the
  emergency production flow (SDLC.md §4) that step 5C only takes when the
  user asks for it outright.
  The prefix is uniform within a run — a Sub-task inherits its parent's —
  so branch naming is always `<PREFIX><KEY>-<slug>` whether `<KEY>` is the
  top-level issue or a Sub-task, which keeps the branch-parsing regex in
  step 2 working no matter which branch someone checks out later.
- `<PREFIX>`, `<BASE_BRANCH>`, `<BRANCH_FROM>` — set once by step 5C, used
  verbatim by step 6. An issue already created *without* this skill needs
  no decision here: provision it with the no-assigner bootstrap in
  `../_shared/jira-api-reference.md` §12 and go straight to the executor.

## 1. Discovery and healthcheck

**Script dispatch — settle this before running any script below.** Every
script this skill invokes ships twice: the POSIX `…/scripts/X.sh` and its
Windows twin `…/scripts/win/X.ps1` (PowerShell 5.1+; identical args, output,
exit codes). Read your OS from your own runtime *before the first call* —
you know it without running anything — and dispatch **every** script that
way, the leading credential block included: `bash …/scripts/X.sh` on
Linux/macOS, `pwsh`/`powershell …/scripts/win/X.ps1` on Windows. The blocks
below are the POSIX form; on Windows substitute the `.ps1` port each time.
Statuscheck's `platform` row then *confirms* that OS (and, on Windows, that
the runtime + ports are present) — it verifies the dispatch you already
chose, and can't be what you consult to dispatch statuscheck itself.
Like `check_assignee`, **statuscheck takes a required `--role` — pass
`--role assigner`** on both POSIX and Windows, since it authenticates *your*
role's credential and there is no default account to fall back on. It takes
**no issue-key argument** here; a role name reaching it positionally is ignored
rather than mistaken for one.

**Make sure local credentials exist — run FIRST, before the healthcheck.**
`ensure_local_env` no-ops when the file already exists, so run it
unconditionally; on non-zero, relay its stderr and **stop**. There is no
login step: `jira.sh` authenticates **per-request as `--role assigner`**
(`../_shared/jira-api-reference.md` §9), so there is no account to become —
every issue create below carries `--role assigner` and picks up the assigner
credential on that one call.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/ensure_local_env.sh" || exit 1
```

Then run the shared pre-flight healthcheck. It
gathers every environment fact this skill depends on — git repo, the two
env files + their gitignore state, Jira auth (the **assigner's** credential —
`jira.sh --role assigner whoami`), Jira project reachability, `gh` auth — in one pass and
prints a markdown table, replacing the older per-check prose. Send it as the
only tool call in its message, because its rows decide whether the next step
happens at all — anything batched alongside it has already run before that
decision existed. Override the rerun hint so its remedies name this skill:

```bash
STATUSCHECK_RERUN="rerun /jira-sdlc:jira-task-assigner" \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role assigner
```

(If `CLAUDE_PLUGIN_ROOT` isn't set — e.g. reading this skill on a non-Claude
client — resolve it against the platform's provided/default skills folder (the
folder it loads these skills from; each non-Claude client is expected to have
this set), keeping `../_shared/scripts/posix/statuscheck.sh` relative to this
skill's directory as the default; see INTEGRATIONS.md.) It resolves `<PROJECT-KEY>` and
`<DEFAULT_BASE_BRANCH>` from the env files itself, so you don't
pre-resolve tokens for this section.

It prints one markdown table (`check | status | detail`), where status is
`OK`, `FAIL` (blocks, with a remedy line printed under the table), `WARN`
(suspicious, not blocking), or `INFO` (context only), and exits non-zero
if any row is `FAIL`.

Only the rows the assigner reads in a role-specific way are spelled out
here; the rest are role-independent preconditions defined in
`statuscheck.sh` itself (their `detail` column is self-explanatory in the
printed output — that live output, not this table, is what the skill
actually acts on). The script never FAILs the rows below — it reports them
for every role, and each skill judges them for itself. The first three are
where the assigner's reading is the *opposite* of the executor's and
reviewer's: it runs from the **main repo checkout** (not a per-issue
worktree) on a long-lived branch.

| row | what it verifies / gathers |
|---|---|
| `worktree` | INFO: *main checkout* (`.git` is a directory) vs. *linked worktree* (`.git` is a file). **The assigner requires the main checkout** — it *creates* worktrees, it doesn't run inside one; a linked-worktree reading is a stop condition (see "Reading the result" below) |
| `branch` | INFO: *base branch* (`<DEFAULT_BASE_BRANCH>`) vs. `feature/*`/`hotfix/*` issue branch (`../_shared/jira-api-reference.md` §12) vs. neither. **The assigner requires `<DEFAULT_BASE_BRANCH>`, or `<PRODUCTION_BRANCH>` when the run turns out to be a hotfix** — the script only knows the former by name, so it reports production as *neither*; match it against the `production_branch` row yourself. Step 2 consumes this row and resolves every reading |
| `worktrees_dir` | INFO when `<WORKTREES_DIR>` exists, WARN when missing or unset. **The assigner requires it present** — it creates a worktree per leaf issue there and never `mkdir`s it; on WARN, stop and ask rather than creating the directory (the convention may have changed) |
| `parallel_instances` | INFO either way: whether this project has an optional `.jst/PARALLEL-INSTANCES.md`. Present → step 7 reads it and relays it; absent → nothing to do, and most projects won't have one |

Because no issue exists yet, `branch_project`, `issue_key`, and
`parent_branch` read as WARN/INFO here (skipped / no derivable key /
unset) — all expected. `gh_auth` still verifies GitHub credentials even
though the assigner only pushes branches and never opens PRs itself — a
green row confirms the creds the executor will later need for
`gh pr create`. The remaining rows FAIL if broken but need no per-role
interpretation: `git_repo`, `env_config`, `env_local`,
`env_local_ignored`, `jira_auth` (the **assigner's** credential authenticates —
`jira.sh --role assigner whoami`, the same pair every `jira.sh` call in
steps 6–7 uses), `jira_project`, plus context
`base_branch` (INFO), `production_branch` (INFO — only consumed on the
hotfix path in step 5C, which stops if it reads `unset`), and `working_tree`
(INFO, or WARN when the tree is dirty — that doesn't block, but mention
it to the user before branching from a dirty base checkout).

Reading the result: **any FAIL row** → stop, relay the script's remedy
line to the user, and wait — don't self-repair (re-auth CLIs, fabricate
env values, add missing files silently). The role-specific rows
never FAIL, so judge them yourself per the table above: a linked-worktree
reading → stop and tell the user to cd into the main checkout; a missing
worktrees dir → stop and ask; the `branch` row carries into step 2, which
acts on it (so you don't re-run `git branch --show-current` there); and
`parallel_instances` carries into step 7.

With no FAIL row and the role-specific rows reading as above, state what
those rows read — `worktree`, `branch`, `worktrees_dir`,
`parallel_instances` — before your first call after the healthcheck, then
continue to step 2. A message batched with the healthcheck can't state them,
because the values don't exist yet.

## 2. Determine context from the current branch

Read the `branch` row from step 1's healthcheck to determine your
starting point (the script already ran `git branch --show-current`; don't
re-run it):

- **Base branch (`<DEFAULT_BASE_BRANCH>`)**: you're standing where this skill
  expects to run. Proceed to investigate and plan the work — step 5C decides
  what the new branches get cut *from*, which isn't necessarily the branch
  you're standing on.
- **`<PRODUCTION_BRANCH>`**: a valid start state, but only for a hotfix.
  Proceed and let step 5C decide as it always does — don't try to settle
  hotfix-vs-planned here, before you've investigated; 5C is the single place
  that decision is made and confirmed with the user, and it stops there if it
  lands on planned work. (You cut from `origin/<PRODUCTION_BRANCH>` either
  way, so standing here is permitted, never required.)
- **`feature/<KEY>-...` or `hotfix/<KEY>-...` issue branch**:
  **STOP.** Running this skill from an existing issue branch is currently not supported. Tell the user to checkout the base branch first.
- **Any other branch name**:
  Ask the user whether to treat it as a base branch or abort. Do not guess.

## 3. Investigate

Search the codebase (Grep/Read/Glob) for relevant context: existing
related code, similar past patterns, affected modules. **Investigate
specifically to decide whether the work splits into pieces that can run at
the same time** — look for shared modules, sequential dependencies, and
single owners for interfaces. Signs it's one piece, not two:
- Changes that must land in a specific order to compile/test
- A single module that all work touches sequentially
- One person owns the interface all pieces must conform to

Don't ask the user things you can find yourself.

## 4. Clarify

If anything material is ambiguous (scope, acceptance criteria, priority,
or whether it's actually a defect vs. new work), ask concise, specific
questions before creating anything. Don't proceed on guesses for anything
that would change what you build.

**Tie clarified acceptance criteria to the issue description.** Once you have
the user's final answers, write them into the issue description at step 6A.1
so the criteria are durable and visible to anyone picking up the work.

## 5. Decide: Scope and Issue Type

By this point Step 2 has already confirmed you're standing on a branch this skill can run from — `<DEFAULT_BASE_BRANCH>`, or `<PRODUCTION_BRANCH>` pending a hotfix decision here. There is no second branch-context check. Make the following three decisions before moving to setup; C is what turns "which branch am I on" into the base the new branches actually get cut from:

**A. Decide Scope: single-step or multistep**
- **Multistep** — the request breaks into genuinely independent, parallelizable pieces (e.g. backend API + frontend UI + feature-flag config) that can be worked on *at the same time* in separate worktrees.
- **Single-step** — one cohesive piece of work, even if it touches several files. If piece B can only start once piece A finishes, that's one piece, not two — don't split purely sequential work.

**B. Pick the top-level issue type**
There is no `Epic` level — `Task`, `Story`, and `Bug` are the top-level types (peers), with `Sub-task` underneath. Your top-level options are `Task`, `Story`, or `Bug`.
- Defect / regression / something broken → `Bug`.
- New work, feature, or chore → If the user did not explicitly tell you which to use, **decide based on the complexity of the task**. Use a `Story` for larger, multi-faceted requests that deliver end-to-end user value, and use a `Task` for smaller, localized, or strictly technical chores.
- **Scope (A) and issue type (B) are independent** — scope is about *can the pieces run at the same time*; issue type is about *size/value of the whole*. A multistep `Task` of parallel technical chores is valid; a single-step `Story` is valid.

**C. Decide the base: planned work (default) or emergency hotfix**

Nearly every run is planned work. Take the hotfix path **only when the user
explicitly asks for an emergency production fix** — SDLC.md §4's flow, for a
bug already live in production that can't wait for the next sprint release.
Urgency words ("urgent", "asap", "this is blocking us") are not that signal;
deliberate ones are ("hotfix", "emergency production fix", "we need to patch
prod now"), and even then say which path you're taking and get a yes before
creating anything — a hotfix PR aims at production, so a false positive ships
code that never sat in staging.

| | planned work (default) | emergency hotfix |
|---|---|---|
| `<BASE_BRANCH>` — what the PR targets | `<DEFAULT_BASE_BRANCH>` | `<PRODUCTION_BRANCH>` |
| `<BRANCH_FROM>` — what you cut from | `<DEFAULT_BASE_BRANCH>` (your checkout) | `origin/<PRODUCTION_BRANCH>` |
| `<PREFIX>` | `feature/` | `hotfix/` |
| scope from (A) | single-step or multistep | **single-step, always** |

The issue type still comes from B, where an emergency production fix lands on
`Bug` like any other defect. Two entries in the hotfix column carry the weight:

- **`origin/<PRODUCTION_BRANCH>`, not your local copy and not
  `<DEFAULT_BASE_BRANCH>`.** Cutting from the freshly fetched remote ref works
  identically from either start state step 2 allows, and a stale local
  `<PRODUCTION_BRANCH>` can't poison the branch. Cutting from
  `<DEFAULT_BASE_BRANCH>` instead would carry every unreleased sprint feature
  into a production release — the accident SDLC.md §4 exists to prevent, and
  it stays invisible until the release ships.
- **Single-step overrides (A).** Splitting an emergency into parallel
  sub-tasks serializes the fix behind a stack of PRs. Work too big for one
  branch isn't a patch (SDLC.md §5) and belongs in the planned flow — say so
  rather than provisioning a hotfix parent with children.

The prefix is what makes the release machinery work, not just a label: CI
resolves the version from the branch name, patch-bumping a `hotfix/*` merge
into `<PRODUCTION_BRANCH>` (SDLC.md §5). A `feature/` branch merged there
matches nothing and is never tagged or released.

If step 1's `production_branch` row read `unset`, stop and ask — don't invent
a name for the branch you're about to point a PR at.

If step 2 started you on `<PRODUCTION_BRANCH>` and this decision lands on
**planned work**, stop and tell the user to checkout `<DEFAULT_BASE_BRANCH>`:
the planned path cuts from your own checkout (step 6), so continuing from here
would branch tomorrow's feature off production.

## 6. Create the Jira issue(s), branch(es), and worktrees

Because step 2 stopped you if you were already on an issue branch, you are always creating a brand-new top-level issue. By always provisioning a worktree for this top-level issue, the setup becomes a single, unified flow regardless of your scope decision.

**Re-run / partial-failure safety — deferred:** The assigner mints a fresh `<PARENT-KEY>` per run and has no resume input, so a key-keyed pre-check can't detect a prior run's differently-keyed orphan; revisit when a resume path or orphan-scan is added.

Before any branch creation, refresh from the remote. Which of the two
commands you need follows step 5C's `<BRANCH_FROM>`:
```bash
git fetch origin     # both paths — also refreshes origin/<PRODUCTION_BRANCH>
git pull --ff-only   # planned work only: you cut from your own checkout, and a bare
                     # fetch moves only the remote-tracking ref, not the branch you
                     # branch from. If it can't fast-forward, stop and ask.
```
On the hotfix path **skip the pull**: you cut from the fetched
`origin/<PRODUCTION_BRANCH>`, which the fetch already brought up to date.
Pulling would only move whichever branch you happen to be standing on —
nothing the hotfix needs, and from `<DEFAULT_BASE_BRANCH>` it quietly merges
production into your checkout.

**A. Create the Top-Level Issue, Branch, and Worktree (Always)**

**Assign on create** — get the assignee email once here; every issue this run
creates (top-level AND every sub-task) is assigned to it. On non-zero, relay
the script's stderr and **stop**.
```bash
ASSIGNEE_EMAIL=$(bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/get_assignee_email.sh") || exit 1
```
(If `CLAUDE_PLUGIN_ROOT` isn't set, resolve it against the platform's
provided/default skills folder (the folder it loads these skills from; each
non-Claude client is expected to have this set), keeping
`../_shared/scripts/posix/get_assignee_email.sh` relative to this skill as the
default; see INTEGRATIONS.md.)

1. Create the `Task`/`Story`/`Bug` → `<PARENT-KEY>`. (If single-step, this is your only issue).
   - **Assign on create** — pass `--assignee "$ASSIGNEE_EMAIL"` on the
     `jira.sh --role assigner issue create` call. One flag does it (no separate
     `issue assign`).
2. Create the branch: `git branch <PREFIX><PARENT-KEY>-<slug> <BRANCH_FROM>`, then `git push -u origin <PREFIX><PARENT-KEY>-<slug>`. This is the `PARENT_BRANCH`.
3. Set parentbranch config: `git config branch.<PREFIX><PARENT-KEY>-<slug>.parentbranch <BASE_BRANCH>`
   — record `<BASE_BRANCH>`, never `<BRANCH_FROM>`: this value becomes the
   executor's `gh pr create --base`, and on the hotfix path `origin/main` isn't
   something `gh` can target while `main` is.
4. **Always create a parent worktree:**
   `git worktree add <WORKTREES_DIR>/worktree-<PARENT-KEY> <PREFIX><PARENT-KEY>-<slug>`
   *(A worktree to check out when inspecting the assembled parent branch, and a base for future additions.)*

**B. If Single-step (Cohesive work):**
The top-level issue is your only issue. You are done creating issues.
Proceed to leave a PR-target comment on `<PARENT-KEY>` (see "PR-target comments" below).
Every hotfix run ends here — 5C forces single-step.

**C. If Multistep (Parallelizable): Create Sub-tasks (each with its own branch and worktree)**
Create the `Sub-task`s under `<PARENT-KEY>`. Every sub-task gets the same treatment — its own dedicated branch, its own worktree, and its own PR into `PARENT_BRANCH` — regardless of how small it is. There is no "small enough to commit straight to the parent branch" shortcut. Sub-task creates take the same `--assignee "$ASSIGNEE_EMAIL"` as the top-level issue — resolved once in 6A above, passed on every `issue create` here.

For each sub-task `→ <SUBTASK-KEY>`:
 1. `git worktree add <WORKTREES_DIR>/worktree-<SUBTASK-KEY> -b <PREFIX><SUBTASK-KEY>-<slug> <PREFIX><PARENT-KEY>-<slug>`
    (sub-tasks inherit the parent's prefix — the nesting rule in `../_shared/jira-api-reference.md` §12 — and since 5C only reaches this branch on the planned path, `<PREFIX>` is `feature/` here)
 2. `git config branch.<PREFIX><SUBTASK-KEY>-<slug>.parentbranch <PREFIX><PARENT-KEY>-<slug>` (required for executor)
 3. Leave a PR-target comment on the sub-task (format below).

**PR-target comments** (consumed by the executor, and by the reviewer's fallback on a fresh clone):
After creating each leaf issue (the single top-level task, OR each sub-task), add a Jira comment recording the branch its PR should target and the worktree to run the executor in. Every leaf — single-step or sub-task — gets its own dedicated branch and PR; this comment is what tells the executor where that PR's base is.

*Single-step (top-level issue):*
*"PR target branch: <BASE_BRANCH>. Worktree: <WORKTREES_DIR>/worktree-<PARENT-KEY>."*

*Multistep sub-task:*
*"PR target branch: <PREFIX><PARENT-KEY>-<slug>. Worktree: <WORKTREES_DIR>/worktree-<SUBTASK-KEY>."*

In the multistep path, after creating all sub-tasks, also post the single-step-format comment on the **parent issue** — its PR targets `<BASE_BRANCH>` — so the reviewer's fallback can recover `<BASE_BRANCH>` even without `git config` (fresh clone or different machine).

On the hotfix path this comment is load-bearing rather than a convenience: the
PR-base resolver's last fallback is `<DEFAULT_BASE_BRANCH>`
(`../_shared/jira-api-reference.md` §13), so a hotfix whose comment never
landed can look like ordinary planned work to a later session. Confirm the
comment posted before reporting back.

**Client mechanics — things to never forget** (`jira.sh` on POSIX /
`jira.ps1` on Windows; full command surface in `../_shared/jira-api-reference.md`
§9; the steps write `jira.sh <cmd>` for brevity — actually invoke it as
`bash "$S/jira.sh" <cmd>` where `S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"`):
- **Auth**: no login step — every call carries `--role assigner` and
  authenticates per-request on the assigner credential (`../_shared/jira-api-reference.md`
  §9). (Step 1's healthcheck already verified that this credential auths.)
- **Project health check**: already verified by step 1's healthcheck. (If
  you're picking up from a re-run and skipped step 1, run
  `jira.sh --role assigner project exists <PROJECT-KEY>` first — exit 0 means
  visible.)
- **Create issue**:
  `jira.sh --role assigner issue create --project "<PROJECT-KEY>" --type "Task" --summary "..." --desc-file <file> --assignee "$ASSIGNEE_EMAIL"`
  Sub-tasks add `--type "Subtask"` and `--parent "<PARENT-KEY>"`.
  `create` **prints the new key on stdout** — capture it directly (`KEY=$(jira.sh
  … issue create …)`); there is no browse URL to parse. **Always pass
  `--assignee "$ASSIGNEE_EMAIL"`** on every create — top-level AND each
  sub-task — resolved once at the top of 6A. One flag does it on create; do
  not issue a separate `issue assign`.
- Quote `"Subtask"` exactly (no hyphen — this project's real type name,
  confirmed in `../_shared/jira-api-reference.md` §10).
- **Comment**: no inline body — write a temp file and pass `--body-file <file>`:
  `jira.sh --role assigner issue comment add <KEY> --body-file <file>`. Plain
  text is stored as ADF, one paragraph per non-blank line; for real structure
  build an ADF `doc` and use `--adf-file` (see `../_shared/jira-api-reference.md`
  §11).
- **Delete caveat**: `jira.sh issue delete <KEY> [--with-subtasks]` runs
  unattended (no confirmation prompt), so still never auto-delete; hand back
  the ready-to-paste command for the human to run.
- Put investigation findings + acceptance criteria in the issue
  description (use `--desc-file <file>` for anything beyond a sentence).
  `--desc-file` stores **plain text as ADF, one paragraph per non-blank
  line** — a markdown body shows its syntax literally (`##` / `-`); for real
  structure build an ADF `doc` and pass `--adf-file` (see
  `../_shared/jira-api-reference.md` §11).
- Make sure the branch you're branching *from* is committed/pushed
  before branching.

## 7. Report back

List: created issue key(s)/link(s); the scope decision (single-step vs multistep) and why; which base path 5C took and why; each branch created; and each worktree path together with the PR-target branch it's meant to merge into (explicitly calling out the parent worktree).

**If step 1's `parallel_instances` row read *present*,** read
`.jst/PARALLEL-INSTANCES.md` and fold its instructions into the report, so
each worktree is listed with what still has to be provisioned there (clone the
database, pick an instance index, per-instance ports) before the app will run.
You created source trees, not running instances, and this report is where
whoever picks a worktree up will look for the difference. Don't run any of it —
provisioning is environment setup for the executor/human, so step 8's boundary
holds. Absent → say nothing and carry on.

On the hotfix path, add that the fix also has to reach
`<DEFAULT_BASE_BRANCH>` after it lands on `<PRODUCTION_BRANCH>` (SDLC.md §4
step 4) — automatically if the project's release workflow back-merges, by hand
otherwise. Without it the bug returns with the next sprint release, and this
report is the last point where anyone is thinking about it.

Post this same report to the user in chat **and** as a single Jira comment on the parent issue. Since it's multi-line, write it to a temp file and post it with `jira.sh --role assigner issue comment add <PARENT-KEY> --body-file <file>` (there is no inline body — the body always comes from a file; see `../_shared/jira-api-reference.md` §11).

## 8. Don't start implementation work, but do leave worktrees ready

Creating the worktrees above is environment setup, not implementation —
that boundary still holds: don't write code, commit, or open a PR here.
Once the worktrees exist, point the user (or a parallel subagent per
worktree) at cd'ing into each created worktree and running
`/jira-sdlc:jira-task-executor` there with **no key argument** —
optionally with free-form prose notes for that run — since the issue key
is derived from that worktree's own branch (adjust the `jira-sdlc:`
prefix if you renamed the plugin, or drop it entirely if you installed
these skills as loose files rather than as a plugin). Merging the parent
branch back into its own base once all sub-tasks land is likewise out of
scope for this skill.

Reference: `../_shared/jira-api-reference.md` is the operational + REST
reference — the `jira.sh` command surface, confirmed issue type names, and
git/branch conventions this skill depends on. The
`.jst/jira-sdlc-tools.env` (team-shared) and `.jst/jira-sdlc-tools.local.env`
(machine-specific) files under the project root have this repo's specific
values for every `<TOKEN>` used above.
