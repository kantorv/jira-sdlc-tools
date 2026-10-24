# Multi-repo workspaces: brainstorm (session reference)

|  |  |
| -- | -- |
| Status | Working notes, not a spec. Unpublished (`_` prefix) |
| Started | 2026-10-24, against plugin 0.8.10 |
| Follows up | [Proposal: multi-repo support](multi-repo-workspaces.md) |
| Pilot project | `~/projects/threejs-skeleton-proj` (workspace + 2 member repos, no `.jst/` yet) |

The aim of this session is to work out how to *think* about projects made of several repos before writing code, without
adding rules for one project type. These notes record where the thinking stands, so a cut or compacted session can
pick up from here.

## 1. The problem as stated

The plugin works well for single-repo projects. With several repos, the task lives at the parent level (one Jira
issue, one workspace worktree), but its commits and PRs land in the child repos it actually changes. Nothing in the
skills connects the two, which is the source of the confusion. THS-2 (proposal §2) is the first recorded case.

## 2. One abstraction, not a list of project types

Today the plugin assumes **1 issue = 1 branch = 1 PR = 1 repo**. Every multi-repo failure is that chain breaking.
Replace it with one idea:

> **An issue owns a set of changes. A change is (repo, branch, PR).**

A single-repo project is a set of size 1. In this model the parent-level task isn't "in" the workspace repo: the
Jira issue describes behaviour, and the repos are only where its code lands.

Every kind of multi-repo project has to answer the same seven questions. Types differ only in the answers:

| Question | Single repo | Workspace + members (pilot) | Submodules / manifest / package-coupled |
| -- | -- | -- | -- |
| **Discover:** which repos exist? | the git toplevel | a list of repos | gitlinks / manifest / dependencies |
| **Scope:** which repos does this issue touch? | trivial | judgement, recorded on the issue | judgement |
| **Checkout:** how to get an isolated copy? | one worktree | a worktree per repo, nested so siblings still find each other | `submodule update` / `repo start` |
| **Deliver:** what's the unit per repo? | branch + PR | branch + PR | branch + PR (+ a gitlink bump, + a release) |
| **Link:** how to find all changes of an issue? | `current_pr` | issue key in the branch name, queried across repos | same |
| **Order:** what must land first? | n/a | depends on the issue | forced by the type |
| **Gate:** when is it Done? | PR merged | the whole set merged | the set merged + the extra steps |

- **Discover, Scope, Deliver and Link are the same for every type.** That's the generic core.
- **Checkout and Gate are where the types differ.** That's where adapters go later. Build one adapter now
  (workspace + members) and leave room for the rest. The proposal's §3 type table already does this.

## 3. Three ideas that make it simpler

1. **Separate the config home from the code targets.** The deepest assumption is "the place holding `.jst/` is the
   git toplevel where commits go". In a single repo they coincide; here they don't. If the scripts find `.jst/` on
   their own (not via `git rev-parse --show-toplevel`), then "workspace + members", "polyrepo where one repo holds
   `.jst/`" and "`.jst/` outside any repo" become the same thing with a different home.
2. **Treat the workspace as a regular member.** List it as path `.` and handle it like any other repo: it gets a PR
   only if it has commits. That drops a special case (`WORKSPACE_PR`, proposal MR-CFG-2) and fixes the "workspace
   branch with nothing on it" oddity.
3. **Keep plugin config factual; leave relationships to project docs.** The repo list holds facts a script can check:
   path, slug, base, production. Merge order and cross-repo contracts belong in the project's own docs, read by the
   model. That's what "no project-specific rules" means in practice.

### Why a static `order` column fails on the pilot

The pilot's dependencies run both ways:

- The app depends on the server through the HTTP API.
- The server depends on the app because it runs `make_bboxes.py` and `convert.ts` as subprocesses.

A new API field means "server first"; a change to `convert.ts`'s flags means "app first, or both together". No single
per-repo number expresses that. Order belongs to each issue and should be decided by the assigner and recorded on the
issue, not stored per repo.

## 4. The design fork: decide before writing anything

|  | Model A: one issue, many PRs | Model B: one leaf issue per repo |
| -- | -- | -- |
| Shape | What the proposal specifies | Cross-repo work is split into sub-tasks, one per repo, ordered with Jira "blocks" links |
| Gains | Cross-repo review is natural: the reviewer sees both sides of a contract change together | Nearly every existing invariant survives, including merge → Done per sub-task |
| Costs | A PR set, a Done gate over the set, and turning off Jira's merge → Done automation (the first merge would close the issue) | More Jira noise; small changes forced into multistep; the contract check only happens at the parent stage |

**Recommendation:** build A's abstraction, since B is A with a set size of 1 per leaf. Teams that prefer B can still
decompose that way (proposal Q4). But B is a good **zero-code first pilot**, and it isolates which problems are about
"home vs target" rather than "PR sets".

**Decision: open.**

## 5. Notes on the proposal

The thinking is solid and §3's type list is valuable. As a starting point it's heavy (~5,300 words, ~50 `MR-*`
requirements).

- **Keep:** the repo list (minus `order`, maybe minus `outside_scope`), `pr_set` derived from GitHub by branch name,
  the "unknown is not none" rule, and the delivery order (reviewer first, since it's the most blind).
- **Defer until a pilot shows the need:** `order`, the umbrella PR, a per-member `test` column, the `link` symlinks.
- **Worth testing, not verified:** with the GitHub for Jira app on every repo, Jira's development panel already holds
  an issue's PR set. Reading it would be fully type-agnostic, but it's an internal API and lags GitHub, so at most a
  cross-check against `pr_set`.

## 6. User proposal: start concrete, with git submodules (type 2)

The user proposes starting from one specific type they know well, submodules, instead of the abstraction. Agreed: the
seven questions (§2) stay as the checklist, and submodules become the first concrete answer to them.

### The idea

1. The parent repo holds the children as submodules.
2. When a feature starts, the parent's issue branch sets `branch = <issue-branch>` in `.gitmodules` for each child the
   feature touches. Untouched children keep `development`.
3. Each involved child gets that branch.
4. In the issue worktree, `git submodule update --init --remote` checks out every child on the branch `.gitmodules`
   names. The worktree is "frozen" to the right branch per repo, and anyone can rebuild it from the parent branch alone.

### Why it's strong: git holds the multi-repo state

| Question | Submodule answer |
| -- | -- |
| Discover | `.gitmodules` *is* the members file. The proposal's TSV isn't needed |
| Scope | The parent branch's `.gitmodules` diff: children whose `branch` equals the issue branch. A commit, so reviewable and fresh-clone safe. Replaces the `Members:` line in the Jira comment |
| Checkout | `git submodule update --init --remote`. Sibling layout comes for free |
| Deliver | One PR per involved child, plus the **parent PR**: the umbrella PR the proposal left as an open question (Q2) |
| Link | For each child whose `branch` is the issue branch, look up the PR with that head in its repo |
| Order / Gate | Children merge first, then the parent. Submodules force this order |

### Gotchas to design for

1. **Git warns against the layout.** `git worktree`'s man page (git 2.43): *"support for submodules is incomplete. It
   is NOT recommended to make multiple checkouts of a superproject."* In practice: each worktree initializes its own
   copy of the submodules (slower, more disk), and `git worktree move`/`remove` is awkward with submodules inside.
   **The biggest risk: test it on the pilot first.**
2. **`--remote` gives a detached HEAD** at the tip of `origin/<branch>`. The executor must `git switch <branch>` in
   each child before committing. Scriptable, but explicit.
3. **Two-level commits.** Per child: commit, push. Parent: commit the gitlink bump, push. A parent pushed before a
   child points at a commit no one else can fetch.
4. **Undo the freeze before merging.** If the parent PR merges as is, `development`'s `.gitmodules` points at a
   feature branch about to be deleted. The parent branch needs a final *landing* commit: each `branch` back to the
   base, each gitlink bumped to the child's *merged* commit on its base. Children must merge first. Deterministic,
   so a script candidate.
5. **Squash merges in children break gitlinks.** The feature commit the parent points at becomes unreachable once its
   branch is deleted. The landing step (4) avoids this if it always re-points at the base tip after merge, and the
   gitlink checks must account for it.
6. **`branch = .` — an optional shortcut.** Git's special value means "the same branch name as the superproject's
   current branch", so `.gitmodules` wouldn't need editing per feature. The catch: `update --remote` fails for any
   child that doesn't have that branch. Prefer the explicit per-child `branch = <issue-branch>`: it keeps scope
   visible.

### What it means for the pilot

`threejs-skeleton-proj` is type 1 today (git-ignored clones). Using it for this means converting it:
`git submodule add` both repos, remove them from `.gitignore`. That's the user's call. THS stays type 1 and won't
benefit until a second adapter exists, which is fine as long as the seven questions stay the dividing line.

Suggested first check, before any plugin work, by hand on the pilot: create one issue branch with a `.gitmodules`
freeze, add a parent worktree, run `submodule update --init --remote`, commit in a child, bump the parent, then do the
landing step. That checks gotchas 1–5 directly.

## 7. The pilot project

`~/projects/threejs-skeleton-proj`, a type-1 workspace:

| Path | Repo (`origin`) | Branches |
| -- | -- | -- |
| `.` (workspace: `CLAUDE.md`, `README.md`, `NEXT-STEPS.md`, `.gitignore`) | `kantorv/threejs-skeleton-studio` | `development` |
| `threejs-skeleton/` (React + three.js app, `body-pose/` scripts) | `kantorv/threejs-skeleton-editor` | `development`, `main` |
| `threejs-skeleton-server/` (Django + DRF, Postgres, Kafka workers) | `kantorv/threejs-skeleton-server` | `development`, `main` |

Members are git-ignored by the workspace. No `.jst/` yet.

What it exercises, compared with THS:

- The workspace holds only docs.
- Dependencies run both ways (§3).
- The server finds the app at `../threejs-skeleton`, so the nested-sibling worktree layout really matters.
- Interfaces that must stay in sync are already listed in the workspace `CLAUDE.md` and the server's
  `ARCHITECTURE.md` §10: good material for a cross-repo review dimension.

What it doesn't exercise: different base branch names across repos (both use `development`/`main`), or a repo the PAT
can't reach.

Pre-pilot fix: the workspace `CLAUDE.md` says the workspace and the server have no remote, but all three have an
`origin`. The skills read that file, so stale facts there will mislead the model. *(User fixing this, 2026-10-24.)*

## 8. Next steps

1. Run **`jst-install` for real** on the workspace rather than setting up `.jst/` by hand. It will configure the
   workspace as a single repo: an honest baseline, and it shows what the installer would need to detect members.
2. Pick one real cross-repo issue, ideally a contract change such as a `convert.ts` flag. Run assigner → executor →
   reviewer and log every step that breaks or needs a manual nudge.
3. Compare that log with THS-2. The overlap is the generic core; anything only one project hit stays out of the
   plugin for now.

## 9. Open questions

- Model A or Model B for the pilot (§4)?
- Convert the pilot to submodules (§6)? If so, run the by-hand check before `jst-install`.
- Is there a Jira project key for threejs yet, or will `jst-install` create one?

## 10. Session log

- **2026-10-24:** read the proposal and the pilot layout; brainstorm above. User fixing the pilot's `CLAUDE.md`
  remote declarations.
- **2026-10-24:** user proposes starting concrete with submodules and a per-feature `.gitmodules` branch freeze;
  agreed, gotchas recorded in §6.
- **2026-10-24:** user answered the §6 gotchas; experiments on a scratch superproject (git 2.43) settled them. Result
  written up as a full proposal: [submodules-strategy.md](submodules-strategy.md). It supersedes this file's §6 where
  they differ: clone instead of worktree, the branch freeze kept in local config (a `.gitmodules merge=ours` rule
  doesn't work), gitlinks bumped only at landing and only to commits on each member's base.
- **2026-10-24:** user overruled the clone: keep worktrees and remove with `--force`. Tested and agreed. Consequences
  written into the strategy doc: worktree git config is shared, so the branch freeze is a one-shot `git -c`; never
  combine `--remote` with `--recursive` (it moves pinned nested submodules to their branch tip).
- **2026-10-24:** implementation shape agreed: no per-strategy sections in the skills; one flow over a set of repos,
  behind a `repos.sh` front door with `strategies/*.sh` (single goes through it too, guarded by golden-output tests).
  User's amendment: members are detected from `.gitmodules`, with `JST_MEMBERS_EXCLUDE` for vendored libraries.
  Strategy doc §7, §8 and §11 (delivery plan) updated.
- **2026-10-24:** reverted to an explicit `JST_MEMBERS` list. It fails closed: no setting means today's behaviour, so
  an upgrade can't change a project that vendors via submodules, and a new vendored submodule can't silently become a
  member. `.gitmodules` now validates the list instead of defining it (strategy doc §7).
- **2026-10-24:** phase 1 planned in detail: [\_submodules-phase-1-plan.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/docs/proposals/_submodules-phase-1-plan.md). The lab
  confirmed that `ensure_local_env` run inside a member of the main checkout copies the credential file into the member.
- **2026-10-24:** phase 1 done (commits `3eb0221`, `48eb897`). Phase 2 done: the pilot was converted to submodules
  (`threejs-skeleton-studio` `14fe106`), and the by-hand check ran as Jira SKL-2, with a squash-merged member PR and
  landing. Results and two design findings are in the strategy doc's §10.
- **2026-10-24:** phases 4–6 done. The executor and assigner work across members. SKL-4 (reject → fix → land) and SKL-5
  (the first fully automatic chain) are Done. `remove-check` cleared the finished pilot worktrees, jst-install has step
  2e, and the site has a Multi-repo projects page. Deferred: multistep and hotfix across members, the type-1 strategy,
  and a real Windows run.
