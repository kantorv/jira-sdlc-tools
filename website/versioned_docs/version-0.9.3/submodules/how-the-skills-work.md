---
slug: /submodules/how-the-skills-work
sidebar_position: 3
sidebar_label: How the skills work
---

# How the skills work with member repos

Each skill keeps its usual steps. What changes is that "the repo" becomes **the repo set**: the workspace (`.`) plus
its members. A single-repo project is a set of one, so the same steps cover both. Everything that depends on the
layout goes through `repos.sh`, and the skills act on its output ([reference](./repos-sh.md)).

## The assigner

Run from the workspace's main checkout, as always.

1. **The healthcheck** shows `repo_strategy` and one `member_repo[…]` row per member. A FAIL there stops the run.
2. **Investigation** covers the members' code, under their folders, and the interfaces between them, which the
   project's docs list. **Repos are not pieces:** a change that has to land in one repo before another is still one
   issue.
3. **Scope (step 5D):** it decides which members the issue changes, and includes a member when unsure. An empty issue
   branch costs nothing; a missing one costs the executor a `provision --add` mid-run. Members are supported on
   **single-step planned** work only; with a member in scope, multistep or hotfix stops with a clear message.
4. **Branches:** the issue branch is created in the workspace, as always, and the worktree added. Then, in that
   worktree, `repos.sh provision --add "<members>"` cuts each member's issue branch from that member's base, pushes it,
   and puts the worktree's copy of the member on it. The main checkout's members never move.
5. **The report** lists each member's branch and the likely merge order.

## The executor

Run from the issue's worktree, with no arguments, as always.

1. **`repos.sh provision`**, before the project's hook: every member whose issue branch exists on its origin is put
   on that branch, with its `parentbranch` recorded *inside the worktree's copy of the member*. The rest stay
   *pinned* at the commit the workspace records. The hook receives the members in `JST_MEMBERS`.
2. **Bring current:** the workspace's own merge as always, then `repos.sh sync` for the members. A conflict stops the
   run, naming the repo and files.
3. **Implement:** a member's files change in its folder. A pinned member isn't part of the issue yet:
   `repos.sh provision --add <path>` brings it in (scope growth), and the report says so.
4. **Test** each repo it changed, with that repo's own documented commands.
5. **Commit** in each member it changed. It **never stages a member's folder in the workspace**: that records a move
   of the member's pointer, and moving pointers is landing's job.
6. **`repos.sh push`:** the members first, the workspace last, under the push-order guard.
7. **PRs:** `repos.sh prs` finds what's already open in every repo; a fix summary goes to each open PR (`-R <slug>`);
   then `repos.sh open-prs`, every time, opens the missing ones. There's one PR per member with commits; the workspace
   gets none at this point, since its own commits ride the landing PR. Every PR's body ends with a **PR set** section
   listing the whole set, refreshed whenever the set changes. The body the executor writes says which repo merges
   first, and why.
8. **In Review** once every repo it committed in has a PR.

## The reviewer

Run from the issue's worktree, as always.

1. **`repos.sh gate`** gives the phase of the whole PR set, across every repo. The statuscheck `current_pr` row is not
   used: it sees the workspace only.

   | `phase` | The reviewer |
   | -- | -- |
   | `none` | Reports "no PR yet" and exits |
   | `review` | Reviews each open PR (step 3) |
   | `land` | Runs `repos.sh land`, then reviews the landing PR (5L) |
   | `review-landing` | Reviews the landing PR (5L) |
   | `merged` | Reports the issue complete |
   | `stop` | Relays the reason and asks, never treating it as "no PR" ([stop reasons](./troubleshooting.md#when-a-run-stops)) |

2. **Each member PR** is reviewed on its own, with `-R <slug>` on every `gh pr` command, and gets its own verdict
   comment.

3. **Dimension 7, consistency across the set:** an interface one PR changes (an API field, a CLI flag, an event
   name) is matched on the other side, and no repo the change needs is missing. The reviewer decides the **merge
   order**, what's depended on merging first, and states it.

4. **Outcomes:**

   - every member PR approved → **R-MEMBERS-APPROVED**, which tells you the order to merge them in, then to re-run
   - any rejected → **M-SOME-BLOCKED**, and the issue goes back to In Progress
   - no Done offer at this point: the set hasn't landed

5. **Landing (5L)**, on the re-run after you merge them:

   - `repos.sh land` moves each member's pointer to the commit its PR merged as, commits, pushes, and opens the
     **landing PR** into the workspace's base.
   - `repos.sh land --check` confirms every pointer is on its member's base.
   - Then **R-LANDING-READY**, and only now does the reviewer offer to move the issue to Done.

6. **Never sources secrets** to run a project's tests; it reports what it couldn't run instead.

## What you do

1. **Merge the member PRs** in the order the reviewer gives (any merge method), then re-run the reviewer.
2. **Merge the landing PR.** The issue is done.
3. **Remove the worktree** when you're finished with it: run `repos.sh remove-check` inside it, then
   `git worktree remove --force` (git refuses without `--force` when a worktree holds submodules). A squash-merged
   branch reads `safe`.
