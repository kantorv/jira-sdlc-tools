# Submodules support, phase 5: the assigner (implementation plan)

|  |  |
| -- | -- |
| Status | **Done** (§5). Unpublished (`_` prefix) |
| Written | 2026-10-24, on `feature/JST-322-submodules-support-pilot-implementation` (after phase 4) |
| Implements | Phase 5 of [the submodules strategy](submodules-strategy.md) §11 |

## 1. Goal and exit criteria

The assigner turns a task that spans member repos into a ready-to-work issue. It investigates the members' code too,
decides which members are in scope, creates the issue branch in the workspace and in each in-scope member (eagerly,
MS-SC-1), and leaves the worktree with those members already on the branch. A single repo behaves as today. Done when:

1. On the pilot, **one task description goes assigner → executor → reviewer → landing with no hand steps** apart from
   the merges, which stay the human's (A1).
2. A chess-app assigner run is unchanged (A0).

## 2. Decisions (taken; veto any)

- **A-D1, `provision --add` does the member side.** It already cuts a member's issue branch from `origin/<base>`,
  pushes it, sets `parentbranch` inside the worktree's member, and switches the member to it. The assigner runs it
  once in the new worktree. The only script change: `--add` takes several paths (space- or comma-separated).
- **A-D2, members are supported for single-step planned work only.** Multistep across members is deferred (phase 3,
  D2). A hotfix needs each member's *production* branch as the PR base, which `repos.sh` doesn't model yet (strategy
  doc Q1). So an issue whose in-scope members aren't empty stops on the multistep or hotfix path, with a clear message.
  An issue that touches only the workspace is unaffected.
- **A-D3, scope is the assigner's judgement, recorded on GitHub, not in a comment.** A member is in scope when its
  issue branch exists on its origin (MS-SC-1). The assignment report names the in-scope repos for people; nothing
  parses it. "Repos are not pieces": a front-end-plus-server change that must land in order stays one issue (MR-ASG-1).
- **A-D4, the main checkout's members are never moved.** Everything member-side happens in the new worktree, so the
  main checkout stays on its base for the next assigner run.

## 3. Changes

- `repos.sh provision --add <paths>`: a list. Every listed path must be a member; the first one that isn't stops the
  run before anything is created. Both ports, plus tests.
- Assigner `SKILL.md`:
  - **Step 1:** `repo_strategy` and `member_repo[…]` are what make members usable; a FAIL on either already blocks.
  - **Step 3:** investigate members' code too; the project's docs say which interfaces cross repos.
  - **Step 5A:** decide the in-scope members; A-D2's stop.
  - **Step 6A:** after the worktree, `repos.sh provision --add "<in-scope members>"` in it.
  - **Step 7:** the report lists each repo's branch, and the merge order if it's already clear.
  - **Step 8:** the executor hand-off is unchanged.

## 4. Tests

- **Scripts:** a multi-path `--add`, an invalid path in the list, and idempotence when the branches already exist.
- **A0, chess-app:** a real small task (the §14 setext-heading bug E1 found): one issue, a branch, a worktree, the
  report. Unchanged from today.
- **A1, pilot:** a real cross-repo task description. The assigner creates SKL-N with both members in scope. Then the
  executor implements and opens the two member PRs, the reviewer approves (with the order), the human merges, the
  reviewer lands, the human merges the landing PR, and the issue is Done. All headless, on Sonnet.

## 5. Progress

- **Commit `6e2819f`:** `provision --add` takes a list (198 checks, both ports), plus the assigner's step 1 row, step 3
  members, 5D scope, 6A.5 and the report.
- **A1, pilot SKL-5, the first fully automatic chain** (Sonnet, medium effort). The task description named no repos or
  files.
  - **Assigner:** found that both members are in scope, the right files on each side, and "app first". It ran
    `provision --add`. Bug found: after `cd`-ing into the worktree for `provision`, its next `jira.sh` call ran there,
    with no credentials. Fixed with a subshell (`615ac91`).
  - **Executor:** started from the assigner's worktree and implemented both sides, using a custom date field because
    the source is stored as JSON. It opened two member PRs, each with the order stated and the PR-set section, gave
    the workspace no PR, and moved the issue to In Review.
  - **Reviewer:** approved both with "app first". Wording found: it asked "move to Done anyway?" on
    R-MEMBERS-APPROVED. Step 7 now says not to ask at all, which put the reviewer over its allowance, so it went to
    6,400 (`819a1a4`).
  - **Human:** merged the members (app squash, server merge commit).
  - **Reviewer:** `land` → `threejs-skeleton-studio#4` → `land --check` ok → R-LANDING-READY.
  - **Human:** merged the landing PR, then Done.
  - **Executor behaviour to decide (open):** to run tests, it copied the server's git-ignored `.env.local` into the
    worktree and started the pilot's Docker stack (left running). The reviewer has a no-secrets rule and the executor
    doesn't. Turning a worktree into a runnable instance is meant to be the project's `.jst/bootstrap.sh` job, and the
    pilot has none.
- **A0, chess-app CTA-270 (the real §14 setext bug):** single repo, unchanged. One issue, a branch from `development`,
  a worktree, both comments, no `repos.sh` calls.
- **CTA-270's executor run** produced the real one-line fix as PR `pgntools/chess-trainer-app#276`, left open for the
  owner. It also shows the pattern for the open executor question: chess-app's own `.jst/bootstrap.sh` copied
  `.env.local` into the worktree. The project, not the skill, decides how a worktree gets its environment.
