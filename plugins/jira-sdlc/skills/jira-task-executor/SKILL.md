---
name: jira-task-executor
description: Given a Jira issue key, picks it up end-to-end — branch, status transition, codebase investigation, implementation, tests, commit, push, and PR — then reports back the PR link and updated Jira status.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

You are acting as the engineer picking up a single Jira issue end-to-end.
Given an issue key ($ARGUMENTS, e.g. `PROJ-278`):

1. **Fetch the issue** — `acli jira workitem view <KEY> --json --fields '*all'`
   (auth per `../_shared/jira-acli-reference.md` §0). Pull out: summary,
   description, issue type, current status, and parent (if any).
   - Also check `fields.subtasks` (the default `--json` *omits* subtasks,
     so `--fields '*all'` is required here — see
     `../_shared/jira-acli-reference.md` §3):
     - **Non-empty** → `<KEY>` is a multistep parent — a merge target
       for its sub-tasks' PRs, not something to implement on directly.
       Confirm with the user that they really want to implement on the
       parent itself before continuing.
     - **Empty** → `<KEY>` is a leaf: either a sub-task, or a
       single-step top-level issue the assigner provisioned for direct
       implementation (its own worktree + dedicated branch, PR targeting
       the base branch). Proceed normally.
   - Every leaf gets its own dedicated branch and opens its own PR (no
     per-issue strategy to read). The PR's base comes from the
     `PR target branch: ...` Jira comment posted by `jira-task-assigner`,
     read in step 10 below.

2. **Branch setup:**
   - Capture the branch you're starting from:
     `STARTING_BRANCH=$(git branch --show-current)`. Whether this ends up
     being the PR's base or not depends on which path below you take —
     it's the base only in the "create a fresh branch" case; in the
     resumed-work case, the real base comes from recovering the existing
     branch's own recorded parent instead.
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
   - `git fetch origin` then `git branch -a | grep <KEY>` to check whether
     a branch for this issue already exists, local or remote. The
     assigner pre-creates the branch and worktree for every leaf issue,
     so the "exists" path below is the normal one; "not" is a fallback
     for issues created without the assigner.
   - **If it exists** → check it out (the assigner pre-created it, or
     this is resumed work — either way, don't create a second branch for
     the same issue). Recover its parent via
     `git config branch."<branch-name>".parentbranch` — if that's unset
     (branch predates the parentbranch convention, or wasn't created by
     this skill), ask the user which branch the PR should target rather
     than guessing.
   - **If not** → this only happens for issues created without the
     assigner, so first work out the prefix (only needed on this path —
     an existing branch already has its prefix baked into its name):
     - `<KEY>` is `Task`/`Story` → `feature/`.
     - `<KEY>` is `Bug` → `hotfix/`.
     - `<KEY>` is `Subtask` → look at its parent's type instead (one
       level up is always top-level — see the nesting rule in
       `../_shared/jira-acli-reference.md` §7) and use *that* type to pick
       feature/hotfix.
     - Branch from `$STARTING_BRANCH` (now up to date, if this was a
       worktree) directly —
       `git checkout -b <prefix>/<KEY>-<slugified-summary>` (naming
       convention per `../_shared/jira-acli-reference.md` §7).
     - Record the parent for later (this run, and any future resumed
       session): `git config branch."<new-branch-name>".parentbranch "$STARTING_BRANCH"`.
     - Also post the same durable fallback `jira-task-assigner` posts for
       issues it creates, so the PR target survives even if this local
       config is ever unreadable later (fresh clone, different machine):
       `acli jira workitem comment create --key <KEY> --body "PR target branch: $STARTING_BRANCH."` — single-line form; for multi-line/markdown comments write a temp file and use `--body-file <file>` (see `../_shared/jira-acli-reference.md` §6 for full comment syntax).

3. **Transition the issue** to in-progress:
   `acli jira workitem transition --key <KEY> --status "<STATUS_IN_PROGRESS>" --yes` (see
   `jira-tools-plugin.env` in the project root for the confirmed status name for this
   project — default example `In Progress`).

4. **Investigate** — read the affected code (Grep/Read/Glob) before
   writing anything. Understand existing patterns, not just the issue text.

5. **Clarify** — if the issue's description/acceptance criteria leaves
   something materially ambiguous (an implementation choice that would
   change the result), ask the user before writing code. Don't guess on
   anything that matters.

6. **Implement** the change.

7. **Test before committing:**
   - **Testing is project-local — find the project's instructions
     first.** Which runner a project uses, how it selects a single
     test, and how it runs the whole suite all vary too much to ship a
     plugin default that isn't wrong for most setups. Look for a
     `CLAUDE.md`, `AGENTS.md`, "Tests" section in `README.md`, or
     similar in the repo root.
     - **If the project docs cover both forms (run a single test, run
       the full suite)** → use those commands throughout the rest of
       this step.
     - **If no such docs exist** in this project, ask the user
       explicitly whether to install a test runner and the testing
       dependencies now. This is its own task; don't decide on their
       behalf.
       - If they say yes → once everything's in, fold the discovered
         "run one test" / "run full suite" commands into `CLAUDE.md` /
         `AGENTS.md` so the next session doesn't have to re-derive
         them.
       - If they say no, or this stack genuinely has no test layer →
         skip the rest of this step. Note in the final report that
         testing was skipped and why, then continue to step 8
         (commit).
     - **Tests exist in the project but the one-vs-suite commands
       aren't documented** (e.g. CI runs them, `package.json` has
       scripts, but no `CLAUDE.md`/`AGENTS.md` line tells you how):
       discover them — inspect `package.json` scripts, `Makefile`
       targets, README sections, and CI config — and sanity-check each
       candidate (`--listTests`, a dry run, or one trivial pass)
       before relying on it. **Suggest** (don't silently edit) that
       the user add the resulting "run one test" and "run full suite"
       commands to `CLAUDE.md` / `AGENTS.md`, so the next session
       skips the discovery dance.
   - **For the change at hand:** if test coverage exists already,
     identify the affected tests; if it doesn't, add the new test(s)
     to the relevant suite file first.
   - **Run each new/affected test individually, one at a time** —
     don't move on until the current one passes. Use the project's
     documented single-test command. If that command selects by line
     number but your runner doesn't actually support it, filter by
     name or pattern instead — the policy below matters more than
     the exact invocation.
   - **Once every individual test passes, run the whole affected
     suite** to catch regressions, using the project's documented
     full-suite command.
   - **If the full suite run reports failures, don't treat that as
     final** — timing/flakiness can fail a test that's actually fine
     on its own. Re-run just the failed tests individually (not the
     whole suite again):
     - If they pass individually → treat the suite as passing
       overall. Don't re-run the whole suite a second time.
     - If an individually re-run test fails again → stop. Report the
       failure and wait for instructions — don't commit, push, or open
       a PR, and don't keep retrying on your own.

8. **Commit** — `git commit -m "<KEY> <short message>"`. Split into
   multiple commits if the change has logically separate pieces; one is
   fine for a small change.

9. **Push** — `git push -u origin <branch-name>`.

10. **Open a PR:**
    - Determine the base:
      `PR_BASE=$(git config branch."$(git branch --show-current)".parentbranch)`
      — this is whatever was checked out *before* this issue's branch was
      created.
    - If that comes up empty, don't go straight to `<DEFAULT_BASE_BRANCH>`
      — try the durable fallback first: `acli jira workitem comment list --key <KEY> --json`
      and look through its comments for a `PR target branch: <branch>` line (the
      one this skill, or `jira-task-assigner`, posts when first creating
      the branch). Use that as `PR_BASE` if found.
    - Only fall back to `<DEFAULT_BASE_BRANCH>` (see
      `jira-tools-plugin.env` in the project root) if *both* the local config and the
      Jira comment come up empty, and say so explicitly in the final
      report if you had to.
    - Build the issue's canonical URL as `https://<JIRA_ACCOUNT_URL>/browse/<KEY>`
      (`<JIRA_ACCOUNT_URL>` comes from `jira-tools-plugin.env` in the
      project root — acli has no browse-URL subcommand, so construct the
      link from the token) to link back to it in the PR body, rather than
      hardcoding the Jira site domain anywhere.
    - `gh pr create --base "$PR_BASE" --title "<KEY>: <summary>" --body "<what changed + link to the issue>" --label <semver-label>`.
      The `--label` flag is **required** — the repo's semver-based release
      workflow reads it to decide the next version bump. Pick the label by
      what the PR actually changes in the app's semantics (these three
      names assume the `<SEMVER_LABELS>` default from `jira-tools-plugin.env`
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

11. **Update Jira — status transition, no comment yet:**
    You just opened a PR (step 10), so the work is now under review —
    transition it to in-review:
    `acli jira workitem transition --key <KEY> --status "<STATUS_IN_REVIEW>" --yes` (see
    `jira-tools-plugin.env` in the project root for the confirmed status
    name for this project — default example `In Review`).
    How it later reaches `<STATUS_DONE>` depends on whether `<KEY>` has
    a parent (check `fields.parent` from step 1):
    - **Has a parent (multistep sub-task)** → Once the reviewer
      approves the PR, the human merges it into the parent branch.
      GitHub-for-Jira automation (if connected) transitions the
      sub-task to `<STATUS_DONE>` on merge. If the reviewer rejects
      it, the sub-task moves to `<STATUS_IN_PROGRESS>` and the
      executor must re-run `jira-task-executor <KEY>` to fix it.
    - **No parent (single-step top-level issue)** → the reviewer
      (when run on the parent key) will review this PR targeting the
      base branch. `<STATUS_DONE>` is handled when the human merges the
      PR into the base branch — via GitHub-for-Jira's merge automation
      if connected, or a manual `acli jira workitem transition --key <KEY> --status "<STATUS_DONE>" --yes`
      otherwise. Don't transition to Done here.

12. **Report back** — branch name, what was implemented, test results,
    commit(s), the PR link, and the issue's new status. Post this same
    report to the user in chat **and** as a single Jira comment — don't
    post a separate short "PR opened" comment earlier, this is the one
    comment for the whole run. Since it's multi-line, **write it to a temp
    file and post with `--body-file <file>`** (never wrap markdown in a
    quoted inline `--body` string — backticks are interpreted as command
    substitution; and `--body-file -` / stdin does not work — see
    `../_shared/jira-acli-reference.md` §6 for all comment variants):
    ```
    cat > /tmp/<KEY>-report.md <<'EOF'
    <the same report content shown to the user>
    EOF
    acli jira workitem comment create --key <KEY> --body-file /tmp/<KEY>-report.md
    ```

Reference: `../_shared/jira-acli-reference.md` has the full acli syntax,
confirmed issue types, and git/branch conventions this skill depends on.
The `jira-tools-plugin.env` file in the project root has this repo's specific values for every
`<TOKEN>` used above.
