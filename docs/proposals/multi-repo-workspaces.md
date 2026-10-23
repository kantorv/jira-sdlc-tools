---
slug: /proposals/multi-repo-workspaces
sidebar_position: 1
sidebar_label: Multi-repo workspaces
---

# Proposal: multi-repo support (a workspace repo with member repos)

|  |  |
| -- | -- |
| Status | Proposal, not implemented |
| Written | 2026-10-23, against plugin 0.8.10 |
| Motivating project | `kantorv/talking-head-studio` (Jira `THS`), issue THS-2 |
| Covers | **one** kind of multi-repo project: a *workspace repo* holding the `.jst/` config, with independent *member repos* checked out at fixed paths inside it (§3, type 1) |

It builds on [Parallel instances](../parallel-instances/RUNNING-MULTIPLE-COPIES.md): there, one worktree becomes one
running copy of the app; here, one issue spans several repos. Requirement IDs (`MR-…`) are stable, so commits, Jira issues and tests can cite them. **MUST** marks what the feature
needs to be correct; **SHOULD** marks what it needs to be pleasant; **MAY** marks options.

## 1. Summary

The plugin assumes one repository per project: one `.jst/`, one GitHub repo, one PR per leaf issue. A workspace that
holds several independent repos breaks that assumption at every stage.

- **Assigner:** creates a branch and worktree in the workspace only.
- **Executor:** commits, pushes and opens its PR in the workspace only.
- **Reviewer:** looks for the PR in the workspace only, finds none, and correctly stops.

Today a project gets through by adding prose rules to its `CLAUDE.md`. That works only as long as the model follows
the prose over the skill.

This document specifies native support:

- A committed list of member repos.
- One branch name per issue, used in every repo the issue touches.
- An issue's **PR set**: all PRs, in any of those repos, whose head is the issue branch.
- Executor and reviewer steps that work on the whole PR set.
- A Done gate that waits for the whole set.

A project with no member list behaves exactly as today.

## 2. Background: what broke on THS-2

The workspace (`talking-head-studio`) holds `CLAUDE.md`, a few scripts and `.jst/`. Five project repos (server, front
end, pipeline, face, TTS) sit in git-ignored subfolders, each with its own GitHub repo. For THS-2:

1. The assigner created `feature/THS-2-…` and its worktree in the workspace. Fine, but no project repo was touched.
2. The project's own `.jst/bootstrap.sh` added worktrees of three project repos *inside* the workspace worktree, on the
   same branch name, and symlinked the other two. That's the sibling layout the projects need to find each other.
3. The executor, steered by a `CLAUDE.md` rule, committed in `talking-frontend/` and later in `talking-server/`, and
   opened talking-frontend#1 and talking-server#1. The workspace had no changes, so there was no workspace PR. The
   skill itself would have run `gh pr create` in the workspace and failed for want of commits.
4. The reviewer's `current_pr` row queried `kantorv/talking-head-studio` only, got `none`, and its single-step phase
   check stopped with "the executor hasn't opened a PR". Correct per the skill; wrong for the project.

The assumptions that break, and where:

| Assumption | Where it lives | What happens with member repos |
| -- | -- | -- |
| The project root is the git toplevel, and holds `.jst/` | `statuscheck.sh` (`WT_ROOT`), every script | Running inside a member worktree gives `jst_dir FAIL`; running in the workspace never sees member PRs |
| One GitHub slug per project | `current_pr`, `gh_repo_access`, `gh pr …` without `-R` | Only the workspace repo is checked or queried |
| One branch per leaf, in one `.git` | assigner step 6, `git config branch.<b>.parentbranch` | Member repos get no branch and no parentbranch config |
| One PR per leaf | executor step 10, reviewer phase checks, 3a–3d, 5a | No PR, or the wrong repo |
| PR base resolved per branch | `pr_base.sh` | No answer for a member repo's base (it may even have a different base name) |
| Merging the PR finishes the issue | GitHub-for-Jira merge automation, executor step 11 | The **first** member PR merged may move the issue to Done while the rest are open |

## 3. Kinds of multi-repo projects

"Multi-repo" covers several different structures. This document covers **type 1 only**. The others are listed so
they aren't assumed to work, and so the design leaves room for them.

| # | Type | Shape | Status |
| -- | -- | -- | -- |
| 1 | **Workspace with member repos** (meta-repo, git-ignored children) | A small "workspace" repo holds shared config and docs. Member repos are independent clones at fixed relative paths, listed in the workspace `.gitignore`. A feature uses the same branch name in each repo it touches, with one PR per repo | **Covered here** |
| 2 | **Git submodules** | The parent repo records each child as a gitlink (a commit SHA). A feature changes the child repos and then bumps the gitlinks in a parent PR | Not covered. Differs from type 1 in: worktrees need `git submodule update --init` and child worktrees inside a parent worktree; child commits must be pushed before the parent PR is mergeable; the parent PR's diff is SHA bumps, not code; the review must follow each bump to the child PR or commit range; merge order is forced (children first, then a parent bump to the *merged* SHAs). A possible extension: `kind=submodule` members whose PR set adds "parent bump PR", and a reviewer check that each bump points at a merged commit |
| 3 | **Polyrepo without a parent** | Sibling repos (`backend/`, `frontend/`) next to each other on disk, with no repo above them. Jira issues span them | Not covered. No natural home for `.jst/`. Options: designate one repo as the "home" of `.jst/` with a members file that points at sibling paths (`../frontend`), or a `.jst/` outside any repo. The worktree layout has no parent worktree to nest in |
| 4 | **Manifest-based** (Google `repo`, `west`, `vcstool` `.repos`, `gclient` DEPS, `mani`, `meta`) | A manifest file lists repos, revisions and paths; a tool checks them all out | Not covered. Close to type 1 (the manifest *is* a member list), but the tool owns checkouts and branches (`repo start`, `west update`); the plugin would have to drive the tool rather than `git worktree`. A `kind=manifest` adapter could read the member list from the manifest |
| 5 | **Package-coupled polyrepo** | Repos depend on each other through published versions (npm, PyPI, Maven), not paths. A feature means a library PR, a release, then a consumer PR that bumps the version | Not covered. Merge order includes a *release* step in between; a consumer PR can't be tested until the library version exists. Needs "linked issues across repos" and probably separate Jira issues per repo, not one branch name |
| 6 | **Git subtree / vendored copies** | Other repos' code merged into this repo's history | Already works as a single repo; contributing back upstream is out of scope |
| 7 | **Monorepo** (one repo, many packages) | One git repo | Already works; not multi-repo |
| 8 | **Mixed hosts** | Members on GitHub and GitLab or Bitbucket | Not covered: the plugin uses `gh` only. Type 1 assumes every member is on GitHub and reachable with the same `gh` login and PAT |
| 9 | **Fork-based contribution** | A feature PR goes from a fork to an upstream repo the team doesn't own | Not covered: PR head `owner:branch`, a different auth model, upstream review not under the team's control |

Type-1 assumptions this document relies on:

- Members are git repos at fixed paths relative to the workspace root.
- Each member has one GitHub remote (`origin`).
- All members are reachable by the project's one `gh` login and PAT.
- An issue's branch name is the same in every repo.
- Members don't have their own `.jst/` (or theirs is ignored, see `MR-CFG-6`).

## 4. Goals and non-goals

Goals:

- **G1:** One assigner, executor and reviewer command per role still handles an issue that changes several repos.
- **G2:** The PR set is derived from GitHub, not from state the plugin stores. Two runs, or a fresh clone, see the
  same set.
- **G3:** Each member PR is reviewed and given a verdict on its own repo, plus one aggregated Jira report.
- **G4:** An issue reaches Done only when its whole PR set is merged (or the human says otherwise).
- **G5:** Zero change for single-repo projects, with no new required config.
- **G6:** POSIX and Windows parity, and no project values hard-coded in skills (repo `AGENTS.md` rules).

Non-goals:

- Types 2–9 of §3.
- Merging: the plugin still never merges. It reports the merge order instead.
- Atomic cross-repo merges, merge queues, release tagging per member.
- Runtime provisioning (databases, ports): that stays the project's `.jst/bootstrap.sh`.
- Different branch names per repo for one issue.

## 5. Terms

| Term | Meaning |
| -- | -- |
| **Workspace** | The repo that holds `.jst/`, where the skills run. It can have code of its own |
| **Member** | A repo listed in the members file, cloned at `<path>` under the workspace root |
| **Issue branch** | `<PREFIX><KEY>-<slug>`, the same name in the workspace and every member that takes part |
| **Issue worktree** | The workspace worktree the assigner creates (`<WORKTREES_DIR>/worktree-<KEY>`) |
| **Member worktree** | A git worktree of a member, at `<issue worktree>/<path>`, on the issue branch |
| **In scope** | The members the assigner expects the issue to touch. Guidance for provisioning, not a gate |
| **PR set** | Every PR in any state whose head is the issue branch, in the workspace and all members. The source of truth |
| **Merge order** | The order members must merge in, from the members file (`order`). Lower merges first |

## 6. Configuration

### MR-CFG-1: a members file (MUST)

A new tracked file, **`.jst/jira-sdlc-members.tsv`**. Its presence turns multi-repo mode on; when it's absent,
nothing changes (G5). Its format: whitespace-separated columns, `#` comments, one member per line, then a header row:

```text
# path              slug                         base         production  order  outside_scope
talking-pipeline    kantorv/talking-pipeline     development  main        10     link
talking-head        kantorv/talking-head         development  main        10     link
tts2026             kantorv/tts-demo             development  main        10     link
talking-server      kantorv/talking-server       development  main        20     link
talking-frontend    kantorv/talking-frontend     development  main        30     link
```

| Column | Meaning | Validation |
| -- | -- | -- |
| `path` | Folder under the workspace root (no `..`, no trailing slash) | Exists in the main checkout, is a git repo, is git-ignored by the workspace |
| `slug` | `owner/repo` on GitHub | `origin` of the member points at it (`MR-SC-2`) |
| `base` | The member's planned-work base branch | Exists on `origin` |
| `production` | The member's production branch (hotfix base) | Exists on `origin`; differs from `base` |
| `order` | Merge order: an integer, where equal values mean "independent" | Integer |
| `outside_scope` | What a member *not* in scope gets in the issue worktree: `link` (a symlink to the main checkout's folder, for projects that need the full sibling layout) or `none` | One of the two |

Why a TSV and not more `KEY=VALUE` lines: member names have hyphens and slashes, which can't be shell variable
names, and a table is easier to read and diff. One parser in `members.sh` / `members.ps1` (`MR-SCR-1`) is the only
reader.

### MR-CFG-2: workspace PR policy (SHOULD)

`WORKSPACE_PR=if-changed|always` in `jira-sdlc-tools.env`, default `if-changed`. With `if-changed`, the workspace PR
exists only when the workspace branch has commits. `always` asks the executor to open an *umbrella* PR in the workspace
every time, with a body listing the member PRs. That gives teams a single GitHub page per issue. The commit it needs
is an open question (Q2).

### MR-CFG-3: in-scope list in the PR-target comment (MUST)

The assigner's comment gains a machine-readable list:
`PR target branch: development. Worktree: <path>. Members: talking-server, talking-frontend.`
That's how a later run (or a fresh clone) knows which member worktrees to provision. An empty list (`Members: none`)
means workspace only.

### MR-CFG-4: per-member bases follow from the workspace base (MUST)

A top-level planned issue targets each member's `base`; a hotfix targets each member's `production`. A sub-task
targets its parent's branch name in the same member repo. The resolver (`MR-SCR-3`) maps the workspace answer
onto each member, so a member whose base is called `develop` still works.

### MR-CFG-5: credentials stay single-sourced (MUST)

Members never get a `jira-sdlc-tools.local.env`. Every script reads the workspace's, and `gh` uses the existing login
and PAT. jst-install verifies the PAT can reach every member slug (`MR-INS-2`).

### MR-CFG-6: a member with its own `.jst/` (SHOULD)

If a member has a `.jst/` of its own (it is also used standalone), the workspace's config wins inside the issue
worktree, and statuscheck reports `WARN member_jst` so the conflict is visible.

## 7. Requirements by component

### 7.1 Scripts (new and changed)

All new scripts have POSIX and PowerShell twins with the same arguments, output and exit codes, and tests next to
`jira.test.sh`. The **reviewer `SKILL.md` is at its word ceiling** (6,348 of an accepted 6,500 words in 0.8.10), so the multi-repo logic MUST live in scripts and
in one `skills/_shared/multi-repo.md`, loaded only when the members file exists. The skills gain one line each that
says "in multi-repo mode, run X and follow `multi-repo.md`".

- **MR-SCR-1 `members.sh`** (MUST): parses and validates the members file. Subcommands:

  - `list`: `path slug base production order outside_scope` per member, in merge order.
  - `check`: validation rows for statuscheck.
  - `slug <path>`.
  - `base <path> --for <workspace-base>`: maps the base per `MR-CFG-4`.
  - Exit codes: 0 ok, 2 file invalid (with the line number), 3 no file (single-repo mode).

- **MR-SCR-2 `pr_set.sh`** (MUST): `pr_set.sh --branch <issue-branch> [--state all|open]` prints one line per PR in
  the workspace and every member, plus a summary line:

  ```text
  repo=<path|.> slug=<owner/repo> pr=<n> state=<OPEN|MERGED|CLOSED> base=<branch> url=<url> draft=<bool>
  summary total=<n> open=<n> merged=<n> closed=<n> repos_with_branch=<list> repos_without_pr=<list>
  ```

  - `repos_with_branch` lists repos where the issue branch exists on `origin` but has no PR. That's the "pushed but
    no PR yet" case the reviewer has to flag.
  - It uses `gh pr list -R <slug> --head <branch> --state all`.
  - It applies the *Reading PRs* rule of the reviewer: an empty result is confirmed by a second query before it
    counts as absent.
  - A `gh` failure for one repo prints `error=…` for that repo and exits 4. That means "unknown", never "none".

- **MR-SCR-3 `pr_base.sh --repo <path>`** (MUST): resolves the base for the issue branch in that member. Sources in
  order:

  1. The member's `git config branch.<b>.parentbranch`.
  2. The workspace's resolution (existing sources 1–4) mapped through `members.sh base`.

  Output is unchanged (`base=…`, `source=…`) plus `source=mapped:<workspace-source>` for the mapped case.

- **MR-SCR-4 `member_worktrees.sh`** (MUST): run from an issue worktree.

  - `ensure [--members a,b]`: for each in-scope member, creates `<issue worktree>/<path>` as a git worktree of
    `<main checkout>/<path>` on the issue branch. Reuses the local branch, else tracks `origin/<branch>`, else
    creates it from the member's resolved base (from `origin/<base>`, or local `<base>` when offline).
  - For each out-of-scope member with `outside_scope=link`, creates a symlink (a directory junction on Windows).
  - `status`: one row per member: `worktree|link|missing`, branch, dirty, ahead/behind.
  - Idempotent. Never touches an existing non-matching folder; it reports it instead.

- **MR-SCR-5 `statuscheck.sh`** (MUST): new rows in multi-repo mode, listed in 7.2.

- **MR-SCR-6 `ensure_local_env.sh`** (SHOULD): unchanged for the workspace. It MUST NOT copy credentials into member
  worktrees.

### 7.2 statuscheck

| Row | Status rules | Detail |
| -- | -- | -- |
| `members_config` | OK / FAIL (invalid file) / INFO "single-repo mode" | count and paths |
| `member_repo[<path>]` | FAIL if missing, not a repo, or `origin` ≠ slug; WARN if not git-ignored by the workspace | `slug`, `base`/`production` present on origin |
| `gh_repo_access[<slug>]` | FAIL on 404/403, with the remedy "add the repo to the PAT's repository access (a 404 looks like a typo but means no access)" | per member |
| `member_worktrees` | INFO in the main checkout; in an issue worktree: OK when every in-scope member is a worktree on the issue branch, WARN otherwise | `MR-SCR-4 status` summary |
| `current_pr` | Keeps its meaning for the current repo; in multi-repo mode its detail adds a pointer to `pr_set` | unchanged |
| `pr_set` | INFO/WARN, never FAIL | `MR-SCR-2` summary line; WARN when a branch is pushed without a PR, or a PR targets an unexpected base |
| `member_jst` | WARN when a member has its own `.jst/` | `MR-CFG-6` |

Rows are per member, so the table grows with the member count. Projects have a handful of members, so that's fine.

### 7.3 jst-install

- **MR-INS-1** (MUST): detect candidates. Git-ignored top-level folders that contain `.git`, with their `origin` slug
  and default branch. Offer to write `.jst/jira-sdlc-members.tsv` with `order` = 10 for all, and say that ordering is
  the user's call.
- **MR-INS-2** (MUST): check the PAT's access to each member slug (Contents + Pull requests read/write) and show the
  exact settings URL on failure.
- **MR-INS-3** (MUST): check that every member has the `base` and `production` branches on `origin`. Offer to create
  a missing `base` from `production` and push it (the step done by hand for this workspace).
- **MR-INS-4** (SHOULD): warn when the workspace `.gitignore` lists a member as `path/` (trailing slash): with
  `outside_scope=link` the symlink won't match and shows as untracked in issue worktrees.
- **MR-INS-5** (SHOULD): warn if the GitHub-for-Jira merge automation (or a Jira automation rule) moves issues to
  Done on merge, and link `MR-JIRA-1`.

### 7.4 Assigner

- **MR-ASG-1** (MUST): investigation covers member repos too. The skill reads members' code as it reads the
  workspace's. The scope decision (single-step vs multistep) is unchanged: **repos are not pieces**. A
  front-end-plus-server feature that must land in order is still one piece. A sub-task MAY map to one repo when the
  work really is parallel.
- **MR-ASG-2** (MUST): decide the in-scope members and write them into the issue description ("Repos in scope") and
  the PR-target comment (`MR-CFG-3`). When unsure, include the member: provisioning an untouched member costs one
  worktree, while missing one costs a failed executor step.
- **MR-ASG-3** (MUST): branch creation. As today for the workspace (branch, push, parentbranch, worktree). For each
  in-scope member: create the issue branch from the member's resolved `<BRANCH_FROM>` (base, or
  `origin/<production>` on the hotfix path), push it, and set `branch.<b>.parentbranch` to the member's base. Then run
  `member_worktrees.sh ensure` in the new issue worktree.
  - Creating member branches up front (not lazily) makes the issue visible on every repo's branch list and in
    GitHub-for-Jira's development panel from the start.
  - Partial failure: report exactly which repos got branches (the existing orphan rule applies per repo).
- **MR-ASG-4** (MUST, multistep): the parent branch is created in every in-scope member. Each sub-task branch is
  created in the members that sub-task touches (its own in-scope list), from the parent branch *in that member*.
  Sub-task PR-target comments carry the sub-task's `Members:`.
- **MR-ASG-5** (MUST): the assignment report lists, per repo: the branch, the base it will target, and the worktree
  path. It also gives the merge order from the members file.

### 7.5 Executor

Step numbers refer to the current `jira-task-executor`.

- **MR-EXE-1, step 1** (MUST): before the project hook, run `member_worktrees.sh ensure` with the comment's
  `Members:` list, so a hook can rely on member worktrees existing. Export two new hook variables (the contract is
  designed to grow):

  - `JST_MEMBERS`: in-scope paths, space-separated.
  - `JST_MEMBERS_FILE`: absolute path of the members file.

  The hook stays responsible for runtime only. A project's hook that creates worktrees itself, as this workspace's
  does today, keeps working: `ensure` is idempotent and so is the hook.

- **MR-EXE-2, step 2** (MUST): bring every member worktree current the same way as the workspace: merge
  `origin/<member parent branch>`, or the local one if it was never pushed. A conflict in one member stops the run
  with that member named, like a conflict today.

- **MR-EXE-3, steps 4–6** (MUST): when the work needs a member that's not in scope, add it: `member_worktrees.sh ensure --members <path>`, which creates the branch from the member's resolved base. Then record it in the run report. An
  out-of-scope `link` folder is the *main checkout* and MUST NOT be edited. The skill says this in one line, and
  `member_worktrees.sh status` flags dirty `link` targets.

- **MR-EXE-4, step 7** (SHOULD): test per changed repo. Test commands are project-specific: they come from each repo's
  own docs or an optional `test` column (Q3), never from the skill.

- **MR-EXE-5, steps 8–9** (MUST): commit and push per repo that has changes, with explicit staging per repo as today.
  A repo with no changes gets no commit, and its pushed but empty branch is left alone (the reviewer ignores
  branches with no commits ahead of their base).

- **MR-EXE-6, step 10** (MUST): open or update **one PR per repo with commits ahead of its base**, base from
  `pr_base.sh --repo`, and title `<KEY>: <summary>` in every repo.

  - The workspace PR follows `WORKSPACE_PR` (`MR-CFG-2`).
  - Re-runs update existing PRs (found through `pr_set.sh`), never open duplicates.

- **MR-EXE-7, PR bodies** (SHOULD): each PR body ends with a "PR set" section listing every PR in the set with its repo
  and merge order. When the set changes, the executor updates the section in every open PR of the set, so a reviewer
  on any one PR sees the rest.

- **MR-EXE-8, step 11** (MUST): move the issue to In Review once every repo with commits has an open PR. If a repo
  has commits but its PR couldn't be opened, stay In Progress and say which.

- **MR-EXE-9, step 12** (MUST): the run report lists per repo: PR link, base, commits and tests, followed by the merge
  order. It stays one Jira comment (the existing rule).

### 7.6 Reviewer

- **MR-REV-1, discovery** (MUST): in multi-repo mode, run `pr_set.sh` right after the healthcheck. The PR set replaces
  `current_pr` in both phase checks.
  - "No PR" means no PR in *any* repo of the set.
  - A pushed branch with commits ahead of its base and no PR is flagged ("repo X has commits on the issue branch but no
    PR"); it isn't treated as absent.
  - A `gh` error on any repo means "unknown", so stop and say which repo, rather than review a partial set.
- **MR-REV-2, per-PR loop** (MUST): run the existing 3a–3d per PR, with `-R <slug>` on every `gh pr view`, `gh pr diff`
  and `gh pr review`.
  - Idempotency (3a) is per PR.
  - Each verdict is posted on its own PR.
  - Reading files for context uses the member worktree when it exists, otherwise `gh pr diff`.
- **MR-REV-3, cross-repo criteria** (MUST): a seventh dimension, *Consistency across the set*, added to the six:
  - **Contracts:** an interface changed on one side (an API field, a CLI flag, an event name, a shared constant) is
    matched on the other side within the set. Contracts are listed by the project in its docs; the plugin doesn't
    know them, so the skill tells the model to look for them in the project docs.
  - **Completeness:** no repo the change needs is missing from the set.
  - **Bases:** every PR targets its expected base (`pr_base.sh --repo`).
  - **Merge order:** a PR that depends on another must not be mergeable on its own in a way that breaks `base`. The
    reviewer states the order and flags violations.
- **MR-REV-4, verdict and gate** (MUST):
  - One canonical run report on the issue with a per-PR verdict table.
  - **Any** CHANGES REQUESTED moves the issue to In Progress, as today.
  - All approved → the existing "wait for merge" state, with the merge order spelled out.
- **MR-REV-5, Done offer** (MUST): step 7 offers Done only when every PR in the set is approved. The offer text
  states that the set merges in order, and that Done means the whole set merged (`MR-JIRA-1`).
- **MR-REV-6, multistep** (MUST): sub-task PRs per member target the parent branch in that member. The parent stage
  (5a/5b) finds or creates **one parent PR per member** whose parent branch has commits ahead of its base, and
  reviews them as a set with the same rules.
- **MR-REV-7, single repo unchanged** (MUST): without a members file, not one behaviour changes (G5). Tests cover both
  modes.

### 7.7 Hotfix path

- **MR-HOT-1** (MUST): `hotfix/<KEY>-<slug>` in every in-scope member, cut from `origin/<member production>`. The
  PRs target each member's `production`. It stays single-step.
- **MR-HOT-2** (MUST): the back-merge reminder in the assignment and run reports lists every member PR to carry back
  into `base`.

### 7.8 Jira and GitHub-for-Jira

- **MR-JIRA-1** (MUST, docs + jst-install check): with member repos, *merge → Done* automation moves the issue to
  Done when the **first** PR of the set merges. The docs MUST explain this and recommend one of two setups:
  - Turn that automation off and let the reviewer's step 7 (or a human) close issues.
  - Use an automation rule that transitions only when the merged PR is the last open PR of the set. Jira can't easily
    know that, so the first option is the default.
- **MR-JIRA-2** (SHOULD): when the GitHub for Jira app is installed on every member repo, its development panel
  already links each member's branch and PR, because the key is in the branch name. The run reports still list them, because the panel isn't visible from the CLI.

## 8. Backward compatibility and migration

- **MR-BC-1** (MUST): no members file → identical behaviour, output and statuscheck rows (`members_config` reads
  `INFO single-repo mode`).
- **MR-BC-2** (MUST): existing hooks keep working. The two new `JST_*` variables are additive; a hook that creates
  member worktrees itself and finds them already present must be idempotent, which this project's hook is.
- **MR-BC-3, migration of `talking-head-studio`** (informative, the first adopter):
  1. Add `.jst/jira-sdlc-members.tsv`, using §6's example, which is the real one.
  2. `.jst/bootstrap.sh` keeps its runtime parts. Its worktree and symlink creation can go, or stay as a harmless
     duplicate until the plugin release is installed.
  3. Remove the "Code changes go in the project worktrees" and "Reviewing" rules from the workspace `CLAUDE.md`. Keep
     only what's project-specific: the merge-order rationale and the interface list for `MR-REV-3`.
  4. Turn off merge → Done automation for `THS` if it's on (`MR-JIRA-1`).

## 9. Edge cases

| Case | Required behaviour |
| -- | -- |
| A member isn't cloned in the main checkout | statuscheck FAIL `member_repo[x]` with a `git clone` remedy; the assigner stops before creating anything |
| The PAT has no access to a member (404) | FAIL `gh_repo_access[slug]`, with the "404 means no access" remedy |
| The branch exists on a member's `origin` but not locally | `ensure` creates the worktree tracking it |
| A member's issue branch has commits but no PR | executor opens one; reviewer flags it (`MR-REV-1`) |
| A member PR targets the wrong base | reviewer: CHANGES REQUESTED, naming the expected base |
| A member PR was merged before review | it's in the set as MERGED; the reviewer reviews the open ones and notes the merged one ("merged without review") |
| A member PR was closed unmerged | reported, excluded from the gate; the report asks whether the change was dropped on purpose |
| A dirty `link` target (someone edited the main checkout through a symlink) | `member_worktrees.sh status` WARN; the executor never commits there |
| A conflict while bringing one member current | stop, naming the member and the files |
| A member renamed on GitHub | `gh` follows redirects for reads but `origin` mismatches: statuscheck WARN with "update the members file and the remote" |
| The same member listed twice, or nested paths | `members.sh check` FAIL with line numbers |
| Windows: symlink privilege missing | `ensure` falls back to a directory junction; if that fails, WARN and leave the member absent (`outside_scope=none` behaviour) |
| A fresh clone or another machine | the PR set comes from GitHub, in-scope from the Jira comment, bases from mapping: nothing depends on local git config |

## 10. Acceptance scenarios

Each is a test case (script tests where scripted, eval prompts where it's skill behaviour).

1. **Single-repo regression:** a project without a members file. Assigner, executor and reviewer outputs are
   identical to 0.8.8 for the existing eval set.
2. **THS-2 replay:** a members file as in §6. Issue: "a page in talking-frontend that also needs a talking-server
   ordering fix".
   - Assigner: branches pushed in the workspace, talking-frontend and talking-server; member worktrees inside the
     issue worktree; `Members: talking-server, talking-frontend` in the comment.
   - Executor: two PRs, both based on `development`, each body listing the other; no workspace PR; issue In Review.
   - Reviewer: finds both PRs, posts two verdicts and one Jira report; with all approved, offers Done only then, with
     the order "talking-server → talking-frontend".
3. **Reject one:** as in 2, with the server PR failing review. Issue back to In Progress. The front-end verdict is still
   posted. A re-run of the executor updates both PRs; the second review skips the unchanged, already-approved
   front-end PR (per-PR idempotency) and re-reviews the server PR.
4. **Scope growth:** the executor discovers talking-pipeline must change too. A worktree is added, a third PR opened,
   and every PR body's "PR set" section is updated.
5. **Missing access:** the PAT lacks `kantorv/tts-demo`. statuscheck FAILs that row; the assigner doesn't start.
6. **Hotfix across two members:** `hotfix/` branches from each `origin/main`, PRs into `main`, and the back-merge list
   names both.
7. **Multistep:** a parent with two sub-tasks, one per member. Parent branches exist in both members; each sub-task PR
   targets the parent branch in its own member; the parent stage opens and reviews two parent PRs.
8. **Unknown is not none:** `gh` times out for one member during review. The reviewer stops, naming it, and doesn't
   conclude "no PR".

## 11. Open questions

- **Q1, eager vs lazy member branches:** `MR-ASG-3` creates member branches up front for in-scope repos. Lazy creation
  (first commit) avoids empty branches when scope was over-estimated, but loses early visibility. Proposed: eager for
  in-scope, lazy for scope growth.
- **Q2, the umbrella PR's content:** with `WORKSPACE_PR=always`, what does the workspace commit hold? Options: a
  generated `.jst/changes/<KEY>.md` (the PR set, merge order, status), or an empty commit (`--allow-empty`). A file is
  reviewable and survives; it also accumulates. Proposed: start with `if-changed` only, and decide when someone asks
  for `always`.
- **Q3, per-member test commands:** a `test` column in the members file, or leave it to each repo's docs? A column
  makes the executor deterministic, but puts project commands in plugin config. That's allowed (it's config, not a
  skill literal).
- **Q4, member-level Jira issues:** some teams want one sub-task per repo for reporting. That's a multistep choice the
  assigner can already make (`MR-ASG-1`); confirm that no extra mechanism is needed.
- **Q5, submodule support (type 2):** worth designing `kind=submodule` members now, so the members file has a `kind`
  column from day one (default `clone`)? Proposed: yes, add the column now and accept only `clone`, which avoids a
  format change later.

## 12. Suggested delivery order

1. **Discovery, read-only:** `members.sh`, `pr_set.sh`, statuscheck rows, docs page, and the jst-install checks. Already
   useful: the reviewer stops being blind (with a `_shared/multi-repo.md` instruction to use `pr_set.sh`).
2. **Reviewer:** `MR-REV-*`, the highest pain today.
3. **Executor:** `MR-EXE-*` plus `member_worktrees.sh` and `pr_base.sh --repo`.
4. **Assigner:** `MR-ASG-*` (single-step first, then multistep).
5. **Hotfix and Jira automation guidance:** `MR-HOT-*`, `MR-JIRA-*`.
6. **Docs:** a new "Multi-repo projects" section on the site, next to "Parallel instances", including §3's table of
   uncovered types.
