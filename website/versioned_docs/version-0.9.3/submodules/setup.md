---
slug: /submodules/setup
sidebar_position: 2
sidebar_label: Setup
---

# Setting up a submodules project

Do the [Step-by-step installation](../STEP-BY-STEP-INSTALLATION/index.mdx) first, in the **workspace** repo, the one
holding `.gitmodules`. That's where `.jst/` lives and where the skills run. Members never get a `.jst/` of their own.

The quickest route is to run `/jira-sdlc:jst-install`. Its step 2e finds the submodules, asks which are members, and
does steps 1 and 2 below. Everything else here is what that step tells you to check.

## 1. List the members

A member is a submodule whose code issues change. A vendored library stays out, so it's never given an issue branch.
List members in `.jst/jira-sdlc-tools.env`, the committed team file, as the paths `git submodule status` prints,
space-separated:

```text
JST_MEMBERS=threejs-skeleton threejs-skeleton-server
```

Unset or empty means a single-repo project, even when submodules exist. This is deliberate: a missing setting can never
change how an existing project behaves. Every member must be checked out:

```bash
git submodule update --init --recursive
```

## 2. Turn on the push-order guard

```bash
git config push.recurseSubmodules check
```

Git then refuses to push the workspace while it points at a member commit that no remote has. "Push the members
first" becomes something git enforces, rather than something the model has to remember. It's local config, so set
it in every checkout (jst-install does, and so does the executor's first step).

## 3. Give the PAT every member repo

The fine-grained PAT in `.jst/jira-sdlc-tools.local.env` needs **Contents** and **Pull requests** read/write on the
workspace repo *and* every member repo ([the PAT page](../STEP-BY-STEP-INSTALLATION/environment-setup/github/authentication/gh/pat.md)).
A token that can't see a repo gets a 404 from GitHub, not a 403, so it looks like a typo.

## 4. Give each member its branches

A member's PRs target that member's **base**: its `branch` in `.gitmodules`, else the workspace's
`DEFAULT_BASE_BRANCH`. Each member needs that branch on its `origin`, and the production branch too, for hotfixes
later. Relative URLs in `.gitmodules` (`../app.git`) are recommended: members then resolve against the workspace's own
`origin`, so SSH and HTTPS clones both work.

## 5. Scope merge → Done automation to the workspace

An issue is done when its **landing PR**, in the workspace, merges, not when its first member PR does. If GitHub for
Jira or a Jira automation rule moves issues to Done on merge, limit it to the workspace repo. Otherwise the first
member merge closes the issue while the rest of the set is still open.

## 6. Recommended: a bootstrap hook

A fresh issue worktree's members arrive as source only: no venv, no `node_modules`, none of their git-ignored env
files. Without a hook, the executor improvises to run its tests, and on the demo workspace that meant copying a
member's `.env.local` and starting its Docker stack. A [`.jst/bootstrap.sh`](../parallel-instances/RUNNING-MULTIPLE-COPIES.md)
is the place for that, decided by the project. The executor runs it with the members already checked out, and lists
them in `JST_MEMBERS`.

## Check it

Run the healthcheck from the workspace (`bash <plugin>/skills/_shared/scripts/posix/statuscheck.sh --role assigner`).
Two rows are about members:

| Row | Expect |
| -- | -- |
| `repo_strategy` | `OK submodules — members: … · pinned: …` |
| `member_repo[<path>]` | `OK <slug> · base <base> · on <branch>`, one row per member |

A FAIL on either blocks every skill, with a remedy line. [Troubleshooting](./troubleshooting.md#healthcheck-rows) has
what each one means.
