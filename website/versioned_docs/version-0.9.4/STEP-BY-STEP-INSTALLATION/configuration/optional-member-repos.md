---
slug: /step-by-step-installation/optional-member-repos
sidebar_position: 5
sidebar_label: "Optional: member repos"
---

# Optional: member repos

**Only if this project's repos are git submodules of it** — a workspace repo
holding, say, an app and its server, each with its own GitHub repo. Most
projects are one repo and skip this; a project whose submodules are only
vendored libraries skips it too.

Listing the members lets one issue span them: the assigner gives each member
the issue branch, the executor opens one PR per member, and the reviewer
lands the merged result in the workspace. `jst-install` does this for you in
its step 2e. By hand:

1. List the members in `.jst/jira-sdlc-tools.env`, as the paths
   `git submodule status` prints, space-separated, vendored ones left out:
   `JST_MEMBERS=app server`.
2. Turn on the push-order guard: `git config push.recurseSubmodules check`.
3. Give the PAT every member repo, with the same permissions.
4. Give each member the base (and production) branch on its `origin`.
5. Scope any merge → Done automation to this repo: the issue is done when the
   *landing* PR here merges.

The `repo_strategy` healthcheck row then reads `OK submodules`, with one
`member_repo[<path>]` row per member.
[Submodules → Setup](../../submodules/setup.md) has the detail behind each
step, and [Submodules](../../submodules/SUBMODULES.md) the whole story.
