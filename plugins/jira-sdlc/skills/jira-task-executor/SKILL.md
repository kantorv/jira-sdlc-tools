---
name: jira-task-executor
description: Given a Jira issue key, picks it up end-to-end — branch, status transition, codebase investigation, implementation, tests, commit, push, and PR — then reports back the PR link and updated Jira status.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

You are acting as the engineer picking up a single Jira issue end-to-end.
Given an issue key ($ARGUMENTS, e.g. `PROJ-278`):

1. **Fetch the issue** — `jira issue view <KEY> --raw` (auth per
   `../_shared/jira-cli-reference.md` §0). Pull out: summary, description,
   issue type, current status, and parent (if any).
   - Also check `fields.subtasks` (CHECK this field path against real
     output once). If it's non-empty, `<KEY>` is a coordinating parent
     issue, not a leaf — `jira-task-assigner` creates these specifically
     as merge targets for its sub-tasks' PRs, not as something meant to
     be implemented on directly. Confirm with the user that they really
     want to implement on the parent itself before continuing.
   - **Read the git strategy** from the issue's comments (posted by
     `jira-task-assigner`). Look for a line matching `Git strategy: ...`
     in any comment. Two possibilities:
     - *"Smart commit on `<parent-branch>`"* → don't create a new
       branch; commit directly on the worktree's current branch using a
       Smart Commit message (§7a of `jira-cli-reference.md`). No
       individual PR — the parent branch gets one PR for all subtasks.
     - *"Dedicated branch `<branch-name>`"* → create (or resume) the
       named branch and open an individual PR against the parent branch.
     If no `Git strategy:` comment exists, fall back to the generic rule
     in `jira-cli-reference.md` §7 (few-line fix → smart commit,
     anything bigger → new branch).

2. **Branch setup** (depends on git strategy from step 1):
   - Capture the branch you're starting from:
     `STARTING_BRANCH=$(git branch --show-current)`. Whether this ends up
     being the PR's base or not depends on which path below you take —
     it's the base only in the "create a fresh branch" case; in the
     resumed-work or smart-commit cases, the real base comes from
     recovering the existing branch's own recorded parent instead.
   - **If running from a worktree** (`[ -f .git ]` — in a worktree `.git`
     is a file, not a directory): first confirm this worktree actually
     belongs to `<KEY>` or its parent — `STARTING_BRANCH` should contain
     `<KEY>` or a parent key from the same issue family. If it doesn't
     match either, stop and ask rather than assuming; this worktree wasn't
     set up for this issue, and merging or branching from it on that
     assumption could land work in the wrong place.
     - The worktree's branch may be behind the branch it was created
       from. Look that up the same way parent branches are tracked
       elsewhere in this skill:
       `git config branch."$STARTING_BRANCH".parentbranch`.
       - If found → bring the worktree branch up to date before doing
         anything else: `git merge <that-branch> --no-edit`. If this
         produces conflicts, stop and ask the user to resolve them —
         don't attempt to resolve merge conflicts automatically.
       - If not set (this worktree branch wasn't created by this skill,
         or predates this convention) → skip the merge, but flag in the
         final report that you proceeded on a possibly-stale worktree
         branch.
   - **If git strategy is "smart commit on parent branch"**:
     Stay on `STARTING_BRANCH` — do not create a new branch. This issue
     is one of several subtasks sharing a worktree; each will commit
     directly on the parent branch. Record the parent for PR targeting:
     `PR_BASE=$(git config branch."$STARTING_BRANCH".parentbranch)`.
     Skip the rest of this step and go to step 3.
   - `git fetch origin` then `git branch -a | grep <KEY>` to check whether
     a branch for this issue already exists, local or remote.
   - **If it exists** → check it out (resumed work — don't create a second
     branch for the same issue). Recover its parent via
     `git config branch."<branch-name>".parentbranch` — if that's unset
     (branch predates this convention, or wasn't created by this skill),
     ask the user which branch the PR should target rather than guessing.
   - **If not** → this is a fresh branch, so first work out the prefix
     (only needed on this path — an existing branch already has its
     prefix baked into its name):
     - `<KEY>` is `Task`/`Story` → `feature/`.
     - `<KEY>` is `Bug` → `hotfix/`.
     - `<KEY>` is `Sub-task` → look at its parent's type instead (one
       level up is always top-level — see the nesting rule in
       `../_shared/jira-cli-reference.md` §3) and use *that* type to pick
       feature/hotfix.
     - Branch from `$STARTING_BRANCH` (now up to date, if this was a
       worktree) directly —
       `git checkout -b <prefix>/<KEY>-<slugified-summary>` (naming
       convention per `../_shared/jira-cli-reference.md` §7b).
     - Record the parent for later (this run, and any future resumed
       session): `git config branch."<new-branch-name>".parentbranch "$STARTING_BRANCH"`.
     - Also post the same durable fallback `jira-task-assigner` posts for
       issues it creates, so the PR target survives even if this local
       config is ever unreadable later (fresh clone, different machine):
       `jira issue comment add <KEY> "PR target branch: $STARTING_BRANCH."` — single-line form; for multi-line/markdown comments use `cat <<'EOF' | jira issue comment add <KEY> --template -` (see `../_shared/jira-cli-reference.md` §6 for full comment syntax).

3. **Transition the issue** to in-progress:
   `jira issue move <KEY> "<STATUS_IN_PROGRESS>"` (see
   the `.env` file in the project root for the confirmed status name for this
   project — default example `In Progress`).

4. **Investigate** — read the affected code (Grep/Read/Glob) before
   writing anything. Understand existing patterns, not just the issue text.

5. **Clarify** — if the issue's description/acceptance criteria leaves
   something materially ambiguous (an implementation choice that would
   change the result), ask the user before writing code. Don't guess on
   anything that matters.

6. **Implement** the change.

7. **Test before committing:**
   - If the change needs test coverage that doesn't already exist, add the
     test(s) to the relevant suite file first.
   - Run each new/affected test individually, one at a time — don't move
     to the next one until the current one passes. Use
     `<TEST_SINGLE_CMD>` from the `.env` file in the project root (the default
     example there runs a Playwright test by line number:
     `yarn playwright test tests/mysuite.ts:555`).
   - Once every individual test passes, run the whole affected suite to
     catch regressions: `<TEST_SUITE_CMD>` from the same config (default
     example: `yarn playwright test tests/mysuite.ts`).
   - **If the full suite run reports failures, don't treat that as final**
     — timing/flakiness can fail a test that's actually fine on its own.
     Re-run just the failed tests individually (not the
     whole suite again):
     - If they pass individually → treat the suite as passing overall.
       Don't re-run the whole suite a second time.
     - If an individually re-run test fails again → stop. Report the
       failure and wait for instructions — don't commit, push, or open a
       PR, and don't keep retrying on your own.
   - If `<TEST_SINGLE_CMD>` isn't set to something your runner actually
     supports (e.g. it can't select by line number), select by test
     name/pattern instead — the policy above (individually, then suite,
     then re-run only failures before trusting a red suite) matters more
     than the exact invocation.

8. **Commit** — format depends on the git strategy from step 1:
   - **Smart commit** (shared worktree): use the Smart Commit message
     format so GitHub-for-Jira auto-transitions the issue:
     `git commit -m "<KEY> #done <short message>"`. See
     `../_shared/jira-cli-reference.md` §7a for the full syntax and
     caveats (e.g. `#done` requires `<STATUS_DONE>` to be the actual
     workflow status name — check the `.env` file).
   - **Dedicated branch**: `git commit -m "<KEY> <short message>"`.
     Split into multiple commits if the change has logically separate
     pieces; one is fine for a small change.

9. **Push** — depends on the git strategy from step 1:
   - **Smart commit** (shared worktree): skip push. Other subtasks may
     still be pending on this branch; pushing after every commit would
     create noise and half-done states on the remote. The user (or a
     later run after all subtasks land) will push the parent branch once.
   - **Dedicated branch**: `git push -u origin <branch-name>`.

10. **Open a PR — only for dedicated-branch strategy:**
    - **Smart-commit strategy**: skip this step entirely. This subtask
      is one of several sharing a parent branch; the parent branch gets
      a single PR once all subtasks are done. Don't push or open a PR
      here — just ensure the commit is on the parent branch. The user
      (or a later run) will push the parent branch and open one PR for
      the whole group.
    - **Dedicated-branch strategy**: proceed as follows:
      - Determine the base:
        `PR_BASE=$(git config branch."$(git branch --show-current)".parentbranch)`
        — this is whatever was checked out *before* this issue's branch was
        created.
    - If that comes up empty, don't go straight to `<DEFAULT_BASE_BRANCH>`
      — try the durable fallback first: `jira issue view <KEY>` and look
      through its comments for a `PR target branch: <branch>` line (the
      one this skill, or `jira-task-assigner`, posts when first creating
      the branch). Use that as `PR_BASE` if found.
    - Only fall back to `<DEFAULT_BASE_BRANCH>` (see
      the `.env` file in the project root) if *both* the local config and the
      Jira comment come up empty, and say so explicitly in the final
      report if you had to.
    - Try to get the issue's canonical URL via `jira open <KEY> --no-browser`
      (CHECK: expected to print the URL instead of opening it — confirm
      once) to link back to it in the PR body, rather than hardcoding the
      Jira site domain anywhere.
    - `gh pr create --base "$PR_BASE" --title "<KEY>: <summary>" --body "<what changed + link to the issue>" --label <semver-label>`.
      The `--label` flag is **required** — the repo's semver-based release
      workflow reads it to decide the next version bump. Pick the label by
      what the PR actually changes in the app's semantics (these three
      names assume the `<SEMVER_LABELS>` default from the `.env` file
      — adjust if yours differ):
      - `patch` — bug fixes, small internal improvements, no new
        functionality or breaking changes
      - `minor` — new features or non-breaking enhancements
      - `major` — breaking changes (API removals, behaviour reversals)
      Labels must already exist in the repo (confirm with
      `gh api repos/<org>/<repo>/labels --jq '.[].name'`).
    - If `gh` isn't installed or not authenticated, don't fail silently —
      report that, and give the user the compare URL instead:
      `https://github.com/<org>/<repo>/compare/$PR_BASE...<branch-name>?expand=1`
      (get `<org>/<repo>` from `git remote get-url origin`).

11. **Update Jira — status only, no comment yet:**
    - **Don't transition the status here.** Leave it as
      `<STATUS_IN_PROGRESS>` — moving to "In Review"/"Done" happens
      automatically (via GitHub-for-Jira's merge automation) once the PR
      is merged. Transitioning it manually here would fight that
      automation, not help it.

12. **Report back** — branch name, what was implemented, test results,
    commit(s), the PR link, and the issue's new status. Post this same
    report to the user in chat **and** as a single Jira comment — don't
    post a separate short "PR opened" comment earlier, this is the one
    comment for the whole run. Since it's multi-line, **always pipe via
    heredoc to `--template -`** (see `../_shared/jira-cli-reference.md`
    §6 for all comment variants: single-line positional, multi-line
    heredoc, and stdin pipe). Never wrap markdown in an quoted inline
    string — backticks are interpreted as command substitution:
    ```
    cat <<'EOF' | jira issue comment add <KEY> --template -
    <the same report content shown to the user>
    EOF
    ```

Reference: `../_shared/jira-cli-reference.md` has the full jira-cli syntax,
confirmed issue types, and git/branch conventions this skill depends on.
The `.env` file in the project root has this repo's specific values for every
`<TOKEN>` used above.
