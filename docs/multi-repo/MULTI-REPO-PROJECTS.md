---
slug: /multi-repo-projects
sidebar_position: 1
sidebar_label: Overview
---

# Multi-repo projects — a workspace holding its repos as git submodules

Some projects aren't one repository. A **workspace** repo holds a few **member** repos as git submodules: an app and
its server, say, each with its own GitHub repo. The skills handle that layout: one Jira issue can change several
members, each member gets its own branch and PR, and the workspace records the result once they've all merged.

A project without submodules, or with submodules that are only vendored libraries, is unaffected. Nothing changes
until you list members.

## How one issue flows

```text
assigner  → the issue, plus the issue branch in the workspace and in every member it touches
executor  → one commit and one PR per member it changed (each PR lists the whole set)
reviewer  → reviews each member PR, checks the interfaces between them, states the merge order
you       → merge the member PRs, in that order
reviewer  → "lands" them: one workspace PR moving each member's pointer to its merged commit
you       → merge the landing PR — the issue is done
```

The branch name is the same everywhere, so `feature/PROJ-42-…` in the app and in the server are one issue's two
halves.

## Setting it up

`jst-install` asks about members when it finds a `.gitmodules` (its step 2e). By hand:

1. **List the members** in `.jst/jira-sdlc-tools.env`, as the paths `git submodule status` prints, space-separated.
   Leave vendored submodules out: they stay pinned and never get an issue branch.

   ```text
   JST_MEMBERS=threejs-skeleton threejs-skeleton-server
   ```

2. **Turn on the push-order guard** in the workspace. It refuses to push the workspace while it points at a member
   commit no remote has:

   ```bash
   git config push.recurseSubmodules check
   ```

3. **Give the PAT every member repo** (Contents and Pull requests, read/write). The healthcheck shows one
   `member_repo[<path>]` row per member, and a 404 there means the token can't see that repo.

4. **Give each member the base branch** (and the production branch, for hotfixes later). A member's PRs target its own
   base, set by its `.gitmodules` `branch`, defaulting to the workspace's.

5. **Scope merge → Done automation to the workspace repo.** The issue is done when the *landing* PR merges. A rule that
   fires on any merged PR closes it at the first member merge.

6. **Consider a `.jst/bootstrap.sh`** ([Parallel instances](../parallel-instances/RUNNING-MULTIPLE-COPIES.md)). A
   worktree's members arrive without venvs, `node_modules` or git-ignored env files. The hook gets the members in
   `JST_MEMBERS`, already checked out, so it can set them up. Without one, the executor improvises to run its tests.

## What each skill does differently

- **Assigner:**
  - It reads the members' code along with the workspace's.
  - It decides which members the issue touches, and creates the issue branch in each one.
  - "Repos are not pieces": a change that has to land in the app before the server is still one issue.
- **Executor:**
  - It puts the members on the issue branch and brings each one current with its base.
  - It commits in each member it changes, and tests each with that repo's own commands.
  - It pushes members first, then opens one PR per member. The workspace gets no PR of its own at this point; its own
    commits, if any, ride the landing PR.
- **Reviewer:**
  - It finds the issue's PRs in every repo.
  - It reviews each one, plus a seventh dimension: *consistency across the set*. An interface changed on one side is
    matched on the other, and no repo the change needs is missing.
  - It states the merge order.
  - Once the member PRs are merged, it lands them and reviews the landing PR.
  - It offers Done only then.

## Why the landing PR comes last

The workspace records each member as a commit, its gitlink. It should only ever point at commits on each member's
base: a squash merge rewrites the PR's commit, and the original disappears once its branch is deleted. So the
workspace's pointers move once, at landing, to the commits the member PRs actually merged as, whatever merge method
you used. The reviewer checks exactly that before approving the landing PR.

## Removing a finished worktree

`git worktree remove` refuses when a worktree holds submodules, so the removal needs `--force`. That skips git's own
safety check, so check first:

```bash
bash <plugin>/skills/_shared/scripts/posix/repos.sh remove-check   # run inside the worktree
```

It reports each repo as `ok`, `dirty`, `unpushed` or `unknown`, then `safe=yes|no`. A squash-merged branch reads
`ok`: its commits are on no remote, but they're the head of a merged PR.

## Limits, for now

- **Single-step, planned work only, when members are involved.** Multistep issues (Jira sub-tasks) and hotfixes across
  members stop with a clear message. Issues that touch only the workspace work as before.
- **Git submodules only.** A workspace whose members are git-ignored clones isn't supported yet.
- **The Windows port** is tested under PowerShell on Linux, not yet on Windows itself.

The design, its rules and the evidence behind them are in the
[submodules strategy proposal](../proposals/submodules-strategy.md).
