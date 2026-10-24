---
slug: /submodules/design
sidebar_position: 4
sidebar_label: Design and rules
---

# Design and rules

For contributors changing the skills or scripts, and for agents that need the *why* behind a rule. The rules are
deliberate, and most were settled by a test; [How it was validated](#how-it-was-validated) has the evidence.

## The shape: one flow over a set of repos

The skills have no per-layout sections. They say "each repo in the set", and a single repo is a set of one. Everything
layout-specific lives behind one front door, `repos.sh` (twin: `win/repos.ps1`), which picks a strategy and dispatches
each verb to it:

```text
skills (judgement: what to change, scope, review, recovery)
   │   "run repos.sh <verb>, act on its rows"
   ▼
_shared/scripts/posix/repos.sh  → strategies/single.sh      today's behaviour
                                → strategies/submodules.sh  these rules
                                → strategies/<future>.sh    a new layout is a new file, not a skill edit
```

- **The strategy is explicit:** `JST_MEMBERS` set → submodules, else single. It's never detected from `.gitmodules`,
  because an explicit list fails safe: upgrading the plugin can't change a project that vendors libraries as
  submodules, and a newly added vendored submodule can't silently become a member. `.gitmodules` validates the list
  instead.
- **Single-repo projects go through the scripts too**, guarded by a regression test that compares statuscheck's whole
  table against the base commit's.
- **Scripts stop, the model recovers.** A verb never resolves a conflict, guesses a base or retries a failed push: it
  prints the row and exits non-zero.
- **A command the model must run sits where it's used.** In testing, a reviewer twice took the PR from statuscheck's
  `current_pr` row instead of running `gate`, two sections down; it only ran `gate` once the command was inside each
  phase check.

## The model

- The **workspace** holds `.jst/`, the project docs, and one gitlink per member. Its gitlinks mean "the last set of
  member commits integrated together", so a workspace commit is a freeze point.
- The **issue branch** has one name, in the workspace and in every member the issue touches.
- During the work, members follow their **issue branches**, not the workspace's gitlinks. The gitlinks move once, at
  landing.
- The **project root** is the outermost repo, up the submodule chain, that has `.jst/`. Every script finds `.jst/`
  that way (`_jst_root.sh`), so a skill run from inside a member still configures itself from the workspace.

## Rules

### Checkouts

- **An issue checkout is a git worktree**, not a clone. Worktrees work with submodules. A clone would lose what the
  plugin relies on: worktree detection, shared `parentbranch` config, and git's refusal to check one branch out twice.
- **Removing a worktree needs `--force`**, which also skips git's own safety check and deletes the members' copies,
  unpushed commits included. So `repos.sh remove-check` comes first, and no skill removes a worktree itself.
- **A worktree's members have their own git directories** (`.git/worktrees/<wt>/modules/<name>`). Config set in the
  main checkout's member doesn't reach them, so `provision` records `branch.<b>.parentbranch` inside the worktree's
  copy.
- **A credentials copy never lands in a member.** A submodule's `.git` is a file, like a linked worktree's, so
  "is `.git` a file" alone misreads a member as a worktree. The scripts check where it points (`…/worktrees/…` vs.
  `…/modules/…`).

### Scope and the member step

- **A member is in scope when its issue branch exists on its origin.** The assigner creates the branches eagerly, and
  any later run, or a fresh clone, re-derives the same scope from GitHub. Nothing is stored in a comment or a file.
- **The member step** (`provision`): `submodule update --init --recursive` (everything at its recorded commit, nested
  submodules too), then each in-scope member is fetched and switched to its issue branch, then its own submodules are
  updated.
- **Nothing is ever committed to `.gitmodules` for an issue.** Freezing a member's branch in `.gitmodules` was
  tried, and a `merge=ours` rule to keep it out of the base doesn't work: a merge driver only runs when both sides
  changed the file, and GitHub's merge button doesn't run custom drivers.
- **Never combine `--remote` with `--recursive`.** `--remote` is passed down, and moves pinned nested submodules to
  their branch tip.
- **Never run a bare `git submodule update` in an issue worktree.** It puts every member back on the workspace's
  gitlink, off its issue branch. Re-run `provision` instead, and don't set `submodule.recurse=true`.

### Commits, pushes and PRs

- **Members commit and push on the issue branch.** The workspace gets commits during the work only for its own files.
  It never moves a gitlink before landing.
- **`push.recurseSubmodules=check`** makes git refuse a workspace push that points at a member commit no remote has.
- **One PR per member with commits; none for the workspace before landing.** Its own commits ride the landing PR. Every
  PR's body carries a marked **PR set** section, kept current by `open-prs`.

### Landing, and why squash merges matter

A gitlink is a commit SHA. If a member PR is **squash-merged** (or rebase-merged), GitHub writes a new commit on the
base, and the PR's own commit is on no branch once its branch is deleted. A workspace pointing at that commit breaks:
a fresh clone can fetch it only until the server garbage-collects it (*"upload-pack: not our ref"*).

- **The workspace's gitlinks only ever point at commits on each member's base**, never at issue-branch commits. This
  makes the squash problem impossible, whatever merge method the members use.
- **Landing** (`land`): for each member PR, take its merge commit, check it's on `origin/<base>`, move the gitlink
  there, commit, push, and open the landing PR. Everything is checked before anything changes.
- **The reviewer's gate on the landing PR** (`land --check`): every gitlink is on its member's base, and
  `.gitmodules` is unchanged.
- **Done is the landing PR's merge**, which is why merge → Done automation must be scoped to the workspace repo.
- **A squash-merged branch is still safe to remove**: `remove-check` accepts a commit on no remote when it's the head
  of a merged PR, or an ancestor of that head.

### The reviewer and the executor

- **PRs are read through `repos.sh`, never a hand-typed `gh pr list`.** `gh` answers a filter that misses with `[]`,
  not an error, so a narrowed query reads an open PR as none. The script asks the one exact query (bare `--head`,
  every state, no `--base`) twice before it says `none`, and a `gh` failure is `error`: unknown, never none.
- **Every `gh pr` command takes `-R <slug>`**, in single-repo mode too, so the prose has no layout branch.
- **The reviewer never sources a project's secrets** to run its tests. It reports what it couldn't run.

## Limits and what's next

- **Multistep issues across members** need per-member parent branches and PRs before landing, a third level. Every
  skill stops on that combination instead of guessing.
- **Hotfixes across members** need each member's production branch as the PR base, which isn't modelled (members
  have a base only).
- **Other layouts** (git-ignored clones, manifests) would each be one more `strategies/` file
  ([Other layouts](./other-layouts.md)).

## How it was validated

**Git behaviour**, tested on git 2.43 on throwaway repos with local remotes:

| Check | Result |
| -- | -- |
| `submodule update --init` in a linked worktree | Works; member gitdirs under `.git/worktrees/<wt>/modules/` |
| `git worktree remove` with submodules | Refused; `--force` works and removes the member copies |
| `git config` inside a worktree | Shared with the main checkout and every other worktree |
| `submodule.<name>.branch` in config vs. `.gitmodules` | Config wins |
| `branch = .` with a member lacking the branch | `update --remote` fails |
| `.gitmodules merge=ours`, only the feature changed it | The feature's version is taken; the driver doesn't run |
| A squash-merged commit, its branch deleted, before / after gc | Fetchable / *"not our ref"* |
| `push.recurseSubmodules=check` with an unpushed member commit | Push refused |
| `update --init --recursive --remote` with a pinned nested submodule | The nested one moves off its pin |

**The scripts:** `scripts/check-repos.sh --ports` runs 208 checks in both ports. They cover:

- the project-root rule from 11 locations
- the single-repo regression against the base commit
- every `repos.sh` verb, against a fake `gh` and real local git (including a real squash merge then `land`)
- the healthcheck rows

`scripts/check-ensure-local-env.sh --ports` covers credentials never landing in a member.

**The skills,** run headlessly against a demo workspace (an app and its server) and a single-repo project:

- a cross-repo issue reviewed, landed after squash merges, and merged
- a member pushed with no PR, which stops the run
- a broken contract, rejected under dimension 7
- a rejected issue fixed by the executor, then approved and landed
- a plain task description taken through assigner → executor → reviewer → landing → Done with no hand steps but the
  merges
- single-repo single-step and multistep runs, unchanged
