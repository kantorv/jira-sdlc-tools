# Submodules support, phase 4: the executor (implementation plan)

|  |  |
| -- | -- |
| Status | **Done** (§6). Unpublished (`_` prefix) |
| Written | 2026-10-24, on `feature/JST-322-submodules-support-pilot-implementation` (after phase 3) |
| Implements | Phase 4 of [the submodules strategy](submodules-strategy.md) §11 |

## 1. Goal and exit criteria

The executor implements a single-step issue across member repos: it brings each member onto the issue branch,
commits and pushes in each repo it changes, and opens or updates one PR per member. It moves the issue to In Review
once every repo with commits has a PR. Single-repo runs behave as today. When phase 4 is done:

1. Step 1 provisions the members (MS-SC-2) before the project hook runs, so the hook can rely on them.
2. Each member's issue branch is brought current with its base. A conflict stops the run, naming the repo.
3. Commits and pushes happen per repo, members before the root, with the push-order guard on.
4. Step 10 opens or updates a PR per member. Every PR in the set carries a "PR set" section, kept in sync.
5. The first test is **SKL-4's fix-and-re-run**: both member PRs were rejected in phase 3's H5, and the executor fixes
   them, after which the reviewer approves and lands. A chess-app run (E1) shows single repos are unchanged.

Out of scope: multistep across members (still deferred), the assigner's side of `provision` (phase 5), and
`remove-check` (phase 6).

## 2. Decisions (taken; veto any)

- **E-D1, the root never gets an executor PR in submodules mode.** Its own commits, if any (workspace docs), ride the
  landing PR, which `land` opens on the same branch. This keeps the set's shape as "member PRs, then one landing PR"
  (phase 3's leaf/aggregate shape) and answers MR-CFG-2 without a setting.
- **E-D2, step 2's root merge stays prose; `sync` handles the members only.** The root merge carries the `.jst/`
  untracked-overwrite recovery, which is judgement and already tested. A single repo then runs exactly today's step 2.
- **E-D3, push and PR creation go through the scripts in both strategies (MS-AR-1).** `push` in single mode is today's
  `git push -u origin <branch>`. `open-prs` in single mode is today's `gh pr create`, plus `-R`.
- **E-D4, the PR body is the model's; the PR-set section is the script's.** The model writes one body file. `open-prs`
  appends a marked `<!-- jst:pr-set -->` section listing every PR in the set, and refreshes that section in every open
  PR of the set when the set changes. The merge order is the executor's call, stated in the body.
- **E-D5, `parentbranch` inside worktree members.** `provision` sets `branch.<b>.parentbranch` in each worktree
  member's own git directory, to the member's base (phase 2 finding: the main checkout's config doesn't reach it).

## 3. New verbs (both ports)

| Verb | Does | single |
| -- | -- | -- |
| `provision [--add <path>]` | MS-SC-2: `submodule update --init --recursive`; for each member whose issue branch is on its origin, the one-shot `-c submodule.<n>.branch` update, `switch`, a nested init, and `parentbranch` = the member's base; then `push.recurseSubmodules=check`. `--add <path>` is scope growth: it creates the issue branch in that member from `origin/<base>`, pushes it, then provisions it. Idempotent | `provisioned=` (nothing to do) |
| `sync` | Each participating member: fetch, then merge `origin/<base>` into its issue branch. Stops at the first conflict, printing `conflict` with the repo and files, and leaves the merge for the user | `synced=` (nothing to do) |
| `push` | Every repo whose issue branch has commits ahead of its upstream (or has none): members first, the root last, with `push.recurseSubmodules=check` | `git push -u origin <b>` |
| `open-prs --title <t> --body-file <f> [--base <b>]` | One PR per repo that needs one: single → the root; submodules → each member with commits ahead of its base. Existing OPEN PR → `exists`; none → `gh pr create -R` → `created`. Then refresh the PR-set section in every open PR of the set. One row per PR | the root, `--base` from `pr_base` |

## 4. The executor `SKILL.md`

| Step | Change |
| -- | -- |
| Discovery | `current_pr` row → `repo_strategy`; step 10 reads PRs through `repos.sh` |
| 1a | `repos.sh provision` first, then the hook, with `JST_MEMBERS` (space-separated, empty for single) added to the hook contract |
| 2 | After the root's merge: `repos.sh sync` |
| 6 | Scope: a member's files are edited in its folder; a member that isn't on the issue branch is pinned, so run `provision --add <path>` before touching it |
| 7 | Test in each repo you changed, using that repo's own documented commands |
| 8 | Commit per repo (`git -C <path>`). Never stage a member's gitlink in the root: moving it is landing's job |
| 9 | `repos.sh push` |
| 10 | `repos.sh prs` replaces `current_pr` for the existing-PR check; fix summaries go to each OPEN PR with `-R`; `open-prs` creates the rest. The `pr_base` resolution and its sanity checks stay as they are, for the root |
| 11 | In Review once `open-prs` shows a PR for every repo with commits |
| 12 | The report lists each repo's PR and the merge order |

## 5. Tests

- **Scripts:** `check-repos.sh` section 5, with the same fake `gh` and local remotes as section 4:
  - `provision` from scratch, twice (idempotent), and with `--add`
  - `sync`, clean and with a conflict
  - `push`: order, and the guard
  - `open-prs`: created, exists, the PR-set section, and its refresh
  - both strategies and both ports
- **Headless runs** (`--model claude-sonnet-5-5 --effort medium`):
  - **E1, chess-app, single repo:** a small test issue; the executor opens one PR, the same as today. Closed after.
  - **E2, pilot SKL-4, fix-and-re-run:** the executor reads both rejections, fixes `convert.ts` and the spliced test,
    comments a fix summary on both PRs, then In Review. Then the reviewer re-runs: approval, merge, land, Done.

## 6. Progress

- **Slice 1, commit `27d5b1d`:** `provision`, `sync`, `push`, `open-prs` in both ports. `check-repos.sh` is at 186
  checks, and the PowerShell port passed first time.
- **Slice 2, the executor:**
  - It reads the repo set through `repos.sh`: `provision` before the hook (with `JST_MEMBERS` added to the hook
    contract), `sync` after the root's merge, commits per member (never a member's gitlink in the root), then `push`,
    then `prs` and `open-prs`.
  - A sub-task with member repos stops, because multistep across members is deferred.
  - 4,122 → 4,453 words, within budget.
- **E2, pilot SKL-4, the fix-and-re-run** (Sonnet, `--effort medium`):
  - The executor ran `provision`, the root merge plus `sync`, fixed both findings (the app's `--source-language` flag
    and the spliced server test), committed per member, then `push`, then `prs`.
  - It posted fix summaries on both PRs with `-R`, then In Review, in 16 turns.
  - Gap found: it skipped `open-prs`, because both PRs were open, so their PR-set sections never got written. Step 10
    now says to run `open-prs` every time. Run once by hand, it reported `exists` for both PRs and wrote the section.
  - Then the reviewer re-reviewed both (their last verdicts were CHANGES REQUESTED), approved them with "app first",
    and kept the new no-secrets rule (it listed the tests it couldn't run instead of sourcing `.env.local`).
  - Both member PRs were squash-merged, and the reviewer landed them (`threejs-skeleton-studio#3`, `land --check` ok,
    R-LANDING-READY).
  - Merged, SKL-4 Done: the whole reject → fix → approve → land loop works.
- **E1, chess-app CTA-269, single repo:**
  - `provision`/`sync` did nothing, the bootstrap hook ran with an empty `JST_MEMBERS`, and `pr_base` resolved the
    base.
  - `open-prs` opened PR #275 into `development` with no PR-set section, then In Review, in 9 turns.
  - The fixture is closed; the bug it fixed (a blank line before §14's rule) is real and still open.
