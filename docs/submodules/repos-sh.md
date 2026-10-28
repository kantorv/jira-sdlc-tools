---
slug: /submodules/repos-sh
sidebar_position: 5
sidebar_label: repos.sh reference
---

# `repos.sh` reference

`plugins/jira-sdlc/skills/_shared/scripts/posix/repos.sh`, and its Windows twin `win/repos.ps1`, with the same
arguments, output and exit codes. It's the only script the skills call for repo work. Run it from anywhere inside the
project: it resolves the project root itself, including from inside a member. It takes no credentials of its own; the
`gh` calls use the session statuscheck logs in.

```text
bash repos.sh <verb> [--branch <b>] [--state all|open] [--base <b>] [--check] [--multistep]
                     [--add <paths>] [--title <t>] [--body-file <f>]
```

`--branch` defaults to the root's current branch. `--base` is the root PR's expected base, defaulting to
`DEFAULT_BASE_BRANCH`. A member's base is always its own: its `.gitmodules` `branch`, else `DEFAULT_BASE_BRANCH`.

## Verbs

| Verb | Prints | Exit |
| -- | -- | -- |
| `strategy` | `strategy=single\|submodules`, `root=`, `members=`, `pinned=` (key=value) | 0; 2 + `error=` if `JST_MEMBERS` is invalid |
| `list` | TSV `repo role initialized slug base branch dirty ahead`, root first. Local only, no network | 0; 2 + `error=` |
| `prs` | TSV `repo slug pr state base url`: one row per PR, `none` for a repo without one, `error` for one that couldn't be read. `--state open` keeps only OPEN | 0; 4 if any row is `error` |
| `gate` | `phase=`, `reason=`, `root=`, `members=`, then the `prs` table | 0 for every phase (a `stop` is a decision) |
| `land --title <t>` | `landed=`, `commit=`, `pr=`; or `error=` with nothing changed. `--title` (required) titles a new root PR, `<KEY>: <summary>` like its member PRs; a reused one keeps its title | 0; 1 on refusal |
| `land --check` | TSV `repo gitlink base result` (`ok` or why not), plus a `.gitmodules` row if it changed | 0; 1 on any failure |
| `provision` | `provisioned=` (members now on the issue branch), `pinned=` | 0; 1 + `error=` |
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
| `merged` | The root's PR is MERGED (in a single repo, the issue's PR) |
| `stop` | Anything else; `reason=` says what ([Troubleshooting](./troubleshooting.md#when-a-run-stops)) |

`root=` is the root's PR state (`none`, `open`, `merged`), and the multistep track reads it directly. `members=` is
`n/a` (no members), `none`, `open`, `merged` or `mixed`.

## Which repos a verb touches

- **single** (no `JST_MEMBERS`): the root only. `provision` and `sync` do nothing; `push` always pushes; `open-prs`
  opens the root's PR into `--base`, with no PR-set section; `land` has nothing to land.
- **submodules:** the root plus every member, in `JST_MEMBERS` order. A member takes part in an issue when its issue
  branch exists on its origin. `open-prs` never opens a root PR (landing does).

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
