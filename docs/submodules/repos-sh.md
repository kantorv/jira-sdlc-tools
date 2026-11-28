---
slug: /submodules/repos-sh
sidebar_position: 5
sidebar_label: repos.sh reference
---

# `repos.sh` reference

`plugins/jira-sdlc/skills/_shared/scripts/posix/repos.sh`, and its Windows twin `win/repos.ps1`, with the same
arguments, output and exit codes. It's the only script the skills call for repo work. Run it from anywhere inside the
project: it resolves the project root itself, including from inside a member. It takes no credentials of its own: its
`gh` calls go through `gh.sh`, which runs each one with the project's `GITHUB_PAT_TOKEN` and logs nothing in (JST-331).

```text
bash repos.sh <verb> [--branch <b>] [--state all|open] [--base <b>] [--check] [--multistep]
                     [--add <paths>] [--title <t>] [--body-file <f>] [--against <branch>…]
```

`--branch` defaults to the root's current branch. `--base` is the root PR's expected base, defaulting to
`DEFAULT_BASE_BRANCH`. A member's base is always its own: its `.gitmodules` `branch`, else `DEFAULT_BASE_BRANCH`.

## Verbs

| Verb | Prints | Exit |
| -- | -- | -- |
| `strategy` | `strategy=single\|submodules`, `root=`, `members=`, `pinned=` (key=value) | 0; 2 + `error=` if `JST_MEMBERS` is invalid |
| `list` | TSV `repo role initialized slug base branch dirty ahead`, root first. Local only, no network | 0; 2 + `error=` |
| `prs` | TSV `repo slug pr state base url`: one row per PR, `none` for a repo without one, `error` for one that couldn't be read. `--state open` keeps only OPEN | 0; 4 if any row is `error` |
| `gate` | `phase=`, `reason=`, `root=`, `members=`, then the `prs` table. With `conflict`, a `sensitive=` line after `members=`; with a `stop` that couldn't read the state, `unknown=prs` or `unknown=conflicts` | 0 for every phase (a `stop` is a decision) |
| `conflicts [--against <branch>…]` | TSV `repo against result files sensitive recipe`: per repo, the branch's dry-run merge with its base, then with each `--against` branch ([below](#conflicts)). Only git runs, no GitHub API | 0; 4 if any row is `error` |
| `resolutions` | TSV `repo commit by files`: the conflict-resolving merges on `origin/<branch>` that its base lacks, newest first ([below](#resolutions)) | 0; 4 if any row is `error` |
| `since --repo <repo> --commit <sha>` | `verdict=`, `reason=`, then TSV `commit kind`: does an approval at `<sha>` still cover `origin/<branch>` in `<repo>` ([below](#since)) | 0; 4 with `verdict=error` |
| `land --title <t>` | `landed=`, `base_merged=` (only when [the gitlink step](#the-landings-gitlink-step) ran), `commit=`, `pr=`; or `error=` with nothing changed. `--title` (required) titles a new root PR, `<KEY>: <summary>` like its member PRs; a reused one keeps its title | 0; 1 on refusal |
| `land --check` | TSV `repo gitlink base result` (`ok` or why not), plus a `.gitmodules` row if it changed | 0; 1 on any failure |
| `provision` | `provisioned=` (members now on the issue branch), `pinned=`. Checks out every member first, so it is what makes a fresh worktree's empty member folders usable, even with nothing in scope | 0; 1 + `error=` |
| `provision --add <paths>` | Same, after creating and pushing the issue branch in each listed member, from `origin/<base>` (space- or comma-separated; every path must be a member) | 0; 1 + `error=` |
| `sync` | `synced=`; or `conflict=`, `files=` with the merge left for the user | 0; 1 on conflict |
| `push` | `pushed=` (members first, `.` = the root, last) | 0; 1 + `error=` |
| `open-prs` | TSV `repo slug pr action url`, `action` = `created` or `exists` | 0; 1 + `error=` |
| `remove-check` | TSV `repo result detail` (`ok`, `dirty`, `unpushed`, `unknown`), then `safe=yes\|no` | 0 safe; 1 not |

Usage errors print to stderr only, and exit 2.

### `gate` phases

| `phase` | When |
| -- | -- |
| `none` | No PR on the branch in any repo |
| `review` | A leaf PR is OPEN: the root's in a single repo, a member's otherwise |
| `land` | Every member with commits on the branch has a MERGED PR, and the root has none |
| `review-landing` | The root's PR is OPEN and every member PR is MERGED |
| `conflict` | It would be `review`, `land` or `review-landing`, but the branch conflicts with its base in the root, or in a member whose PR is open: the issue is paused, since each of those starts a review or a merge. `reason=` names each repo and its files: `conflicts with origin/development in app: core/landing.py` |
| `merged` | The root's PR is MERGED (in a single repo, the issue's PR) |
| `stop` | Anything else; `reason=` says what ([Troubleshooting](./troubleshooting.md#when-a-run-stops)) |

`root=` is the root's PR state (`none`, `open`, `merged`), and the multistep track reads it directly. `members=` is
`n/a` (no members), `none`, `open`, `merged` or `mixed`. `--multistep` (the issue has Jira sub-tasks) gives `stop` as
soon as a member takes part, with a PR or with commits pushed; a workspace-only multistep issue reads as a single repo.

`conflict` comes from the same dry run as `conflicts`, against the base only. It never replaces `none`, `merged` or
`stop`. Two results are not a pause: `gitlink` (the landing fixes it), and a conflict between two open issue branches,
since neither base has moved yet (the gate takes no `--against`; that warning is the `conflicts` verb's). A check that
can't be read (a failed fetch, a member not checked out) is `stop`, because unknown is not none, and it says so with
`unknown=conflicts` (`unknown=prs` when `gh` failed), so a caller that last read `conflict` keeps it rather than
reading the pause as lifted. A git older than 2.38 can't dry-run a merge at all: the phase then stands, and `reason=`
ends `(conflicts not checked: …)`.

With `conflict`, `sensitive=` lists the base rows' `sensitive` files as `<repo>:<path>` (space-separated, empty when
none): those always go to a human, whatever a grant says.

### `conflicts`

Each row is one dry-run merge, `git merge-tree --write-tree` of `origin/<branch>` with `origin/<base>` (or with
`origin/<against>`), after one `ls-remote` and one fetch per repo. Nothing in a worktree or an index moves, and the
branch is read off origin, so unpushed work doesn't count. Needs git 2.38 or later.

| `result` | Means |
| -- | -- |
| `clean` | Merges clean. Against the base, the branch also contains it already |
| `behind` | Against the base only: merges clean, but the branch lacks it |
| `conflict` | Real conflicts; `files` names them |
| `gitlink` | The only conflicted paths are member pointers, and in each one side's commit contains the other's: git fast-forwards the submodule, but GitHub, which doesn't look inside submodules, calls it a conflict |
| `error` | It couldn't be read; `files` is the reason: git too old, a fetch failure, a branch missing from the root's origin, a member not checked out. Never `clean` |

Two more columns mark the conflicted files (`-` when none), the plugin's reading so a caller keeps no list of its own:

| Column | Means |
| -- | -- |
| `sensitive` | The files a human resolves, grant or not: `.jst/`, `stack`, `stack.d/`, `.github/workflows/` and migrations |
| `recipe` | `<recipe>:<path>` for the files a mechanical recipe resolves, never also sensitive: `gitlink` (a member pointer one side's commit contains) and `migration-number` (a numbered migration this branch added shares its number with one the other side added in the same folder since the merge base, at the same path or under another name: renumber this branch's onto the other's leaf). Two names merge clean in git, so the row lists both files and reads `conflict` though git saw none |

A member whose origin has no `--branch` takes no part, and gets no rows; likewise a member whose origin lacks an
`--against` branch (that other issue doesn't touch it). `--against` may be repeated, or list several branches, space-
or comma-separated. The web app runs it for every live issue worktree of a project, each against the others.

### `resolutions`

Each row is a merge on `origin/<branch>` that its base lacks and whose parents, merged again, conflict: a merge that
resolved a conflict. `by` is `agent` when its message carries a `Conflict-Resolved:` trailer (the executor's resolve
mode), else `hand`; `files` is what it resolved; newest first. The reviewer's resolution review keys on it: a merge
the PR's last approval didn't contain is code no review saw. `git show --remerge-diff <commit>` shows the resolution.
A repo that can't be read is an `error` row (`by` = `error`, its reason in `files`) and exit 4.

### `since`

The reviewer's step 3a: its latest verdict on a PR is an approval, of the commit `--commit`, and the PR's head may have
moved since. Each commit on `origin/<branch>` since `<sha>` that the base lacks, oldest first, has a `kind`:
`resolution` (a merge whose parents, merged again, conflict: a `resolutions` row), `base-merge` (only base commits
merged in, and its tree is git's clean merge), `merge` (another branch, an octopus, or a clean merge carrying edits of
its own) or `commit`. `verdict=approved` when nothing or only base merges came since; `resolution-review` when the
rest are resolutions (the resolution review reads only those); `full` on any `merge` or `commit`, and when the branch
doesn't contain `<sha>` at all (a rebase, a force push). `--repo` is `.` for the root.

### The landing's gitlink step

Two landings that move the same member pointer conflict on GitHub, though `git merge` fast-forwards the pointer. So
`land`, after its landing commit and before the push, dry-runs the root's merge with `origin/<base>`: when the result
is `gitlink`, it merges the base in, keeps for each pointer the commit that contains both sides, commits, and prints
`base_merged=<paths>`. No question, no human. Anything else is left as it is (a real conflict is the gate's pause).

## Which repos a verb touches

- **single** (no `JST_MEMBERS`): the root only. `provision` and `sync` do nothing; `push` always pushes; `open-prs`
  opens the root's PR into `--base`, with no PR-set section; `land` has nothing to land.
- **submodules:** the root plus every member, in `JST_MEMBERS` order. `provision` puts a member on the issue branch
  when that branch exists on its origin. The member **takes part**, for `gate` and `open-prs` alike, only once it has
  commits ahead of its base or a PR on the branch; an empty issue branch doesn't count. `open-prs` opens a root PR
  only when no member takes part (a workspace-only issue, whose PR goes into `--base` like a single repo's);
  otherwise landing does.

## Contributing

- **Tests:** `bash scripts/check-repos.sh [--ports]`, plus `scripts/check-ensure-local-env.sh` for the credentials rule.
  Both build throwaway repos with local bare remotes, behind GitHub-shaped URLs (`url.*.insteadOf`), and a fake `gh`.
  Run them after any change to `repos.sh`, the strategies, `_jst_root` or statuscheck.
- **Two ports, one contract.** Edit `posix/` and `win/` together, and diff them under `STATUSCHECK_FORCE_OS=windows`
  (AGENTS.md). In PowerShell, an in-process function that calls `exit` ends the whole script and drops output still
  being captured, so the PowerShell verbs compute first and exit only at the top.
- **A new layout is a new strategy:** `strategies/<name>.sh` (and `.ps1`), defining `s_<verb>` for every verb, usually
  by delegating to the shared `v_<verb>` functions. Only the strategy selection in `repos.sh` changes; the skills
  don't.
