---
slug: /submodules/other-layouts
sidebar_position: 7
sidebar_label: Other multi-repo layouts
---

# Other multi-repo layouts

"Multi-repo" covers several structures, and the plugin supports one of them, git submodules, plus the single repo and
monorepo it always did. The others are listed so nobody assumes they work, and so each can later become one more
`strategies/` file in [`repos.sh`](./repos-sh.md) without touching the skills.

| Layout | Shape | Status |
| -- | -- | -- |
| **Single repo / monorepo** | One git repo, however many packages | Supported, as always |
| **Git submodules** | A workspace records each member as a gitlink | **Supported** (this section) |
| **Workspace with git-ignored clones** | A small workspace repo; members are independent clones at fixed paths, listed in its `.gitignore` | Not supported. Convert it to submodules (below), or it needs its own strategy: no gitlinks, so no landing, and the member list would need its own file |
| **Polyrepo without a parent** | Sibling repos, no repo above them | Not supported: there's no natural home for `.jst/` or for the worktree's sibling layout |
| **Manifest-based** (Google `repo`, `west`, `vcstool`, `gclient`) | A manifest lists repos and revisions; a tool checks them out | Not supported. Close to submodules, but the tool owns checkouts and branches |
| **Package-coupled polyrepo** | Repos depend on each other through published versions | Not supported: merge order includes a release in between, so it's really one issue per repo |
| **Mixed hosts** | Members on GitHub and GitLab/Bitbucket | Not supported: the plugin uses `gh` |
| **Fork-based contribution** | PRs from a fork to an upstream the team doesn't own | Not supported |

## Converting a workspace of git-ignored clones to submodules

This is how the demo workspace the feature was built on was converted. Ignored files (venvs, `node_modules`,
databases) stay where they are.

1. **Check nothing can be lost.** In each clone: a clean `git status`, no unpushed commits
   (`git log --branches --not --remotes`), no stashes, no worktrees of its own.

2. **Stop ignoring the members:** remove their folders from the workspace's `.gitignore`.

3. **Adopt each clone in place.** `git submodule add` accepts an existing repo at the path, and doesn't re-clone. Use
   relative URLs:

   ```bash
   git submodule add -b development ../app-repo.git app
   ```

4. **Move each member's `.git` into the workspace's** (`.git/modules/<name>`), the standard layout:

   ```bash
   git submodule absorbgitdirs
   ```

5. **Commit and push** `.gitignore`, `.gitmodules` and the new gitlinks, and update the workspace's docs:
   contributors now clone with `--recurse-submodules`.

6. **Confirm** that a fresh `git clone --recurse-submodules` rebuilds the layout. Then follow [Setup](./setup.md).
