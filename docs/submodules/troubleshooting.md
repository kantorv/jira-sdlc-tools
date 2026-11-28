---
slug: /submodules/troubleshooting
sidebar_position: 6
sidebar_label: Troubleshooting
---

# Troubleshooting

## Healthcheck rows

| Row | Reading | Fix |
| -- | -- | -- |
| `repo_strategy` | FAIL `JST_MEMBERS lists 'x', which isn't a top-level submodule` (also: listed twice, or no `.gitmodules`) | Fix `JST_MEMBERS`: paths as `git submodule status` prints them |
| `repo_strategy` | INFO `single (N submodule(s) present, none in JST_MEMBERS: …)` | Nothing, if they're vendored. Otherwise list the members ([Setup](./setup.md)) |
| `member_repo[<path>]` | FAIL `not checked out` | `git submodule update --init <path>` in the workspace |
| `member_repo[<path>]` | FAIL `the PAT authenticates but 404s on <slug>` | Add the repo to the PAT's repository access (Contents and Pull requests, read/write) |
| `member_repo[<path>]` | FAIL `base branch '<b>' isn't on <slug>` | Push the base to that repo, or set the member's base in `.gitmodules` (`git submodule set-branch --branch <b> <path>`) |
| `member_repo[<path>]` | FAIL `.gitmodules sets 'branch = .'` | Name a real branch: `git submodule set-branch --branch <b> <path>` |
| `member_repo[<path>]` | WARN `no '<production>' branch there` | Only matters for hotfixes, which aren't supported across members yet |
| `working_tree` | WARN `N uncommitted change(s)` in an issue worktree | Usually the members: on their issue branches they differ from the workspace's gitlinks, which is normal until landing |

## When a run stops

These are `gate`'s `stop` reasons, and what each one asks of you:

| `reason=` says | It means | Do |
| -- | -- | -- |
| `<repo> has commits on <b> … but no PR — pushed, no PR` | A member's branch has work the reviewer can't see | Re-run the executor (it opens the PR), or open it by hand |
| `<slug>#<n> was closed without merging` | Someone abandoned that PR | Decide: reopen it, or say the change was dropped |
| `<slug>#<n> targets '<x>', but its base is '<y>'` | A PR points at the wrong base | Retarget it on GitHub |
| `several OPEN PRs in <repo>` | Duplicate PRs | Close the extra one |
| `the root PR #<n> is open while member PRs are still open` | The landing PR exists too early | Close it; landing reopens it once the members merge |
| `PRs unknown for: <repos> — gh failed` | A `gh` call failed (network, auth) | Re-run; check `gh_auth` |
| `multistep issues … across member repos aren't supported yet` | The issue has Jira sub-tasks, and a member takes part (a PR, or commits pushed) | Restructure as single-step, or review by hand |
| `conflicts unknown for <repo>: <why> — unknown is not none` | The conflict check couldn't read a repo: a fetch failed, or a member isn't checked out | Re-run; `repos.sh provision` for a member that isn't checked out |

### When an issue is paused: `phase=conflict`

`reason=` names the repo and files: `conflicts with origin/development in app: README.md`. Nothing after it runs (no
review, no landing, no Merge) until the branch merges clean. To resolve it by hand: in the issue's worktree, merge the
base in the repo it names (`git -C app merge origin/development`, after a fetch), resolve, commit, and push. The gate
reads the branch off origin, so the pause lifts at its next read once the push is there.

**Member pointers aren't a pause.** When the only conflicted paths are member pointers that one side fast-forwards
(two landing PRs both moved `app`, P16), GitHub shows the landing PR as CONFLICTING, but `conflicts` reads `gitlink`
and the gate doesn't pause: `repos.sh land` merges the base in itself (`base_merged=`). A pointer whose two commits
diverged (neither contains the other) is a real `conflict`, in the root.

Other stops: `land` refuses with `error=… — nothing changed`, and `provision`/`sync`/`push` with `error=` or
`conflict=`. Each names the repo and the cause; nothing is changed or retried behind your back.

## Gotchas found while building it

- **Each project's PAT travels with its own `gh` calls.** `gh.sh` passes the project's `GITHUB_PAT_TOKEN` to each
  command, and nothing logs `gh` in, so skills running at the same time in different projects can't pick up each
  other's token (JST-331; before it, statuscheck's machine-wide login made them race).
- **Running a skill from inside a member is fine.** Every script resolves the workspace as the project root, so
  `.jst/` and the credentials are found there, never inside the member.
- **Don't `git submodule update` by hand in an issue worktree.** It puts every member back on the workspace's gitlink,
  off its issue branch. Run `repos.sh provision`.
- **A worktree's members have no venv, `node_modules` or git-ignored env files.** Give the project a
  `.jst/bootstrap.sh` ([Setup](./setup.md#6-recommended-a-bootstrap-hook)). Without one, the executor improvises, for
  example by copying a member's `.env.local` or starting its Docker stack.
- **Removing a worktree:** `git worktree remove` refuses when submodules are inside. Run `repos.sh remove-check` in
  it first, then `git worktree remove --force`. A squash-merged branch reads `ok`; `unpushed` means real work would be
  lost.
- **The issue went to Done after the first member merge.** A merge → Done automation is reacting to member repos.
  Scope it to the workspace ([Setup](./setup.md#5-scope-merge--done-automation-to-the-workspace)).
