---
name: jira-task-assigner
description: Turn a feature/task/bug description into Jira issues, with matching git branches and worktrees set up so the pieces can be worked on in parallel. Detects an implied parent from the current git branch, investigates the codebase, asks clarifying questions, decides whether the request is a single self-contained task or a multistep task that should be split into parallel sub-tasks, creates the Jira issue(s) via jira-cli, creates a branch per top-level/parent issue, and creates a `git worktree` per leaf issue (the single task, or each sub-task) so parallel work can start immediately. Also decides and records per-issue git strategy (dedicated branch vs smart commit) so the executor knows how to land each change.
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
  create it. Just confirm with `ls <WORKTREES_DIR>` before using it; if
  it's missing, stop and ask rather than `mkdir`-ing a new one (the
  convention may have changed).
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

## 2. Investigate

Search the codebase (Grep/Read/Glob) for relevant context: existing
related code, similar past patterns, affected modules. Don't ask the user
things you can find yourself.

## 3. Clarify

If anything material is ambiguous (scope, acceptance criteria, priority,
or whether it's actually a defect vs. new work), ask concise, specific
questions before creating anything. Don't proceed on guesses for anything
that would change what gets built.


## 4. Decide: Branch Context, Scope, and Issue Type

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
Confirm against `<HAS_EPIC_TYPE>` in `jira-tools-plugin.env`. Your top-level options are `Task`, `Story`, or `Bug`.
- Defect / regression / something broken → `Bug`.
- New work, feature, or chore → If the user did not explicitly tell you which to use, **decide based on the complexity of the task**. Use a `Story` for larger, multi-faceted requests that deliver end-to-end user value, and use a `Task` for smaller, localized, or strictly technical chores.

## 5. Create the Jira issue(s), branch(es), and worktrees

Because you aborted in Step 1 if an existing parent was found, you are always creating a new top-level issue here. Your setup depends entirely on your scope decision in Step 4.

**A. Multistep (Parallelizable):**
1. Create the parent `Task`/`Story`/`Bug` → capture `<PARENT-KEY>`.
2. `git branch feature/<PARENT-KEY>-<slug> <BASE_BRANCH>`, then `git push -u origin feature/<PARENT-KEY>-<slug>`. This is the new `PARENT_BRANCH`. It gets no worktree of its own — it only exists as the merge target for the sub-tasks' PRs.
3. Set parentbranch on the parent branch for consistency:
   `git config branch.feature/<PARENT-KEY>-<slug>.parentbranch BASE_BRANCH`
4. Create the `Sub-task`s under `<PARENT-KEY>`.
5. For each `<SUBTASK-KEY>`:
   - `git worktree add <WORKTREES_DIR>/worktree-<SUBTASK-KEY> -b feature/<SUBTASK-KEY>-<slug> PARENT_BRANCH`
   - `git config branch.feature/<SUBTASK-KEY>-<slug>.parentbranch PARENT_BRANCH` (required for `jira-task-executor` to resolve PR target)
6. Comment on each sub-task with its PR target (see note below).

**B. Single-step (Cohesive work):**
1. Create the single `Task`/`Story`/`Bug` → `<KEY>`.
2. `git worktree add <WORKTREES_DIR>/worktree-<KEY> -b feature/<KEY>-<slug> BASE_BRANCH`
3. `git config branch.feature/<KEY>-<slug>.parentbranch BASE_BRANCH` (required for `jira-task-executor` to resolve PR target)
4. No dedicated parent branch — this issue's PR targets `BASE_BRANCH` directly. Comment on the issue with that PR target anyway (see note below).

**Git strategy — branch vs smart commit per leaf issue:**
Every leaf issue (the single task, or each subtask) must be annotated with how its implementation should land in git. The assigner decides this at issue-creation time:

- **Dedicated branch** (new branch inside the worktree, PR merges back into the worktree's branch): **Default behavior.** Used for larger, self-contained pieces — anything that touches multiple files, adds tests, or involves non-trivial logic.
- **Smart commit** (commit directly on the worktree's current branch, no sub-branch): Exceptional case for small, focused fixes (e.g., a few lines, one function). Messages use `<ISSUE-KEY> #done <description>`.

**PR-target comment** (cases A & B): after creating each leaf issue, add a Jira comment recording where its PR should go, *plus* the git strategy. 
Example format:
*"PR target branch: feature/PROJ-200-xyz. Worktree: ../myapp-worktrees/worktree-PROJ-201. Git strategy: dedicated branch `feature/PROJ-201-fix-drag-speed`."*

**CLI mechanics — things to never forget:**
- **Auth**: check whether `JIRA_API_TOKEN` is already set (`echo $JIRA_API_TOKEN`). If empty, prefix every `jira` command with `JIRA_API_TOKEN="$(cat <JIRA_TOKEN_PATH>)"`.
- Use `--no-input` on every write command except `delete`. Quote `"Sub-task"` exactly (with the hyphen).
- For anything beyond a one-line description, write the body to a file and use `--template <file>` instead of inline `-b"..."`.
- Comment syntax: use `jira issue comment add <KEY> "<text>"` for single-line, or heredoc `cat <<'EOF' | jira issue comment add <KEY> --template -` for multi-line.
- Put investigation findings + acceptance criteria in the issue description.
- Make sure the branch you're branching *from* is committed/pushed before branching.

## 7. Report back

List: created issue key(s)/link(s); the scope decision (single-step vs
multistep) and why; which parent (if any) was used and why; each branch
created; and each worktree path together with the PR-target branch it's
meant to merge into.

Post this same  report to the user in chat **and** as a single Jira comment. Since it's multi-line, pipe it in rather
than using an inline quoted `-b`/comment string (same `--template -`
stdin pattern as issue creation, see `../_shared/jira-cli-reference.md`
§6):

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
confirmed issue type names, and git/branch conventions. The `.env` file in the
project root has this repo's specific values for every `<TOKEN>` used above.
