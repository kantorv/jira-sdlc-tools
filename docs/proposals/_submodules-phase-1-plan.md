# Submodules support, phase 1: foundations (implementation plan)

|  |  |
| -- | -- |
| Status | Implemented (both PRs, on the JST-322 branch); see §7 for what changed against the plan. Decisions D1–D6 confirmed. Unpublished (`_` prefix): a working document that goes stale once the work lands |
| Written | 2026-10-24, against plugin 0.8.10, on `feature/JST-322-submodules-support-pilot-implementation` |
| Implements | Phase 1 of [the submodules strategy](submodules-strategy.md) §11 |

## 1. Goal and exit criteria

Phase 1 lays the groundwork and changes **no skill behaviour**. No `SKILL.md` calls anything new yet. When it's done:

1. Every script finds the project's `.jst/` from anywhere inside the project, including inside a member or a nested
   submodule (P1-1).
2. `ensure_local_env` can no longer write anything into a member, credentials included (P1-2).
3. `repos.sh strategy` and `repos.sh list` exist in both ports, with the strategy layout the later phases fill in
   (P1-4).
4. statuscheck shows `repo_strategy` on every run, and `member_repo[<path>]` per member (P1-5).
5. On a project without `JST_MEMBERS`, statuscheck's output is identical to `development`'s plus one INFO row, and a
   test proves it (P1-7).

## 2. Facts this plan rests on (lab-tested 2026-10-24, git 2.43)

A parent with one member, which has its own nested submodule, plus a linked worktree of the parent:

| Run in | `--show-toplevel` | `--show-superproject-working-tree` | `.git` |
| -- | -- | -- | -- |
| `main` | `main` | (empty) | directory |
| `main/app` | `main/app` | `main` | file: `gitdir: ../.git/modules/app` |
| `main/app/lib` | `main/app/lib` | `main/app` | file |
| `wt` | `wt` | (empty) | file: `gitdir: <abs>/main/.git/worktrees/wt` |
| `wt/app` | `wt/app` | `wt` | file: `gitdir: ../../main/.git/worktrees/wt/modules/app` |
| `wt/app/lib` | `wt/app/lib` | `wt/app` | file |

- `--show-superproject-working-tree` goes up **one level only**. Finding the project root needs a loop.
- A member's `.git` is a file, exactly like a linked worktree's. Every "is this a worktree?" test that looks at `.git`
  misreads a member.

`ensure_local_env.sh`, as it is on `development`, run from inside a member (this was only inferred in the strategy
doc; now it's tested):

| Run in | Result |
| -- | -- |
| `main/app` (member of the main checkout) | Exit 0. **Copies `jira-sdlc-tools.local.env` into `main/app/.jst/`**, plus `.gitignore` and `jira-sdlc-tools.env`. The credential is ignored, but `.jst/` shows as untracked in the member, so `git add -A` there would commit the other two files to the member's repo |
| `wt/app`, `wt/app/lib` (members of a worktree) | Exit 1. Writes a stray `.jst/.gitignore` into the member, and the remedy says to create the credential "in the main checkout", which already has it |

## 3. Work items

### P1-1 One rule for finding the project root

**Rule:** walk up from `git rev-parse --show-toplevel` through `--show-superproject-working-tree` until it's empty.
The root is the **outermost** level of that chain that has a `.jst/` folder. If no level has one, it's the outermost
level.

| Case | Result | Why it's right |
| -- | -- | -- |
| Single repo | The repo | Identical to today |
| Inside a member | The parent | The member has no `.jst/` |
| A member that has its own `.jst/` (also used standalone) | The parent | The project's config wins (the multi-repo proposal's MR-CFG-6) |
| The project vendored into an unrelated repo with no `.jst/` | The project | The outer repo doesn't have `.jst/`, so it doesn't count |
| A fresh worktree whose `.jst/` isn't tracked yet, run from a member | The worktree | No level has `.jst/`, so the outermost wins, which is where `ensure_local_env` should create it |
| A type-1 workspace (git-ignored clones, not submodules) | The clone itself | There's no superproject link: unchanged, and out of scope |

**Where:** a new sourced helper, `_shared/scripts/posix/_jst_root.sh`, defining `jst_root`. Its twin is
`win/_jst_root.ps1`, dot-sourced as `. "$PSScriptRoot/_jst_root.ps1"`. This is the first sourced file in the scripts.
That's worth it: the loop is ~8 lines, and copying it into 16 files is the drift the twin rule already struggles with.

**Callers**, each a one-line change from `git rev-parse --show-toplevel` to `jst_root`, in both ports:

- `jira.sh` (`_cfg_dir`), `check_assignee.sh`, `get_assignee_email.sh`, `pr_base.sh` (`CFG_DIR`),
  `list_subtasks.sh` (`resolve_project`), `create_parent_and_subtasks.sh` (`CFG_ROOT`): config lookup only. No
  `cd`, because some of them take file arguments relative to the caller's working directory.
- `ensure_local_env.sh` and `statuscheck.sh`: see P1-2 and P1-3.
- `jira.test.sh` / `jira.test.ps1`: switch too, so the test reads the same config as the script it tests.

### P1-2 `ensure_local_env` never writes into a member

- `WT_ROOT` becomes `jst_root`. The "linked worktree?" test then runs on the project root, where `.git` being a file
  really does mean a worktree.
- Result, per §2: from `main/app` it resolves to `main` and does nothing, since that's the main checkout. From
  `wt/app` it resolves to `wt` and provisions `wt/.jst/`, which is the correct target. It never writes under a member.
- The stray-`.gitignore` and wrong-remedy cases disappear with it, because they came from the same misread root.

**Tests**, added to `scripts/check-ensure-local-env.sh`. They build the §2 lab with `mkproj` + `git submodule add`:

| # | Case | Assert |
| -- | -- | -- |
| 11 | Run in a member of the main checkout | Exit 0; no `.jst/` in the member; `git -C <member> status --porcelain` is empty |
| 12 | Run in a member of a fresh worktree | Exit 0; `wt/.jst/jira-sdlc-tools.local.env` exists and is ignored; nothing in the member |
| 13 | Run in a nested submodule of a worktree member | Same as 12 |
| — | `--ports` parity | Add 11–13 to the `parity` list |

### P1-3 statuscheck evaluates the project root, not the caller's folder

- Resolve the root **first**, before the branch is read (today `BR` is read at the top, from the current folder,
  before `WT_ROOT` is computed). Then `cd` to the root. statuscheck takes no path arguments, so that's safe.
- Effect: run from inside a member, every row describes the parent issue worktree (branch, issue key, `worktree`,
  `current_pr`), not the member's detached HEAD. Run from the root or a plain subfolder, nothing changes.
- `ENV_LOCAL_COPIED_FROM` re-derives the main checkout with the same three-dirname walk. It moves to the helper, so
  there's one implementation.

### P1-4 `repos.sh`: the front door, with two verbs

**Layout:**

```text
_shared/scripts/posix/repos.sh                    win/repos.ps1
_shared/scripts/posix/strategies/single.sh        win/strategies/single.ps1
_shared/scripts/posix/strategies/submodules.sh    win/strategies/submodules.ps1
```

**Strategy selection (MS-CF-1):** `JST_MEMBERS` empty or unset → `single`; set → `submodules`. It's read from
`.jst/jira-sdlc-tools.env` (team config, committed) through the same `cfg` parsing the other scripts use. Values are
space-separated paths, so the parser has to keep the internal spaces: the existing `sed` trims only the ends, which
is fine.

**Strategy contract:** `repos.sh` sources `strategies/<name>.sh`, which defines one function per verb (`s_strategy`,
`s_list`). `repos.sh` owns argument parsing, config, the root, and output helpers. A verb a strategy doesn't define
→ exit 2, "`<verb>` isn't supported by the `<name>` strategy". Later phases add verbs by adding functions.

**`repos.sh strategy`** prints `key=value` lines, the same style as `pr_base.sh`:

```text
strategy=submodules
root=/abs/path/to/project
members=threejs-skeleton threejs-skeleton-server
pinned=vendor/some-lib
```

- `pinned` lists every top-level submodule that isn't a member. In `single` mode it lists them all, so a project with
  submodules but no `JST_MEMBERS` sees what it could opt in.
- A listed path that isn't a top-level submodule → `error=JST_MEMBERS lists '<path>', which isn't a top-level submodule in .gitmodules`,
  exit 2. So does a duplicate, or a nested path.

**`repos.sh list`** prints a TSV with a header: easy to split in both ports, and still readable for the model.

```text
repo                     role    initialized  slug                              base         branch       dirty  ahead
.                        root    yes          kantorv/threejs-skeleton-studio   development  development  no     0
threejs-skeleton         member  yes          kantorv/threejs-skeleton-editor   development  (detached)   no     -
threejs-skeleton-server  member  yes          kantorv/threejs-skeleton-server   development  (detached)   no     -
```

| Column | Meaning |
| -- | -- |
| `repo` | `.` for the root, otherwise the submodule path |
| `role` | `root` or `member`. Pinned submodules aren't rows: they're never touched |
| `initialized` | Whether the member's working tree is checked out (`git -C <path> rev-parse` succeeds) |
| `slug` | `owner/repo` from the member's `origin`. When it isn't initialized, from `.gitmodules`' URL, resolved against the root's `origin` if it's relative. `-` if neither is a GitHub URL |
| `base` | The root: `DEFAULT_BASE_BRANCH`. A member: its `.gitmodules` `branch`, else `DEFAULT_BASE_BRANCH`. `branch = .` is reported as `error` in this column, because a base has to be a real name |
| `branch` | The current local branch, or `(detached)` |
| `dirty` | `yes` / `no` (`git status --porcelain`, untracked included) |
| `ahead` | Commits ahead of the upstream, or `-` when there's no upstream |

- `list` is **local only**: no network, so it's fast and statuscheck can call it without a timeout. Scope (does the
  issue branch exist on a member's `origin`?) needs GitHub, so it belongs to `prs` / `provision` in later phases.
- Exit 0 whenever the config is valid, even if a member isn't initialized: `list` reports facts, statuscheck judges
  them (MS-AR-2). Exit 2 for an invalid config, with the same `error=` as `strategy`.
- `single` prints exactly one row: `.`.

**Windows traps to design around** (both already hit in this repo):

- `jira.ps1` writes through `[Console]::Out`, which `&` can't capture. `repos.ps1` writes to the success stream
  (`Write-Output`), so `statuscheck.ps1` can capture it.
- A one-element array unrolls to a scalar under StrictMode. A project with a single member is the common pilot case,
  so wrap member lists in `@(...)` at every assignment.

### P1-5 statuscheck rows

Both rows are built from `repos.sh strategy` and `repos.sh list`, so the rules exist in one place:

| Row | When | Status |
| -- | -- | -- |
| `repo_strategy` | Always | `INFO single`, with `(N submodules present, none in JST_MEMBERS)` when `pinned` isn't empty. `OK submodules`: members and pinned paths. `FAIL` on exit 2, relaying `error=` as the detail, with the remedy "fix `JST_MEMBERS` in `.jst/jira-sdlc-tools.env`" |
| `member_repo[<path>]` | `submodules` only, one per member | `FAIL` if not initialized (remedy: `git submodule update --init <path>`). `FAIL` if `gh api repos/<slug>` 404s/403s (remedy: "give the PAT access to `<slug>`, or remove `<path>` from `JST_MEMBERS`"). `FAIL` if `base` isn't among the member's GitHub branches (`gh api repos/<slug>/branches`). `WARN` if the production branch isn't there (it's only needed for hotfixes). Otherwise `OK`, with slug, base, branch |

- Placement: right after `gh_repo_access`. The member probes are gated the same way: `WARN skipped` when `gh_auth`
  failed or the slug isn't a GitHub one. Each probe runs under the existing 30-second `TMOUT_CMD`.
- Cost: two network calls per member per run. A handful of members is fine. If it isn't, cache per run later.
- jst-install's row map: add `repo_strategy` and `member_repo[…]` to section 2 (GitHub), so the install doesn't read
  them as unexplained rows.

### P1-6 Configuration docs

- `_shared/project-config.md`: a new "Optional (in `.jst/jira-sdlc-tools.env`)" section for `<JST_MEMBERS>`, with
  the rule, the format, and a link to the strategy page's published URL (the plugin's docs must use site URLs, per
  AGENTS.md's link table).
- No template change: the team `.env` has no template in the plugin, and jst-install writing `JST_MEMBERS` is phase 6.

### P1-7 Tests: `scripts/check-repos.sh [--ports]`

A new harness in the style of `check-ensure-local-env.sh`: throwaway repos in `$TMPDIR`, local bare remotes, no
credentials, no network (`GITHUB_PAT_TOKEN=` blank, as that harness explains).

**Fixtures:**

| Id | Shape |
| -- | -- |
| A | Single repo, no submodules |
| B | Single repo with one vendored submodule, no `JST_MEMBERS` |
| C | Parent with two members, one pinned submodule, and a member with a nested submodule; `JST_MEMBERS` lists the two |
| D | A linked worktree of C, after `submodule update --init --recursive` |
| E | C with `JST_MEMBERS` naming a path that isn't a submodule, then a nested path, then a duplicate |
| F | C with one member not initialized |

**Assertions:**

- `jst_root` from every folder in §2's table, in C and D, returns the expected root. The same from a plain subfolder
  of the root.
- `repos.sh strategy` and `list` match golden output for A–F, with paths normalised to `<LAB>`, the way the existing
  harness does it.
- **The single-repo regression.** Export `development`'s scripts (`git archive <ref> plugins/jira-sdlc/skills/_shared/scripts`;
  `<ref>` defaults to `origin/development`). Run old and new statuscheck on A and B. The only allowed difference is the
  added `repo_strategy` row. That's the "golden-output test for single" MS-AR-1 asks for, starting here.
- statuscheck on C from inside a member reports the parent's branch and `jst_dir`, not the member's.
- `--ports`: the posix vs win diff of `repos` (both verbs) on A–F, and `_jst_root` through a tiny driver, with
  `STATUSCHECK_FORCE_OS=windows`.

Neither harness runs in CI today. Adding both to a workflow is cheap, but it's a separate decision (§6, D6).

### P1-8 Repo docs

- `AGENTS.md`:
  - add `repos` to the twin list and the parity loop;
  - note that `_jst_root` is sourced, so it has no output of its own to diff;
  - add `bash scripts/check-repos.sh [--ports]` under *Validating a change*;
  - one line under the `ensure_local_env` check saying it now covers members.
- [The submodules strategy](submodules-strategy.md) §8: point at this plan for the phase 1 details (TSV `list`,
  `strategy` verb, the root rule).

## 4. Slicing

Two PRs, so the security-relevant fix doesn't wait on the new script:

1. **The root rule:** P1-1, P1-2, P1-3, and their tests (11–13, `jst_root` assertions, the single-repo regression).
   It fixes a real credential-placement bug on its own, for any project with submodules.
2. **`repos.sh` and the rows:** P1-4, P1-5, P1-6, the rest of P1-7, and P1-8.

## 5. Out of scope for phase 1

- Any `SKILL.md` change apart from jst-install's row map cell.
- Verbs other than `strategy` and `list`. `prs`, `gate`, `provision`, `sync`, `push`, `open-prs`, `land` and
  `remove-check` come in phases 3–6.
- `pr_base --repo`, and member-aware `current_pr`.
- Converting the pilot (phase 2). Phase 1 is tested on lab fixtures only.

## 6. Decisions (all confirmed by the user, 2026-10-24)

- **D1, root rule:** the outermost level with `.jst/` (P1-1), rather than the nearest or simply the outermost.
- **D2, output formats:** `key=value` for `strategy`, TSV with a header for `list`.
- **D3, a sourced helper:** the first one in the scripts, instead of copying the loop into 16 files.
- **D4, statuscheck `cd`s to the root** (P1-3), so its rows describe the project, not the caller's folder.
- **D5, member probes in statuscheck:** two network calls per member per run.
- **D6, CI:** whether to run `check-ensure-local-env.sh` and `check-repos.sh` in a workflow. Neither runs anywhere
  automatically today.

## 7. Progress and deviations

- **PR 1 (P1-1 to P1-3), commit `3eb0221`:** the root rule, `ensure_local_env`, statuscheck's `cd`. Tests: 51 checks in
  `check-ensure-local-env.sh`. Run against `development`'s scripts, 11 of the 12 new checks fail.
- **PR 2 (P1-4 to P1-8):** `repos.sh` + `strategies/{single,submodules}.sh`, their `win/` twins, the two statuscheck
  rows, the `JST_MEMBERS` docs and jst-install's row-map cell. `check-repos.sh` grows to 73 checks.
- **Deviation, P1-5:** a member's branches are read with `gh api repos/<slug>/branches`, not `git ls-remote`. It uses
  the same PAT as every other probe and can't stall on an SSH prompt. Still two calls per member.
- **Deviation, invalid `JST_MEMBERS`:** `strategy` prints `members=` and `pinned=` empty next to `error=`, because a
  half-validated list would read as a real one.
- **Found while testing, fixed:**
  - PR 1's single-repo regression check ran statuscheck alone. In a fresh worktree that stops at the `jst_dir` gate,
    so the two worktree cases compared one row. It now runs `ensure_local_env` first, as a skill's step 1 does, and
    compares the full table. PR 1's change passes the stronger version.
  - In `statuscheck.ps1`, a `$rows` variable overwrote `$script:Rows` (PowerShell variable names are
    case-insensitive), deleting every row above it. The port-parity checks caught it. The block's variables now use
    an `rs`/`m` prefix.
- **Real-world check:** in the pilot (`threejs-skeleton-proj`, still git-ignored clones), `development`'s statuscheck
  and PR 1's give identical output, stderr and exit codes, in the main checkout and inside a clone.
