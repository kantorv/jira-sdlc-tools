---
name: jira-task-assigner
description: Turns a task description into Jira issues plus ready-to-work git branches and worktrees — one per leaf issue, so several executors can then run in parallel. Run it from the main repo checkout on the base branch, passing the task description as the argument. It investigates the codebase, asks about what's ambiguous, and decides whether the work is one self-contained task or splits into parallel sub-tasks. Branches are `feature/` off the default base branch; on an explicit request for an emergency production fix it provisions a single `hotfix/` off the production branch instead. Writes no code and opens no PRs.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Write, AskUserQuestion
---

You are acting as a technical project manager for the **`<PROJECT-KEY>`**
project. Given a task description from the user ($ARGUMENTS):

**Conventions used below:**

- `$ARGUMENTS` is the task description — free-form prose, the sole input to
  steps 3–5. If it's empty, ask for it before running anything: there is
  nothing to investigate or scope without it, and the healthcheck costs a
  round trip you'd only repeat.
- `<PROJECT-KEY>`, `<WORKTREES_DIR>`, `<DEFAULT_BASE_BRANCH>`,
  `<PRODUCTION_BRANCH>` — read all four off step 1's healthcheck rows
  (`env_config`, `worktrees_dir`, `base_branch`, `production_branch`).
  **Never dump `.jst/jira-sdlc-tools.local.env`** — it holds three role Jira
  tokens and the GitHub PAT. A value no row carries is a single-key `grep`,
  never a whole-file read: `../_shared/project-config.md` § *Reading config
  safely* has the form, and the redaction filter that silently doesn't work.
- `<slug>` = the issue title slugified per
  `../_shared/jira-api-reference.md` §12 (lowercase, spaces → hyphens, strip
  punctuation).
- A **leaf** is an issue that gets its own branch, worktree and PR — the
  single top-level issue on the single-step path, or each sub-task on the
  multistep one.
- **Branch prefix** — the prefix follows the **base branch, not the issue
  type** (5C decides it; `../_shared/jira-api-reference.md` §12). It is
  uniform within a run — a Sub-task inherits its parent's — so branch naming
  is always `<PREFIX><KEY>-<slug>`, which is what lets statuscheck derive
  `issue_key` from a branch, and the executor find its issue with no key
  argument at all.
- `<PREFIX>`, `<BASE_BRANCH>`, `<BRANCH_FROM>` — set once by step 5C, used
  verbatim by step 6.
- An issue already created *without* this skill needs no decision here:
  follow the no-assigner provisioning recipe in
  `../_shared/jira-api-reference.md` §12 and go straight to the executor.
- **Script paths** — every script below lives under
  `${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/`. If
  `CLAUDE_PLUGIN_ROOT` isn't set (a non-Claude client), resolve the root
  yourself, in order: (1) this skill's own directory — given at the top of
  the loaded SKILL.md, or the folder containing it — so the scripts are at
  `../_shared/scripts/posix/` relative to it (correct on every platform);
  (2) if you can't derive that, probe the platform's default skills
  locations — project-root `.agent/skills/`, `.agents/skills/`,
  `.codex/skills/`, `.opencode/skills/`, `.claude/skills/`, `.grok/skills/`,
  the home global `~/.claude/skills/`, or the path named in the platform's
  config (`kilo.jsonc`, `settings.json`, `config.toml`). See INTEGRATIONS.md
  → "Locating the shared scripts".

## 1. Discovery and healthcheck

**Script dispatch — settle this before running any script below.** Every
script this skill invokes ships twice: the POSIX `…/scripts/X.sh` and its
Windows twin `…/scripts/win/X.ps1` (PowerShell 5.1+; identical args, output,
exit codes). Pick the branch from your own runtime *before the first call* —
you know your OS without running anything — and use it for every script
here, credential block included; the blocks below are the POSIX form.
Statuscheck's `platform` row only *confirms* that choice afterwards, so it
can't decide how statuscheck itself is run. It takes a required `--role assigner` (no default credential) and no issue-key argument.

There is no login step: `jira.sh` authenticates **per-request as
`--role assigner`** (`../_shared/jira-api-reference.md` §9), so every issue
create below carries `--role assigner` and picks up that credential on the
one call. A missing `.jst/jira-sdlc-tools.local.env` is a hard FAIL on
statuscheck's `env_local` row here — the main checkout is where that file has
to exist, so there is nothing for the healthcheck to copy it from.

Run the shared pre-flight healthcheck. It gathers every environment fact this
skill depends on — git repo, the two env files + their gitignore state, Jira
auth (the **assigner's** credential — `jira.sh --role assigner whoami`), Jira
project reachability, `gh` auth — in one pass. Send it as the only tool call in
its message, because its rows decide whether the next step happens at all —
anything batched alongside it has already run before that decision existed.
Override the rerun hint so its remedies name this skill:

```bash
STATUSCHECK_RERUN="rerun /jira-sdlc:jira-task-assigner" \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role assigner
```

It resolves `<PROJECT-KEY>` and `<DEFAULT_BASE_BRANCH>` from the env files
itself, so you don't pre-resolve tokens here, and prints one markdown table
(`check | status | detail`) — `OK`, `FAIL` (blocks, with a remedy printed
under the table), `WARN` (suspicious, not blocking), `INFO` (context only) —
exiting non-zero if any row is `FAIL`.

Only the rows the assigner reads in a role-specific way are spelled out here;
the rest are role-independent preconditions defined in `statuscheck.sh`,
self-explanatory in the printed output — and that live output, not this table,
is what the skill acts on. The script never FAILs the first two rows below,
leaving each skill to judge them (`worktrees_dir` is the exception: a relative
path is a hard FAIL). The assigner runs from the **main repo checkout** on a
long-lived branch — the opposite reading from the executor/reviewer:

| row | what it verifies / gathers |
| -- | -- |
| `worktree` | INFO: *main checkout* (`.git` is a directory) vs. *linked worktree* (`.git` is a file). **The assigner requires the main checkout** — it *creates* worktrees, it doesn't run inside one; on a linked-worktree reading, stop and tell the user to cd into the main checkout |
| `branch` | INFO: the script only knows the base branch by name, so it reports `<PRODUCTION_BRANCH>` as *neither* — match that yourself against the `production_branch` row. Step 2 judges every reading |
| `worktrees_dir` | INFO when `<WORKTREES_DIR>` exists, WARN when missing or unset, FAIL when it isn't an absolute path. **The assigner requires it present** — it creates a worktree per leaf issue there and never `mkdir`s it; on WARN, stop and ask rather than creating the directory (the convention may have changed) |

Three other rows carry an assigner-specific reading: `gh_auth` still blocks
even though this skill opens no PRs — verifying it now is what stops the
*executor* discovering a logged-out `gh` after its implementation is already
written and pushed; `jira_account_url` is where
step 7's browse links come from, which is why no step opens the
credential-bearing `.jst/jira-sdlc-tools.local.env`; and `working_tree` WARNs
on a dirty tree — not blocking, but mention it before branching from that
checkout. `branch_project`, `issue_key` and `parent_branch` read WARN/INFO
because no issue exists yet; the rest print their own remedy on FAIL.

Reading the result: **any FAIL row** → stop, relay the script's remedy
line to the user, and wait — don't self-repair (re-auth CLIs, fabricate
env values, add missing files silently). `worktree` and `branch` never FAIL —
judge those two yourself per the table.

With no FAIL row and the three role-specific rows reading as above, state what
those rows read — `worktree`, `branch`, `worktrees_dir` — before your first
call after the healthcheck, then continue to step 2.

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
- **`feature/<KEY>-...` or `hotfix/<KEY>-...` issue branch, or a detached
  HEAD**: **STOP.** An issue branch isn't a supported starting point, and a
  detached HEAD gives the new branches nothing nameable to be cut from. Tell
  the user to checkout the base branch first.
- **Any other branch name**: ask the user whether to treat it as a base
  branch or abort. Do not guess; if they accept it, 5C makes it both
  `<BRANCH_FROM>` and `<BASE_BRANCH>`.

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
that would change what you build. Ask with `AskUserQuestion` where the options
are closed (base-branch acceptance in step 2, the hotfix confirmation in 5C);
use plain prose for genuinely open questions about scope.

**Tie clarified acceptance criteria to the issue description.** Once you have
the user's final answers, write them into the issue description at step 6A.1
so they're durable and visible to whoever picks the work up.

## 5. Decide the scope and issue type

Step 2 has already confirmed you're standing on a branch this skill can run
from; there is no second branch-context check. Make the following three
decisions before moving to setup — C is what turns "which branch am I on" into
the base the new branches actually get cut from:

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
explicitly asks for an emergency production fix** — the flow at
https://kantorv.github.io/jira-sdlc-tools/docs/sdlc §4, for a bug already
live in production that can't wait for the next sprint release.
Urgency words ("urgent", "asap", "this is blocking us") are not that signal;
deliberate ones are ("hotfix", "emergency production fix", "we need to patch
prod now"), and even then say which path you're taking and get a yes before
creating anything — a hotfix PR aims at production, so a false positive ships
code that never sat in staging.

|  | planned work (default) | emergency hotfix |
| -- | -- | -- |
| `<BASE_BRANCH>` — what the PR targets | `<DEFAULT_BASE_BRANCH>` | `<PRODUCTION_BRANCH>` |
| `<BRANCH_FROM>` — what you cut from | `<DEFAULT_BASE_BRANCH>` (your checkout) | `origin/<PRODUCTION_BRANCH>` |
| `<PREFIX>` | `feature/` | `hotfix/` |
| scope from (A) | single-step or multistep | **single-step, always** |

If step 2 landed on "any other branch" and the user accepted it as the base,
that branch is both `<BRANCH_FROM>` and `<BASE_BRANCH>` — what you cut from and
what the PR targets — with `<PREFIX>` = `feature/` (it isn't
`<PRODUCTION_BRANCH>`, so it isn't the hotfix flow).

The issue type still comes from B, where an emergency production fix lands on
`Bug` like any other defect. Two entries in the hotfix column carry the weight:

- **`origin/<PRODUCTION_BRANCH>`, not your local copy and not
  `<DEFAULT_BASE_BRANCH>`.** Cutting from the freshly fetched remote ref works
  identically from either start state step 2 allows, and a stale local
  `<PRODUCTION_BRANCH>` can't poison the branch. Cutting from
  `<DEFAULT_BASE_BRANCH>` instead would carry every unreleased sprint feature
  into a production release — the accident SDLC §4 exists to prevent, and
  it stays invisible until the release ships.
- **Single-step overrides (A).** Splitting an emergency into parallel
  sub-tasks serializes the fix behind a stack of PRs. Work too big for one
  branch isn't a patch (SDLC §5) and belongs in the planned flow — say so
  rather than provisioning a hotfix parent with children.

The prefix is what makes the release machinery work, not just a label: CI
resolves the version from the branch name, patch-bumping a `hotfix/*` merge
into `<PRODUCTION_BRANCH>` (SDLC §5). A `feature/` branch merged there
matches nothing and is never tagged or released.

**On the hotfix path only**, if step 1's `production_branch` row read
`unset`, stop and ask — don't invent a name for the branch you're about to
point a PR at. Planned work never reads it.

If step 2 started you on `<PRODUCTION_BRANCH>` and this decision lands on
**planned work**, stop and tell the user to checkout `<DEFAULT_BASE_BRANCH>`:
the planned path cuts from your own checkout (step 6), so continuing from here
would branch tomorrow's feature off production.

## 6. Create the Jira issue(s), branch(es), and worktrees

Because step 2 stopped you if you were already on an issue branch, you are
always creating a brand-new top-level issue.

Before any branch creation, refresh from the remote. Which of the two
commands you need follows step 5C's `<BRANCH_FROM>`:

```bash
git fetch origin                        # both paths — also refreshes origin/<PRODUCTION_BRANCH>
git pull --ff-only origin <BRANCH_FROM>  # planned work only
```

The pull is planned-work only: there you cut from your own checkout, and a bare
fetch moves the remote-tracking ref rather than the branch you branch from.
Name the remote and branch — bare, `pull --ff-only` also exits 1 on a branch
with no upstream configured (benign, common after a re-clone) and that is
indistinguishable from real divergence; named, exit 1 means divergence only, so
stop and ask rather than reset/rebase/`--set-upstream-to`-ing your way past it,
which rewrites the user's history or git config to silence a warning that isn't
yours to answer — with one residual case: a `<BRANCH_FROM>` that exists only
locally exits 1 with `couldn't find remote ref`, which is not divergence. Read
the message before you stop: that one means there is nothing to pull, so skip
the pull and carry on.

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

1. Create the `Task`/`Story`/`Bug` → `<PARENT-KEY>` (if single-step, this is
   your only issue), passing `--assignee "$ASSIGNEE_EMAIL"` and
   `--desc-file <file>` holding the step 3 findings and the step 4 acceptance
   criteria.
2. Create the branch: `git branch <PREFIX><PARENT-KEY>-<slug> <BRANCH_FROM>`,
   then `git push -u origin <PREFIX><PARENT-KEY>-<slug>`. This is the
   `PARENT_BRANCH`.
3. Set parentbranch config: `git config branch.<PREFIX><PARENT-KEY>-<slug>.parentbranch <BASE_BRANCH>`
   — record `<BASE_BRANCH>`, never `<BRANCH_FROM>`: this value becomes the
   executor's `gh pr create --base`, and on the hotfix path `origin/main` isn't
   something `gh` can target while `main` is.
4. **Always create a parent worktree:**
   `git worktree add <WORKTREES_DIR>/worktree-<PARENT-KEY> <PREFIX><PARENT-KEY>-<slug>`
   *(A worktree to check out when inspecting the assembled parent branch, and
   a base for future additions.)*

**B. If Single-step (Cohesive work):**
The top-level issue is your only issue. You are done creating issues. Proceed
to leave a PR-target comment on `<PARENT-KEY>` (see "PR-target comments"
below). Every hotfix run ends here — 5C forces single-step.

**C. If Multistep (Parallelizable): Create Sub-tasks (each with its own branch
and worktree)**
Create the `Sub-task`s under `<PARENT-KEY>`. Every sub-task gets the same
treatment — its own dedicated branch, its own worktree, and its own PR into
`PARENT_BRANCH` — regardless of how small it is. There is no "small enough to
commit straight to the parent branch" shortcut.

For each sub-task `→ <SUBTASK-KEY>`:

1. `git worktree add <WORKTREES_DIR>/worktree-<SUBTASK-KEY> -b <PREFIX><SUBTASK-KEY>-<slug> <PREFIX><PARENT-KEY>-<slug>`
   (sub-tasks inherit the parent's prefix — the nesting rule in
   `../_shared/jira-api-reference.md` §12 — and since 5C only reaches this
   branch on the planned path, `<PREFIX>` is `feature/` here)
2. `git config branch.<PREFIX><SUBTASK-KEY>-<slug>.parentbranch <PREFIX><PARENT-KEY>-<slug>`
   (required for executor)
3. Leave a PR-target comment on the sub-task (format below).

**PR-target comments** (consumed by the executor, and by the reviewer's
fallback on a fresh clone):
After creating each leaf issue, add a Jira comment recording the branch its PR
should target and the worktree to run the executor in — that comment is what
tells the executor where its PR's base is.

*Single-step (top-level issue):*

```
PR target branch: <BASE_BRANCH>. Worktree: <WORKTREES_DIR>/worktree-<PARENT-KEY>.
```

*Multistep sub-task:*

```
PR target branch: <PREFIX><PARENT-KEY>-<slug>. Worktree: <WORKTREES_DIR>/worktree-<SUBTASK-KEY>.
```

In the multistep path, after creating all sub-tasks, also post the
single-step-format comment on the **parent issue** — its PR targets
`<BASE_BRANCH>` — so the reviewer's fallback can recover `<BASE_BRANCH>` even
without `git config` (fresh clone or different machine).

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
- **Project health check**: already verified by step 1's healthcheck.
- **Create issue**:
  `jira.sh --role assigner issue create --project "<PROJECT-KEY>" --type "Task" --summary "..." --desc-file <file> --assignee "$ASSIGNEE_EMAIL"`
  Sub-tasks add `--type "Subtask"` and `--parent "<PARENT-KEY>"`.
  `create` **prints the new key on stdout** — capture it directly (`KEY=$(jira.sh … issue create …)`); there is no browse URL to parse, links are
  assembled (`../_shared/project-config.md` § *Issue browse links*). **Always pass
  `--assignee "$ASSIGNEE_EMAIL"`** on every create — top-level AND each
  sub-task — resolved once at the top of 6A. One flag does it on create; do
  not issue a separate `issue assign`.
- Quote `"Subtask"` exactly (no hyphen — this project's real type name,
  confirmed in `../_shared/jira-api-reference.md` §10).
- **Text bodies** (`--body-file` on a comment, `--desc-file` on a create):
  there is no inline form — the body always comes from a file, which also
  keeps backticks in it away from the shell. Plain text is stored as ADF, one
  paragraph per non-blank line, so markdown syntax (`##`, `-`) shows up
  literally; for real structure build an ADF `doc` and pass `--adf-file`
  instead (`../_shared/jira-api-reference.md` §11).
- **Partial failure leaves orphans, and nothing detects them.** If a run dies
  after creating some issues or branches, report exactly what got created
  before you stop — don't retry from the top, which just makes a second set
  under new keys. To undo, hand back
  `jira.sh --role assigner issue delete <KEY> [--with-subtasks]` for the human
  to run: it deletes unattended, with no confirmation prompt, so never run it
  yourself.

## 7. Report back

Begin the report with the marker line `Assignment report` — the executor greps
the issue's comments for exactly that prefix to recover this context
(`../_shared/jira-api-reference.md` §11), so it must be the first line and
verbatim. Then list:

- each created issue key and its link
  (`https://<JIRA_ACCOUNT_URL>/browse/<KEY>`, built from step 1's
  `jira_account_url` row and from nothing else —
  `../_shared/project-config.md` § *Issue browse links*)
- the scope decision (single-step vs multistep) and why
- which base path 5C took and why
- each branch created
- each worktree path with the PR-target branch it's meant to merge into,
  explicitly calling out the parent worktree

On the hotfix path, add that the fix also has to reach
`<DEFAULT_BASE_BRANCH>` after it lands on `<PRODUCTION_BRANCH>`
(https://kantorv.github.io/jira-sdlc-tools/docs/sdlc §4 step 4) —
automatically if the project's release workflow back-merges, by hand
otherwise. Without it the bug returns with the next sprint release, and this
report is the last point where anyone is thinking about it.

Post this same report to the user in chat **and** as a single Jira comment on
the top-level issue, written to a temp file and posted with
`jira.sh --role assigner issue comment add <PARENT-KEY> --body-file <file>`
(§11 — no inline body exists).

## 8. Don't start implementation work, but do leave worktrees ready

Creating the worktrees above is environment setup, not implementation —
that boundary still holds: don't write code, commit, or open a PR here.
Once the worktrees exist, point the user (or a parallel subagent per
worktree) at cd'ing into each created worktree and running
`/jira-sdlc:jira-task-executor` there with **no key argument** —
optionally with free-form prose notes for that run — since the issue key
is derived from that worktree's own branch. Merging the parent branch back
into its own base once all sub-tasks land is likewise out of scope for this
skill.

Reference: anything the steps don't spell out is in
`../_shared/jira-api-reference.md`.
