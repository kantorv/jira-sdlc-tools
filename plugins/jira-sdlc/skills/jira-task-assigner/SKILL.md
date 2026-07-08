---
name: jira-task-assigner
description: Turn a feature/task/bug description into Jira issues, with matching git branches and worktrees set up so the pieces can be worked on in parallel. Detects an implied parent from the current git branch, investigates the codebase, asks clarifying questions, decides whether the request is a single self-contained task or a multistep task that should be split into parallel sub-tasks, creates the Jira issue(s) via jira-cli, creates a branch per top-level/parent issue, and creates a `git worktree` per leaf issue (the single task, or each sub-task) so parallel work can start immediately. Every leaf issue gets its own dedicated branch and worktree, so the executor always opens an individual PR per leaf.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are acting as a technical project manager for the **`<PROJECT-KEY>`**
project. Given a task description from the user ($ARGUMENTS):

**Conventions used below:**
- `<PROJECT-KEY>`, `<WORKTREES_DIR>`, `<DEFAULT_BASE_BRANCH>` — resolve
  these from `jira-tools-plugin.env` in the project root before following the rest of
  this skill.
- `<WORKTREES_DIR>` — relative to project root — already exists, don't
  create it. **Run this check from the repo root:** `ls <WORKTREES_DIR>` and
  verify the exit code is 0 before using it; if it's missing (non-zero exit),
  stop and ask rather than `mkdir`-ing a new one (the convention may have
  changed).
- `<slug>` = short kebab-case summary of the issue title, same style as
  existing branches in this repo.
- Branch naming is **always** `feature/<KEY>-<slug>` (`hotfix/<KEY>-<slug>`
  for a production bugfix) whether `<KEY>` is a top-level issue or a
  Sub-task — this keeps the branch-parsing regex in step 1 working no
  matter which branch someone checks out later.

## 1. Determine context from the current branch

Run `git branch --show-current` to determine your starting point.

- **Branch is exactly `<DEFAULT_BASE_BRANCH>`**: 
  `BASE_BRANCH = <DEFAULT_BASE_BRANCH>`. Proceed to investigate and plan the work.
- **Branch matches `feature/<KEY>-...` or `hotfix/<KEY>-...`**: 
  **STOP.** Running this skill from an existing issue branch is currently not supported. Tell the user to checkout the base branch first. 
  *(TBD: Add instructions for starting from an issue branch, parsing existing sub-tasks, and appending new parallel work).*
- **Any other branch name**: 
  Ask the user whether to treat it as a base branch or abort. Do not guess.

## 2. Fail-fast health check (before any planning work)

Before investigating or creating anything, verify the environment is configured correctly:
- **Auth check**: run `JIRA_API_TOKEN="$(cat <JIRA_TOKEN_PATH>)" jira me` — it should print your account email. If it fails, the token is invalid or the path is wrong.
- **Project health check**: run `jira project list | grep -w <PROJECT-KEY>` to confirm the configured project key exists and is accessible as a whole-word match (avoids partial matches like `PROJ` matching `PROJ2`). If nothing matches, stop — the project key may be wrong, the token may be scoped to a different board, or the bot may not have been granted access to the board.

## 3. Investigate

Search the codebase (Grep/Read/Glob) for relevant context: existing
related code, similar past patterns, affected modules. Don't ask the user
things you can find yourself.

## 4. Clarify

If anything material is ambiguous (scope, acceptance criteria, priority,
or whether it's actually a defect vs. new work), ask concise, specific
questions before creating anything. Don't proceed on guesses for anything
that would change what you build.


## 5. Decide: Branch Context, Scope, and Issue Type

First, verify your current branch context using `git branch --show-current`.

**1. Called from base branch** (e.g., `<DEFAULT_BASE_BRANCH>`, `development`, or `main`): 
Proceed with planning the work. 

**2. Called from a feature/hotfix branch** (an existing Jira issue exists):
**Stop immediately.** Explain to the user that creating sub-tasks or parallelizing work from an already existing feature branch is currently not supported. Do not create any Jira issues, branches, or worktrees.

If you are in **Case 1** (base branch), make the following two decisions before moving to setup:

**A. Decide Scope: single-step or multistep**
- **Multistep** — the request breaks into genuinely independent, parallelizable pieces (e.g. backend API + frontend UI + tests) that can be worked on *at the same time* in separate worktrees.
- **Single-step** — one cohesive piece of work, even if it touches several files. If piece B can only start once piece A finishes, that's one piece, not two — don't split purely sequential work.

**B. Pick the top-level issue type**
There is no `Epic` level — `Task`, `Story`, and `Bug` are the top-level types (peers), with `Sub-task` underneath. Your top-level options are `Task`, `Story`, or `Bug`.
- Defect / regression / something broken → `Bug`.
- New work, feature, or chore → If the user did not explicitly tell you which to use, **decide based on the complexity of the task**. Use a `Story` for larger, multi-faceted requests that deliver end-to-end user value, and use a `Task` for smaller, localized, or strictly technical chores.
- **Scope (A) and issue type (B) are independent** — scope is about *can the pieces run at the same time*; issue type is about *size/value of the whole*. A multistep `Task` of parallel technical chores is valid; a single-step `Story` is valid.

## 6. Create the Jira issue(s), branch(es), and worktrees

Because you aborted in Step 1 if an existing parent was found, you are always creating a brand-new top-level issue. By always provisioning a worktree for this top-level issue, the setup becomes a single, unified flow regardless of your scope decision.

**Re-run / partial-failure safety check (M3):** Before creating anything, check for a half-created parent from a previous failed run:
- `ls <WORKTREES_DIR>/worktree-<PARENT-KEY>` (check exit code)
- `git branch -a | grep -E "feature/<PARENT-KEY>-|hotfix/<PARENT-KEY>-"`
If either exists, **stop and surface the cleanup command** for the user to run manually (consistent with the repo's never-auto-delete stance) — do not proceed to create a second parent:
```
rm -rf <WORKTREES_DIR>/worktree-<PARENT-KEY>
git branch -D feature/<PARENT-KEY>-<slug>  # or hotfix/...
git push origin --delete feature/<PARENT-KEY>-<slug>  # if branch was pushed
JIRA_API_TOKEN="$(cat <JIRA_TOKEN_PATH>)" jira issue delete <PARENT-KEY>
```

**A. Create the Top-Level Issue, Branch, and Worktree (Always)**
1. Create the `Task`/`Story`/`Bug` → `<PARENT-KEY>`. (If single-step, this is your only issue).
   - **Assignment (M4):** This repo **does not auto-assign** created issues — ownership is left to board triage. Do not add `-a$(jira me)` on creation. If your project wants auto-assignment, add the flag and update this note.
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
   (use `hotfix/<SUBTASK-KEY>-<slug>` instead when the top-level issue is a `Bug` — see the nesting rule in `../_shared/jira-cli-reference.md` §7)
2. `git config branch.feature/<SUBTASK-KEY>-<slug>.parentbranch feature/<PARENT-KEY>-<slug>` (required for executor)
3. Leave a PR-target comment on the sub-task.

**PR-target comment:**
After creating each leaf issue (the single top-level task, OR each sub-task), add a Jira comment recording the branch its PR should target and the worktree to run the executor in. Every leaf — single-step or sub-task — gets its own dedicated branch and PR; this comment is what tells the executor where that PR's base is.

*Example format for Single-step (Top-level issue):*
*"PR target branch: <BASE_BRANCH>. Worktree: <WORKTREES_DIR>/worktree-<PARENT-KEY>."*

*Example format for Multistep Sub-task:*
*"PR target branch: feature/<PARENT-KEY>-<slug>. Worktree: <WORKTREES_DIR>/worktree-<SUBTASK-KEY>."*

**CLI mechanics — things to never forget:**
- **Auth**: check whether `JIRA_API_TOKEN` is already set (`echo $JIRA_API_TOKEN`). If empty, prefix every `jira` command with `JIRA_API_TOKEN="$(cat <JIRA_TOKEN_PATH>)"`.
- **Project health check**: before the first `jira issue create`, run `jira project list | grep -w <PROJECT-KEY>` to confirm the configured project key exists and is accessible as a whole-word match. If nothing matches, stop — the project key may be wrong, the token may be scoped to a different board, or the bot may not have been granted access to the board.
- Use `--no-input` on every write command except `delete`. Quote `"Sub-task"` exactly (with the hyphen).
- For anything beyond a one-line description, write the body to a file and use `--template <file>` instead of inline `-b"..."`.
- Comment syntax: use `jira issue comment add <KEY> "<text>"` for single-line, or heredoc `cat <<'EOF' | jira issue comment add <KEY> --template -` for multi-line.
- Put investigation findings + acceptance criteria in the issue description.
- Make sure the branch you're branching *from* is committed/pushed before branching.

## 7. Report back

List: created issue key(s)/link(s); the scope decision (single-step vs multistep) and why; each branch created; and each worktree path together with the PR-target branch it's meant to merge into (explicitly calling out the parent worktree).

Post this same report to the user in chat **and** as a single Jira comment on the parent issue. Since it's multi-line, pipe it in rather than using an inline quoted `-b`/comment string (same `--template -` stdin pattern as issue creation, see `../_shared/jira-cli-reference.md` §6):

## 8. Don't start implementation work, but do leave worktrees ready

Creating the worktrees above is environment setup, not implementation —
that boundary still holds: don't write code, commit, or open a PR here.
Once the worktrees exist, point the user (or a parallel subagent per
worktree) at `/jira-sdlc:jira-task-executor <KEY>` to actually do the
work in each one (adjust the `jira-sdlc:` prefix if you renamed the
plugin, or drop it entirely if you installed these skills as loose files
rather than as a plugin). Merging the parent branch back into its own
base once all sub-tasks land is likewise out of scope for this skill.

Reference: `../_shared/jira-cli-reference.md` has the full command syntax,
confirmed issue type names, and git/branch conventions. The `jira-tools-plugin.env` file in the
project root has this repo's specific values for every `<TOKEN>` used above.
