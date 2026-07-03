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
  these from `../_shared/project-config.md` before following the rest of
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

Run `git branch --show-current` and resolve the **parent key** (if any),
the **base branch** (what a brand-new top-level branch would start from),
and the **parent branch** (what new sub-task worktrees/PRs should target).

- Branch is exactly `<DEFAULT_BASE_BRANCH>` → no parent issue.
  `BASE_BRANCH = <DEFAULT_BASE_BRANCH>`. There's no parent branch yet —
  one may get created in step 6 if this turns out to be multistep.
- Branch matches `feature/<KEY>-...` or `hotfix/<KEY>-...` → extract
  `<KEY>`, then:
  - `jira issue view <KEY> --raw`, check `fields.issuetype.name` (CHECK
    this field path against real output once).
  - **`<KEY>` is `Sub-task`**: it can't be the parent. Read
    `fields.parent.key` to get the grandparent `<GP-KEY>` — that's the
    real parent. Everything created in this run becomes a sibling
    `Sub-task` of `<KEY>`, under `<GP-KEY>`. The current branch is `<KEY>`'s
    own branch, **not** the parent branch — find the real one instead:
    `git branch -a | grep <GP-KEY>`. Exactly one match → that's
    `PARENT_BRANCH`. Zero or multiple matches → don't guess, ask the user
    for the parent branch name.
  - **`<KEY>` is a top-level type** (`Task`/`Story`/`Bug`): it's the parent
    directly, and since branches are always named `feature/<KEY>-...`,
    `PARENT_BRANCH` = current branch.
  - `BASE_BRANCH` = current branch in both cases (only relevant if this run
    somehow still needs a *new* top-level branch, which it won't once a
    parent already exists from the branch).
- Any other branch name → ask the user whether to treat it as having a
  parent, rather than guessing.

## 2. Investigate

Search the codebase (Grep/Read/Glob) for relevant context: existing
related code, similar past patterns, affected modules. Don't ask the user
things you can find yourself.

## 3. Clarify

If anything material is ambiguous (scope, acceptance criteria, priority,
or whether it's actually a defect vs. new work), ask concise, specific
questions before creating anything. Don't proceed on guesses for anything
that would change what gets built.

## 4. Decide: single-step or multistep

This is the key planning call, and it's independent of whether step 1
found a parent:

- **Multistep** — the request breaks into genuinely independent,
  parallelizable pieces (e.g. backend API + frontend UI + tests, or
  several unrelated modules) that can be worked on *at the same time* in
  separate worktrees.
- **Single-step** — one cohesive piece of work, even if it touches several
  files. If piece B can only start once piece A finishes, that's one
  piece, not two — don't split purely sequential work.

Everything in step 6 follows mechanically from this decision plus step 1,
so don't skip it or guess silently — if it's not obvious from the
investigation, this is a question for step 3.

## 5. Pick the top-level issue type — only if step 1 found no parent

This skill assumes a two-level hierarchy — top-level types (`Task`,
`Story`, `Bug`) plus `Sub-task`, no `Epic`. Confirm against
`<HAS_EPIC_TYPE>` in `../_shared/project-config.md`; if your project does
use Epics, this step and the hierarchy checks in
`../_shared/jira-cli-reference.md` §1/§3 need extending before you rely on
this skill:
- Defect / regression / something broken → `Bug`
- New work, feature, or chore → `Task` or `Story` (ask the user which
  convention they use if it's not obvious from context)

If step 1 found a parent, skip this — anything created in this run is a
`Sub-task`.

## 6. Create the Jira issue(s), branch(es), and worktrees

Step 1 (parent or not) × step 4 (single vs multistep) gives five cases.
Every case ends with at least one `git worktree` — that's where work
actually happens. Sub-task issues never get their own dedicated parent
branch; only a brand-new top-level parent does.

**A. No parent + multistep:**
1. Create the parent `Task`/`Story`/`Bug` → capture `<PARENT-KEY>`.
2. `git branch feature/<PARENT-KEY>-<slug> <BASE_BRANCH>`, then
   `git push -u origin feature/<PARENT-KEY>-<slug>`. This is the new
   `PARENT_BRANCH`. It gets no worktree of its own — it only exists as the
   merge target for the sub-tasks' PRs.
3. Set parentbranch on the parent branch for consistency:
   `git config branch.feature/<PARENT-KEY>-<slug>.parentbranch BASE_BRANCH`
4. Create the `Sub-task`s under `<PARENT-KEY>`.
5. For each `<SUBTASK-KEY>`:
   - `git worktree add <WORKTREES_DIR>/worktree-<SUBTASK-KEY> -b feature/<SUBTASK-KEY>-<slug> PARENT_BRANCH`
   - `git config branch.feature/<SUBTASK-KEY>-<slug>.parentbranch PARENT_BRANCH` (required for `jira-task-executor` to resolve PR target)
6. Comment on each sub-task with its PR target — see the note below.

**B. No parent + single-step:**
1. Create the single `Task`/`Story`/`Bug` → `<KEY>`.
2. `git worktree add <WORKTREES_DIR>/worktree-<KEY> -b feature/<KEY>-<slug> BASE_BRANCH`
3. `git config branch.feature/<KEY>-<slug>.parentbranch BASE_BRANCH` (required for `jira-task-executor` to resolve PR target)
4. No dedicated parent branch — this issue's PR targets `BASE_BRANCH`
   directly. Comment on the issue with that PR target anyway, for
   consistency with the other three cases (see note below).

**C. Parent already existed (step 1) + multistep:**
1. Create the `Sub-task`s under `<PARENT-KEY>` (or under `<GP-KEY>` if step
   1 promoted to a sibling).
2. For each: 
   - `git worktree add <WORKTREES_DIR>/worktree-<SUBTASK-KEY> -b feature/<SUBTASK-KEY>-<slug> PARENT_BRANCH`
   - `git config branch.feature/<SUBTASK-KEY>-<slug>.parentbranch PARENT_BRANCH` (required for `jira-task-executor`)
3. Comment on each with PR target `PARENT_BRANCH`.

**D. Parent already existed + single-step:** same as C with exactly one
   `Sub-task` (same config command applies):
   - `git worktree add ...`
   - `git config branch.<branch-name>.parentbranch PARENT_BRANCH`

**E. Single-step with multiple subtasks (shared worktree):**
When the single-step decision produces multiple subtasks that can't be
parallelised (e.g. all touch the same files), they share one worktree
on the **parent branch** — no per-subtask worktrees or branches:

1. Create parent → `<PARENT-KEY>`.
2. `git branch feature/<PARENT-KEY>-<slug> <BASE_BRANCH>`, push it.
   This is `PARENT_BRANCH`.
3. `git config branch.feature/<PARENT-KEY>-<slug>.parentbranch BASE_BRANCH`
4. Create subtasks under `<PARENT-KEY>`.
5. One worktree on the parent branch:
   `git worktree add <WORKTREES_DIR>/worktree-<PARENT-KEY> PARENT_BRANCH`
6. Each subtask is a **smart commit** on the parent branch (see
   git-strategy section below).

**Git strategy — branch vs smart commit per leaf issue:**

Every leaf issue (the single task, or each subtask) must be annotated
with how its implementation should land in git. The assigner decides
this at issue-creation time, not the executor:

- **Smart commit** (commit directly on the worktree's current branch,
  no sub-branch): for small, focused fixes — a few lines, one
  function, a dead-variable removal. Smart-commit messages use the
  `<ISSUE-KEY> #done <description>` convention (see
  `../_shared/jira-cli-reference.md` §7a).
  → **Default when subtasks share a worktree** (case E). If a subtask
  is big enough to warrant its own branch, it should have gotten its
  own worktree in a multistep decision (cases A/C) instead.

- **Dedicated branch** (new branch inside the worktree, PR merges back
  into the worktree's branch): for larger, self-contained pieces —
  anything that touches multiple files, adds tests, or involves
  non-trivial logic where atomic reverting is valuable.
  → **Default when subtasks have separate worktrees** (cases A/C) —
  the branch already exists per step 6A/6C.
  → Also valid in shared-worktree scenarios when a subtask is
  significantly larger than its siblings (use judgment; document the
  reason in the Jira comment).

The assigner writes this decision into each leaf issue's PR-target
comment (see below), so the executor knows whether to branch or
smart-commit without re-deriving the logic.

**PR-target comment** (cases A–E): after creating each leaf issue, add a
Jira comment recording where its PR should go, *plus* the git strategy.
Example formats (using a generic example key and worktrees path — sub in
your own `<PROJECT-KEY>` and `<WORKTREES_DIR>`):

- Separate worktree (dedicated branch — cases A/C):
  *"PR target branch: feature/PROJ-200-xyz. Worktree: ../myapp-worktrees/worktree-PROJ-201. Git strategy: dedicated branch `feature/PROJ-201-fix-drag-speed`."*
- Shared worktree, smart commit (case E):
  *"PR target branch: feature/PROJ-291-path-calc-bugs. Shared worktree: ../myapp-worktrees/worktree-PROJ-291. Git strategy: smart commit on parent branch (few-line fix, no sub-branch)."*
- Shared worktree, exceptional dedicated branch (case E, large subtask):
  *"PR target branch: feature/PROJ-291-path-calc-bugs. Shared worktree: ../myapp-worktrees/worktree-PROJ-291. Git strategy: dedicated branch `feature/PROJ-293-resize-observer` (substantial refactor, warrants atomic PR)."*

This is what lets `jira-task-executor` (or a parallel subagent dropped
into that worktree) open its PR against the right branch without
re-deriving any of this logic.

**CLI mechanics** — see `../_shared/jira-cli-reference.md` for exact
syntax. Things to never forget:
- **Auth**: check whether `JIRA_API_TOKEN` is already set (`echo
  $JIRA_API_TOKEN`). If empty, prefix every `jira` command with
  `JIRA_API_TOKEN="$(cat <JIRA_TOKEN_PATH>)"` (see
  `../_shared/project-config.md` for `<JIRA_TOKEN_PATH>` — default
  `.jira/token.txt` — and jira-cli-reference.md §0).
- Use `--no-input` on every write command except `delete` (§8 — it doesn't
  support it), and quote `"Sub-task"` exactly (with the hyphen) when
  creating subtasks.
- For anything beyond a one-line description, write the body to a file
  and use `--template <file>` instead of inline `-b"..."` — inline has
  been observed to hang for ~2 minutes on longer text.
- Comment syntax (`jira issue comment add <KEY> ...`) is fully covered
  in `../_shared/jira-cli-reference.md` §6: use `jira issue comment add
  <KEY> "<text>"` for single-line, or heredoc `cat <<'EOF' | jira issue
  comment add <KEY> --template -` for multi-line/markdown; there is no
  `-m` flag.
- Put investigation findings + acceptance criteria in the issue
  description.
- Before branching, make sure the branch you're branching *from*
  (`BASE_BRANCH` or `PARENT_BRANCH`) is committed/pushed, so every new
  branch starts from a consistent, known point.

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
confirmed issue type names, and git/branch conventions. `../_shared/project-config.md`
has this repo's specific values for every `<TOKEN>` used above.
