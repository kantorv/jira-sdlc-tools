---
name: jira-task-assigner
description: Turn a feature/task/bug description into Jira issues, with matching git branches and worktrees set up so the pieces can be worked on in parallel. Detects an implied parent from the current git branch, investigates the codebase, asks clarifying questions, decides whether the request is a single self-contained task or a multistep task that should be split into parallel sub-tasks, creates the Jira issue(s) via the official Atlassian CLI (acli), creates a branch per top-level/parent issue, and creates a `git worktree` per leaf issue (the single task, or each sub-task) so parallel work can start immediately. Every leaf issue gets its own dedicated branch and worktree, so the executor always opens an individual PR per leaf.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are acting as a technical project manager for the **`<PROJECT-KEY>`**
project. Given a task description from the user ($ARGUMENTS):

**Conventions used below:**
- `<PROJECT-KEY>`, `<WORKTREES_DIR>`, `<DEFAULT_BASE_BRANCH>` — resolve
  these from `jira-sdlc-tools.env` (team-shared) and
  `jira-sdlc-tools.local.env` (machine-specific) in the project root before
  following the rest of this skill.
- `<WORKTREES_DIR>` — the directory where per-issue worktrees are created
  (see `../_shared/project-config.md`). It must already exist — this skill
  never `mkdir`s it; step 1's healthcheck verifies it's present.
- `<slug>` = short kebab-case summary of the issue title, same style as
  existing branches in this repo.
- Branch naming is **always** `feature/<KEY>-<slug>` (`hotfix/<KEY>-<slug>`
  for a production bugfix) whether `<KEY>` is a top-level issue or a
  Sub-task — this keeps the branch-parsing regex in step 2 working no
  matter which branch someone checks out later.

## 1. Discovery and healthcheck

Before any planning work, run the shared pre-flight healthcheck. It
gathers every environment fact this skill depends on — git repo, the two
env files + their gitignore state, `acli` auth, Jira project
reachability, `gh` auth — in one pass and prints a markdown table,
replacing the older per-check prose. Override the rerun hint so its
remedies name this skill:

```bash
STATUSCHECK_RERUN="rerun /jira-sdlc:jira-task-assigner" \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/statuscheck.sh"
```

(If `CLAUDE_PLUGIN_ROOT` isn't set — e.g. reading this skill outside a
plugin session — the script lives at `../_shared/scripts/statuscheck.sh`
relative to this skill's directory.) It resolves `<PROJECT-KEY>` and
`<DEFAULT_BASE_BRANCH>` from the env files itself, so you don't
pre-resolve tokens for this section.

It prints one markdown table (`check | status | detail`), where status is
`OK`, `FAIL` (blocks, with a remedy line printed under the table), `WARN`
(suspicious, not blocking), or `INFO` (context only), and exits non-zero
if any row is `FAIL`. The `worktree` and `branch` rows are context INFO —
the shared script reports them for every role and never FAILs on them; the
assigner runs from the **main repo checkout on the base branch** (not a
per-issue worktree), so it reads those two rows the opposite way from the
executor/reviewer. The rows:

| row | what it verifies / gathers |
|---|---|
| `git_repo` | you're inside a git repository at all |
| `worktree` | INFO: whether the repo root is the *main checkout* (`.git` is a directory) or a *linked worktree* (`.git` is a file). **The assigner requires the main checkout** — it *creates* worktrees, it doesn't run inside one; the reading note below turns that into a stop condition |
| `env_config` | `jira-sdlc-tools.env` exists and defines `<PROJECT-KEY>` |
| `env_local` | `jira-sdlc-tools.local.env` is mandatory in every checkout (Jira URL/email/token) and gitignored. In the main checkout the assigner runs from, this row is `OK` when present and `FAIL` (with a remedy) when missing — the linked-worktree auto-copy path doesn't apply here |
| `env_local_ignored` | the local env file is gitignored and untracked — it points at secrets and must never enter shared history |
| `branch` | INFO: whether the current branch is the *base branch* (`<DEFAULT_BASE_BRANCH>`), a `feature/*`/`hotfix/*` issue branch (§7), or neither. **The assigner requires the base branch**; a feature/hotfix issue branch is its explicit STOP case and any other branch is a user decision — both handled in step 2, which consumes this row |
| `branch_project` | skipped here (`WARN`) — there's no issue branch yet to check a project prefix against |
| `issue_key` | reports no derivable key (`WARN`) — no issue exists yet; the assigner is what *creates* the issue and its key |
| `gh_auth` | `gh` installed + authenticated. The assigner pushes branches but doesn't call `gh` itself; a green row confirms the GitHub credentials the executor will need for `gh pr create` already work (a broken `gh` surfaces here rather than mid-execution) |
| `acli_auth` | `acli` installed + authenticated — every `acli jira ...` call in steps 6–7 depends on it; credentials live in acli's keyring, not the env files |
| `jira_project` | `<PROJECT-KEY>` exists and is reachable on the authenticated Jira site (`acli jira project list`, whole-word match) |
| `base_branch` | INFO: `<DEFAULT_BASE_BRANCH>` as resolved from the env files |
| `parent_branch` | INFO: `git config branch.<branch>.parentbranch` — unset on the base branch, which is expected here |
| `working_tree` | WARN if uncommitted changes predate this run |

**Worktrees directory exists.** The assigner creates a `git worktree` per
leaf issue under `<WORKTREES_DIR>` and never `mkdir`s it, so verify it's
there before planning: from the repo root, `ls <WORKTREES_DIR>` and
confirm exit 0. If it's missing, stop and ask rather than creating one
(the convention may have changed).

Reading the result: **any FAIL row** → stop, relay the script's remedy
line to the user, and wait — don't self-repair (re-auth CLIs, fabricate
env values, add missing files silently). Role-independent failures
(missing git repo or env files, a mis-tracked `local.env`, an
unauthenticated `acli`/`gh`, an unreachable project) still FAIL and block.

The `worktree` and `branch` rows never FAIL, so judge them yourself: the
`worktree` row must report the **main repo checkout** (if it reports a
linked worktree, stop and tell the user to cd into the main checkout — the
assigner doesn't run inside a per-issue worktree), and the `branch` row
should report the **base branch** (`<DEFAULT_BASE_BRANCH>`). A
`feature/*`/`hotfix/*` issue branch is the assigner's explicit STOP case
and any other branch is a user decision — both are resolved in step 2,
which consumes this row (so you don't re-run `git branch --show-current`
there).

With no FAIL row, the `worktree`/`branch` rows reading as above, and
`<WORKTREES_DIR>` present, continue to step 2.

## 2. Determine context from the current branch

Run `git branch --show-current` to determine your starting point.

- **Branch is exactly `<DEFAULT_BASE_BRANCH>`**: 
  `BASE_BRANCH = <DEFAULT_BASE_BRANCH>`. Proceed to investigate and plan the work.
- **Branch matches `feature/<KEY>-...` or `hotfix/<KEY>-...`**: 
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

## 5. Decide: Branch Context, Scope, and Issue Type

First, verify your current branch context using `git branch --show-current`.

By this point Step 2 has already decided the branch context and confirmed you're starting from a base branch (`BASE_BRANCH`) — there is no second branch-context check here. Make the following two decisions before moving to setup:

**A. Decide Scope: single-step or multistep**
- **Multistep** — the request breaks into genuinely independent, parallelizable pieces (e.g. backend API + frontend UI + feature-flag config) that can be worked on *at the same time* in separate worktrees.
- **Single-step** — one cohesive piece of work, even if it touches several files. If piece B can only start once piece A finishes, that's one piece, not two — don't split purely sequential work.

**B. Pick the top-level issue type**
There is no `Epic` level — `Task`, `Story`, and `Bug` are the top-level types (peers), with `Sub-task` underneath. Your top-level options are `Task`, `Story`, or `Bug`.
- Defect / regression / something broken → `Bug`.
- New work, feature, or chore → If the user did not explicitly tell you which to use, **decide based on the complexity of the task**. Use a `Story` for larger, multi-faceted requests that deliver end-to-end user value, and use a `Task` for smaller, localized, or strictly technical chores.
- **Scope (A) and issue type (B) are independent** — scope is about *can the pieces run at the same time*; issue type is about *size/value of the whole*. A multistep `Task` of parallel technical chores is valid; a single-step `Story` is valid.

## 6. Create the Jira issue(s), branch(es), and worktrees

Because you aborted in Step 2 if an existing parent was found, you are always creating a brand-new top-level issue. By always provisioning a worktree for this top-level issue, the setup becomes a single, unified flow regardless of your scope decision.

**M3 (re-run / partial-failure safety) — deferred:** The assigner mints a fresh `<PARENT-KEY>` per run and has no resume input, so a key-keyed pre-check can't detect a prior run's differently-keyed orphan; revisit when a resume path or orphan-scan is added.

Before any branch creation, ensure the base is current:
```bash
git fetch origin
```


**A. Create the Top-Level Issue, Branch, and Worktree (Always)**
1. Create the `Task`/`Story`/`Bug` → `<PARENT-KEY>`. (If single-step, this is your only issue).
   - **Assignment (M4):** This repo **does not auto-assign** created issues — ownership is left to board triage. Do not add `--assignee @me` on creation. If your project wants auto-assignment, add the flag and update this note.
2. Create the branch: `git branch feature/<PARENT-KEY>-<slug> <BASE_BRANCH>`, then `git push -u origin feature/<PARENT-KEY>-<slug>`. This is the `PARENT_BRANCH`.
3. Set parentbranch config: `git config branch.feature/<PARENT-KEY>-<slug>.parentbranch <BASE_BRANCH>`
4. **Always create a parent worktree:** 
   `git worktree add <WORKTREES_DIR>/worktree-<PARENT-KEY> feature/<PARENT-KEY>-<slug>`
   *(A worktree to check out when inspecting the assembled parent branch, and a base for future additions.)*

**B. If Single-step (Cohesive work):**
The top-level issue is your only issue. You are done creating issues. 
Proceed to leave a PR-target comment on `<PARENT-KEY>` (see "PR-target comment" section below).

**C. If Multistep (Parallelizable): Create Sub-tasks (each with its own branch and worktree)**
Create the `Sub-task`s under `<PARENT-KEY>`. Every sub-task gets the same treatment — its own dedicated branch, its own worktree, and its own PR into `<PARENT-BRANCH>` — regardless of how small it is. There is no "small enough to commit straight to the parent branch" shortcut.

For each sub-task `→ <SUBTASK-KEY>`:
 1. `git worktree add <WORKTREES_DIR>/worktree-<SUBTASK-KEY> -b feature/<SUBTASK-KEY>-<slug> feature/<PARENT-KEY>-<slug>`
    (use `hotfix/<SUBTASK-KEY>-<slug>` instead when the top-level issue is a `Bug` — see the nesting rule in `../_shared/jira-acli-reference.md` §7)
 2. `git config branch.feature/<SUBTASK-KEY>-<slug>.parentbranch feature/<PARENT-KEY>-<slug>` (required for executor)
 3. Leave a PR-target comment on the sub-task.

**PR-target comment on the parent** (required for reviewer fallback on fresh clone):
After creating all sub-tasks in the multistep path, also post on the **parent issue** (not each sub-task) to record its PR target:
```
PR target branch: <BASE_BRANCH>. Worktree: <WORKTREES_DIR>/worktree-<PARENT-KEY>.
```
This mirrors the single-step format and ensures the reviewer's fallback can recover `<BASE_BRANCH>` even without `git config` (fresh clone or different machine).

**PR-target comment:**
After creating each leaf issue (the single top-level task, OR each sub-task), add a Jira comment recording the branch its PR should target and the worktree to run the executor in. Every leaf — single-step or sub-task — gets its own dedicated branch and PR; this comment is what tells the executor where that PR's base is.

*Example format for Single-step (Top-level issue):*
*"PR target branch: <BASE_BRANCH>. Worktree: <WORKTREES_DIR>/worktree-<PARENT-KEY>."*

*Example format for Multistep Sub-task:*
*"PR target branch: feature/<PARENT-KEY>-<slug>. Worktree: <WORKTREES_DIR>/worktree-<SUBTASK-KEY>."*

**CLI mechanics — things to never forget:**
- **Auth**: `acli` stores credentials after a one-time
  `acli jira auth login` (see `../_shared/jira-acli-reference.md` §0). No
  per-command token prefix — run commands bare. (Step 1's healthcheck
  above already verified auth.)
- **Project health check**: already verified by step 1's healthcheck. (If
  you're picking up from a re-run and skipped step 1, run
  `acli jira project list --paginate --json | grep -w <PROJECT-KEY>`
  first.)
- **Create issue**:
  `acli jira workitem create --project "<PROJECT-KEY>" --type "Task" --summary "..." --description-file <file>`
  Sub-tasks add `--type "Subtask"` and `--parent "<PARENT-KEY>"` (acli's
  `--parent` actually works on this project — see
  `../_shared/jira-acli-reference.md` §2 for the gotcha it fixes). Capture
  the returned key with `--json` (parse `key`), or grep it out of the text
  output (embedded in the returned browse URL). **Do not auto-assign** —
  ownership is left to board triage (see M4 above); omit `--assignee @me`
  unless your project opts in.
- `--yes` is **not** universal — `workitem create` and `comment create`
  reject it (`✗ Error: unknown flag: --yes`; they're non-interactive by
  default), so don't add `--yes` to either; `edit` / `transition` /
  `assign` / `delete` / `link create` / `create-bulk` do take it. See
  `../_shared/jira-acli-reference.md` §8 for the full `--yes` surface.
- Quote `"Subtask"` exactly (no hyphen — this project's real type name,
  confirmed in `../_shared/jira-acli-reference.md` §1).
- **Comment**: single-line —
  `acli jira workitem comment create --key <KEY> --body "<text>"`.
  Multi-line — write a temp file and use `--body-file <file>`
  (`--body-file -` / stdin does **not** work; see
  `../_shared/jira-acli-reference.md` §6).
- **Delete caveat**: `acli jira workitem delete --key <KEY> --yes`
  accepts `--yes`, so it *can* run unattended — but still never
  auto-delete; hand back the ready-to-paste command for the human to run
  (see `../_shared/jira-acli-reference.md` §8).
- Put investigation findings + acceptance criteria in the issue
  description (use `--description-file <file>` for anything beyond a
  sentence). `--description` / `--description-file` accept **plain text
  or ADF, not markdown** — a markdown body is stored verbatim as one
  plain-text paragraph (`##` / `-` show literally); see
  `../_shared/jira-acli-reference.md` §2.
- Make sure the branch you're branching *from* is committed/pushed
  before branching.

## 7. Report back

List: created issue key(s)/link(s); the scope decision (single-step vs multistep) and why; each branch created; and each worktree path together with the PR-target branch it's meant to merge into (explicitly calling out the parent worktree).

Post this same report to the user in chat **and** as a single Jira comment on the parent issue. Since it's multi-line, write it to a temp file and post it with `acli jira workitem comment create --key <PARENT-KEY> --body-file <file>` rather than an inline quoted `--body` string (see `../_shared/jira-acli-reference.md` §6 — `--body-file -` / stdin does not work):

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

Reference: `../_shared/jira-acli-reference.md` has the full command syntax,
confirmed issue type names, and git/branch conventions. The
`jira-sdlc-tools.env` (team-shared) and `jira-sdlc-tools.local.env`
(machine-specific) files in the project root have this repo's specific
values for every `<TOKEN>` used above.
