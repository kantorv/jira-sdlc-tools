---
slug: /proposals/submodules-strategy
sidebar_position: 2
sidebar_label: Submodules strategy
---

# Proposal: multi-repo support through git submodules

|  |  |
| -- | -- |
| Status | Proposal, not implemented. Design agreed in a brainstorm; every git behaviour marked *tested* was run on git 2.43 |
| Written | 2026-10-24, against plugin 0.8.10 |
| Pilot project | `~/projects/threejs-skeleton-proj` (to be converted from git-ignored clones to submodules) |
| Covers | Type 2 of the [multi-repo proposal](multi-repo-workspaces.md)'s §3: a parent repo holding its member repos as git submodules |

The [multi-repo proposal](multi-repo-workspaces.md) specifies type 1 (a workspace with git-ignored member clones). This
document takes the other route: **start from one concrete type the team knows well, submodules**, and let git hold as
much of the multi-repo state as possible. The plugin then needs little new configuration of its own.

## 1. Why submodules first

Every multi-repo design has to answer seven questions. With submodules, git answers most of them:

| Question | Submodule answer |
| -- | -- |
| **Discover:** which repos exist? | `.gitmodules`. No separate members file |
| **Scope:** which repos does this issue touch? | The members whose GitHub `origin` has the issue branch (§4) |
| **Checkout:** how to get an isolated copy? | The usual issue worktree of the parent, with its submodules on the issue branch (§3, §4). Sibling layout comes for free |
| **Deliver:** what's the unit per repo? | One PR per member with commits, plus one **parent PR** |
| **Link:** how to find all changes of an issue? | For each member, the PR whose head is the issue branch |
| **Order:** what lands first? | Members first, then the parent. Submodules force this |
| **Gate:** when is it Done? | When the parent PR merges (§6). One merge, one Done |

The last row is the main gain over type 1. There, *merge → Done* fires on the first member PR and has to be turned
off. Here, the parent PR is the single integration point, so it can stay on, scoped to the parent repo.

## 2. The model

- The **parent repo** holds `.jst/`, the project docs, and a gitlink per member. Its gitlinks mean "the last set of
  member commits that were integrated together". That makes a parent commit a freeze point, and a natural release or
  version trigger.
- An **issue branch** `<PREFIX><KEY>-<slug>` exists in the parent and in every member the issue touches. Same name
  everywhere.
- During the work, members follow their **issue branches**, not the parent's gitlinks. The parent's gitlinks are
  updated once, at landing (§6), not on every member commit.
- The skills always run from the **parent root**, never from inside a member (§8).

## 3. Rule: an issue checkout stays a worktree

`git worktree`'s man page says: *"support for submodules is incomplete. It is NOT recommended to make multiple
checkouts of a superproject."* Tested in practice, none of it is a blocker:

| Behaviour | Result (*tested*) | Consequence |
| -- | -- | -- |
| `submodule update --init` in a linked worktree | Works | Nothing changes in how the assigner creates worktrees |
| Member git directories | `<main>/.git/worktrees/<wt>/modules/<name>`: one full copy of each member per worktree, inside the main checkout's `.git` | Disk cost per worktree. Fine for the pilot's repo sizes |
| `git worktree remove` | Refused even on a clean worktree: *"working trees containing submodules cannot be moved or removed"*. A single `--force` works, and also cleans up the member copies | Removal always needs `--force` (MS-CO-2) |
| Git config set inside the worktree | **Shared** with the main checkout and every other worktree | The branch freeze can't be plain config (§4, MS-SC-2) |

An earlier draft chose a clone per issue instead. It was dropped: it gains a plain folder delete, but loses what the
plugin relies on today. The credentials copy recognises an issue checkout by its `.git` being a file, `pr_base`'s
`branch.<b>.parentbranch` is shared across worktrees, and git refuses to check one branch out twice. A clone would
need all three rebuilt.

**Rule MS-CO-1:** the assigner creates the issue worktree as today, then runs the member step of §4.

**Rule MS-CO-2:** because `--force` is always needed, it also skips git's own "uncommitted changes" check, and it
deletes the members' copies, including commits never pushed. So removal needs its own check first: the parent *and
every member* have no uncommitted changes and no commits missing from `origin`. Then ask the human. No skill removes
worktrees today, and this doesn't change that.

## 4. Rule: scope comes from GitHub, the branch freeze stays local

### What doesn't work: committing the freeze to `.gitmodules`

The first idea was to set `branch = <issue branch>` in `.gitmodules` on the parent issue branch, and keep it out of
`development` with a merge rule (`.gitattributes`: `.gitmodules merge=ours`). Tested, and it fails in the common case:

- A merge driver only runs when **both sides** changed the file. When only the feature changed `.gitmodules`, which is
  the normal case, git takes the feature's version as is, and `development` ends up pointing at a feature branch.
- The driver itself (`merge.ours.driver`) lives in each machine's `.git/config`, not in the repo. GitHub's merge button
  doesn't run custom drivers (known behaviour, not tested here).

### What does: config that never reaches `.gitmodules`

`submodule.<name>.branch` set in git config **overrides** `.gitmodules` for `submodule update --remote` (*tested*). So
the freeze never needs committing, and there's nothing to undo before merging. But in a worktree, plain `git config`
writes the **shared** config (*tested*: the main checkout and a second worktree both saw the value), so two issues
would overwrite each other's freeze. Two ways that stay local to one worktree, both *tested*:

- **One-shot, nothing stored:** `git -c submodule.<name>.branch=<issue branch> submodule update --remote <name>`.
- **Per-worktree config:** `git config --worktree …`, which needs `extensions.worktreeConfig=true` set once in the
  repo.

Prefer the one-shot form. It writes nothing, needs no repo-wide setting, and the member step runs on every executor
start anyway.

**Rule MS-SC-1, scope:** a member is in scope for an issue when its `origin` has the issue branch. The assigner creates
and pushes the branch in every member it expects the issue to touch (eager, so the branch is visible on GitHub and in
GitHub for Jira from the start). Any later run, or a fresh clone, re-derives the same scope from GitHub.

**Rule MS-SC-2, the member step** (scripted, run after the worktree is created and on every executor start):

1. `git submodule update --init --recursive`: every submodule, nested ones included, at the commits the parent and
   members record.
2. For each member listed in `<JST_MEMBERS>` (§7):
   - **branch on `origin`:** `git -c submodule.<name>.branch=<issue branch> submodule update --remote <name>`, *without*
     `--recursive`; then `git switch <issue branch>` inside the member (`--remote` leaves a detached HEAD; `switch`
     gives a local branch tracking `origin`, *tested*); then `git submodule update --init --recursive` inside the
     member, so its own submodules match its branch;
   - **no branch:** leave it at the parent's gitlink, read-only for this issue.
3. `push.recurseSubmodules=check` (§5). This one *should* be shared config, so it's set once, not per worktree.

**Rule MS-SC-4, recursion:** never combine `--remote` with `--recursive`. `--remote` is passed down to nested
submodules, and moves each one to its branch tip (*tested*: a library a member pins at a commit moved to the
library's latest `development`). Nested submodules are usually pinned on purpose. Step 2 of MS-SC-2 is split
for that reason.

**Rule MS-SC-5, don't undo the step by accident:** a plain `git submodule update` in the issue worktree puts every
member back on the parent's gitlink, detached, off its issue branch. No commits are lost, since they're on the
branch, but the next commit lands on a detached HEAD. So don't set `submodule.recurse=true` in the repo (it makes
`checkout` and `pull` do that implicitly), and re-run the member step instead of a bare `submodule update`.
(Documented git behaviour, not tested here.)

**Rule MS-SC-3, scope growth:** when the executor finds a member that must change and isn't in scope, it creates the
issue branch there from the member's base, pushes it, and re-runs the member step. The branch on `origin` *is* the
record, so nothing else needs updating.

Why not `branch = .` (git's "same name as the superproject's branch"): `update --remote` then fails for every member
without the branch (*tested*: *"Unable to find refs/remotes/origin/<branch> revision"*). The scripted step does the
same thing, but tolerates members that are out of scope.

## 5. Rule: commits and pushes

- Members: commit and push on the issue branch, per member, as the executor does for one repo today.
- The parent gets commits on its issue branch only for its own files (docs, config) during the work. It **doesn't bump
  gitlinks** while the work is in progress: members follow their branches, and the bump happens at landing (§6).
- **MS-PU-1:** `push.recurseSubmodules=check` makes git refuse to push a parent commit whose gitlink points at a member
  commit that isn't on any remote (*tested*: *"submodule paths contain changes that can not be found on any remote"*).
  That turns "push members before the parent" from a rule the model must remember into one git enforces. (`on-demand`
  would push the members itself; `check` is preferred because pushes stay explicit.)

## 6. Rule: landing, and why squash merges matter

### The squash problem, step by step

A gitlink is a commit SHA. It has to point at a commit that stays reachable in the member repo, or nobody can check it
out later. Reproduced (*tested*):

1. The parent records member commit `C`, made on the member's issue branch.
2. The member PR is **squash-merged**. GitHub writes a new commit `S` on `development` with the same content but a
   different SHA. `C` is *not* an ancestor of `development`.
3. The issue branch is deleted. Now no branch reaches `C`.
4. A fresh clone of the parent still fetches `C` while the server keeps the object. After garbage collection it fails:
   *"upload-pack: not our ref … Direct fetching of that commit failed."*

**Rebase-merge** has the same effect: it rewrites SHAs too. Only **"Create a merge commit"** keeps `C` an ancestor of
`development`. On GitHub, `refs/pull/<n>/head` probably keeps `C` reachable longer, but that's not a guarantee to
build on (not tested).

### The landing step

**Rule MS-LA-1:** the parent's gitlinks are only ever bumped to commits **on each member's base branch**, never to
issue-branch commits. That makes the squash problem impossible, whatever merge method the members use.

**Rule MS-LA-2, landing** (scripted, run once every member PR in the set is merged):

1. For each in-scope member, find its PR's merge commit (`gh pr view --json mergeCommit`).
2. Check it's an ancestor of the member's `origin/<base>`.
3. Bump the parent's gitlink to it, commit on the parent issue branch (`<KEY>: land <members>`), push.
4. The parent PR is now the integration change: gitlink bumps plus any parent-file changes. Merging it is the freeze.

A gitlink bumped to a merge commit also brings in every commit merged before it in that member. That's inherent: the
parent records integrated states, not individual issues.

**Rule MS-LA-3, the reviewer's gate on the parent PR:** every bumped gitlink must point at a commit reachable from that
member's base. One `git merge-base --is-ancestor` per member, so scriptable. Any other value means CHANGES REQUESTED.
It's also a good candidate for a CI check on the parent repo.

## 7. Configuration

Not every submodule is a member: a vendored third-party library must never get issue branches. So membership is
explicit:

- **`JST_MEMBERS`** in `.jst/jira-sdlc-tools.env`: the submodule names that take part in issues, space-separated. No
  value, or no `.gitmodules`, means single-repo mode, unchanged (the multi-repo proposal's G5).
- Each member's **base** and **production** branch names come from `.gitmodules`'s `branch` (the base) or, when they
  differ from the parent's, from per-member settings. Whether that needs a setting at all is open (§11).
- **Relative URLs** in `.gitmodules` (`../threejs-skeleton-editor.git`) are recommended: members then resolve against
  the parent's `origin`, so SSH and HTTPS clones both work.
- Credentials stay single-sourced in the parent's `.jst/jira-sdlc-tools.local.env`. Members never get one.

## 8. What changes in the plugin

### Finding `.jst/` (the "home vs target" fix)

Every script finds `.jst/` with `git rev-parse --show-toplevel`: `jira.sh`, `check_assignee.sh`,
`get_assignee_email.sh`, `pr_base.sh`, `statuscheck.sh`, `ensure_local_env.sh`, `list_subtasks.sh`,
`create_parent_and_subtasks.sh`, and their `win/*.ps1` twins. Inside a member, that returns the **member's** root, so
`.jst/` isn't found. Fix: prefer `git rev-parse --show-superproject-working-tree` when it's non-empty.

### `ensure_local_env`: run inside a member, it misreads where it is (found by reading the code, not run)

It decides "issue worktree vs main checkout" by whether `.git` is a file, then walks three levels up from the gitdir to
find the main checkout. A submodule's `.git` is *also* a file (`gitdir: ../.git/modules/<name>`):

- **In a member of the main checkout,** the walk lands on the parent's root, which passes its "main checkout" test.
  It would create `.jst/` inside the member and copy `jira-sdlc-tools.local.env` there, protected only by an untracked
  `.gitignore`.
- **In a member of an issue worktree,** the walk most likely finds nothing and copies nothing, but it still writes a
  stray `.jst/.gitignore` into the member.

Running from the parent root (§2) avoids both. The script should also refuse to run inside a submodule. This is the
safety property `scripts/check-ensure-local-env.sh` exists to protect, so it needs a test case.

### New scripts (POSIX and PowerShell twins)

| Script | Does |
| -- | -- |
| `members_checkout.sh` | The MS-SC-2 member step, run in the issue worktree. Idempotent, so the executor re-runs it on every start |
| `members.sh` | Lists members from `JST_MEMBERS` + `.gitmodules`: name, path, slug, base, in scope (branch on `origin`), local state (branch, dirty, ahead/behind) |
| `pr_set.sh` | Every PR whose head is the issue branch, in the parent and each member, as in the multi-repo proposal's MR-SCR-2, including its "unknown is not none" rule |
| `land.sh` | MS-LA-2, and a `--check` mode for MS-LA-3 |

### Skills, one line each

Each skill gains "with `JST_MEMBERS` set, follow `skills/_shared/submodules.md`". The reviewer is at its word ceiling,
so the detail lives in that shared file.

| Skill | Change |
| -- | -- |
| jst-install | Detect submodules, ask which are members, write `JST_MEMBERS`. Check the PAT can reach each member repo. Check each member's base and production branches exist on `origin`. Warn about merge → Done rules not scoped to the parent repo |
| Assigner | Investigate members' code too. Decide the in-scope members; repos are not pieces (a cross-repo change can still be single-step). Create and push the issue branch in the parent and each in-scope member, then `members_checkout.sh` |
| Executor | `members_checkout.sh` at start. Bring each member current with its base. Commit and push per member. One PR per member with commits, plus the parent PR when the parent has commits. In Review once every member with commits has a PR |
| Reviewer | `pr_set.sh` instead of `current_pr`. Review each member PR with `-R <slug>`, plus a cross-repo consistency check (contracts listed in the project docs). After approval: tell the human to merge the members, then run landing. Review the parent PR with the MS-LA-3 gate |
| Done | The parent PR merging. Scope the merge → Done automation to the parent repo, or member merges will close the issue early |

## 9. Multistep and hotfix

- **Multistep:** the parent issue branch exists in the parent and each in-scope member. A sub-task branch is created
  from the parent issue branch, in the members it touches, and its PRs target that branch in each one. Each sub-task
  gets its own worktree. Landing happens once, for the parent issue, after the parent-branch PRs merge into each member's
  base.
- **Hotfix:** `hotfix/<KEY>-<slug>` from each in-scope member's production branch and the parent's. Landing bumps the
  parent's production gitlinks to the members' production merge commits. The back-merge to `development` will likely
  conflict on gitlinks, because the two branches' member commits aren't ancestors of each other. After the members are
  back-merged, re-bump the parent's `development` gitlinks to their `development` tips. Not tested yet.

## 10. Converting the pilot

`threejs-skeleton-proj` today has git-ignored clones. To convert:

1. In the workspace: remove both folders from `.gitignore`, and `git submodule add` each repo (relative URLs) at the
   same paths, branch `development`.
2. Commit on the workspace's `development`, push.
3. Re-clone the workspace with `--recurse-submodules` to confirm it rebuilds. The server's `venv`, the app's
   `node_modules` and other ignored files don't come with the clone; that's the same per-checkout cost as worktrees
   today, and it's the project's `.jst/bootstrap.sh` job.
4. Update the workspace `CLAUDE.md`: "commit and push each repo separately" becomes this document's rules.

Then, by hand, before any plugin work: create one issue branch in the workspace and one member, run the member
step, commit in the member, open both PRs, merge the member PR with each merge method, run landing, then remove the worktree (MS-CO-2 check, then
`--force`). That checks
§3–§6 on the real project.

## 11. Open questions

- **Q1, per-member branch names:** both pilot members use `development`/`main`. Is `.gitmodules`'s `branch` enough for
  the base, with production assumed the same as the parent's, or does this need a per-member setting from the start?
- **Q2, who runs landing:** the reviewer after approval, a re-run of the executor, or a parent-repo GitHub Action
  triggered by the last member merge?
- **Q3, member merge method:** with MS-LA-1 any method is safe. Is it still worth recommending merge commits, to keep
  member history readable from the parent?
- **Q4, the parent PR when the parent has no own changes:** it exists only to carry the landing bump. Open it at
  landing time, or at the start as a draft that collects the PR set (the multi-repo proposal's umbrella PR)?
- **Q5, type 1 later:** most of §8 (the `.jst/` lookup, `pr_set.sh`, the reviewer changes) carries over to the
  multi-repo proposal's type 1. Keep the seam: Discover and Checkout are the submodule-specific parts.

## 12. Evidence

The *tested* rows above came from a scratch superproject with two members and local bare remotes. In summary:

| Check | Result |
| -- | -- |
| Worktree + `submodule update --init --remote` | Works; member gitdirs under `.git/worktrees/<wt>/modules/` |
| `git worktree remove` with submodules | Refused; only `--force` works |
| Clone `-b <branch> --recurse-submodules --remote-submodules` | Works; members detached at `origin/<branch>` (the clone route, since dropped) |
| `git switch <branch>` in a detached member | Local branch tracking `origin/<branch>` |
| `submodule.<name>.branch` in `.git/config` vs `.gitmodules` | Local config wins |
| `branch = .` with a member lacking the branch | `update --remote` fails |
| `.gitmodules merge=ours`, only the feature changed the file | Feature's version taken; driver not run |
| `.gitmodules merge=ours`, both sides changed the file | Driver runs; base kept |
| Squash-merged member commit, branch deleted, before / after gc | Fetchable / *"not our ref"* |
| `push.recurseSubmodules=check` with an unpushed member commit | Push refused |
| `clone --reference <main> --recurse-submodules` | Parent and members both use the main checkout's objects (the clone route, since dropped) |
| `git worktree remove --force` with submodules | Removes the worktree and its member copies under `.git/worktrees/<wt>/` |
| Plain `git config submodule.<name>.branch` inside a worktree | Seen by the main checkout and another worktree: shared |
| `git config --worktree` (with `extensions.worktreeConfig`) | Seen by that worktree only |
| `git -c submodule.<name>.branch=<b> submodule update --remote <name>` | Member moved to `<b>`; nothing written |
| `update --init --recursive --remote` with a nested pinned submodule | The nested one moves off its pin to its branch tip |
| `update --init --recursive`, then `--remote` per member, then `--init --recursive` inside it | Member on its branch; the nested pin kept |
