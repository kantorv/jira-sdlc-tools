# Submodules support, phase 3: the reviewer (implementation plan)

|  |  |
| -- | -- |
| Status | Plan, not started. Decisions D1–D7 settled (§8). Unpublished (`_` prefix) |
| Written | 2026-10-24, on `feature/JST-322-submodules-support-pilot-implementation` (after phases 1 and 2) |
| Implements | Phase 3 of [the submodules strategy](submodules-strategy.md) §11 |

## 1. Goal and exit criteria

The reviewer handles a **single-step issue whose work spans member repos**, end to end: it reviews every member PR,
lands the result in the workspace, reviews the landing PR, and offers Done only once the whole set has landed. For a
single-repo project, nothing it does changes. When phase 3 is done:

1. The reviewer finds an issue's PRs in every repo of the set, not just the workspace. Today it reads `current_pr`,
   which queries the workspace only, so on the pilot it reports "no PR" with two open member PRs (the multi-repo
   proposal's THS-2 failure).
2. Every per-PR command (`gh pr view`, `gh pr diff`, `gh pr review`) names its repo.
3. A seventh review dimension, *consistency across the set*, checks the contracts between repos.
4. Once every member PR is merged, the reviewer runs landing and reviews the landing PR with the gitlink gate.
5. The reviewer `SKILL.md` gets **shorter**, not longer: the PR-reading and phase-check prose moves into scripts.
6. Single-repo runs behave as today, checked by script golden tests and by headless reviewer runs (§6).

Out of scope: **multistep issues across member repos** (sub-tasks × members, D2), the executor and assigner (phases 4
and 5), and `remove-check`.

## 2. The idea that keeps the skill small: leaf PRs, then one aggregate PR

The reviewer already knows one two-level shape: on the multistep track, sub-task PRs (the leaves) merge into the parent
branch, then one parent PR (the aggregate) merges into the base. A single-step issue across member repos has **the same
shape**, along a different axis:

| Shape | Leaf PRs | Aggregate PR |
| -- | -- | -- |
| Single repo, single-step | the one PR | — |
| Single repo, multistep | sub-task PRs → `<PARENT-BRANCH>` | parent PR → `<BASE_BRANCH>` |
| **Submodules, single-step** | **one PR per member → that member's base** | **the landing PR in the workspace → its base** |
| Submodules, multistep | sub-task PRs per member, then parent PRs per member | the landing PR (deferred, D2) |

So the skill needs no "submodules section". Its steps stay "review the leaves, then the aggregate". What differs is
*where the leaves are* and *how the aggregate comes to exist*: the executor opens it on the multistep track, landing
creates it here. A script answers both.

## 3. New verbs (both ports, `repos.sh` + `strategies/`)

### `prs --branch <b> [--state all|open]`

Every PR whose head is `<b>`, in every repo of the set. Tab-separated, with a header:

```text
repo                     slug                             pr  state   base         url
threejs-skeleton         kantorv/threejs-skeleton-editor  7   OPEN    development  https://…/pull/7
threejs-skeleton-server  kantorv/threejs-skeleton-server  -   none    -            -
.                        kantorv/threejs-skeleton-studio  -   none    -            -
```

- The reviewer's *Reading PRs* rule moves in here (JST-310): `--head` is the bare branch name, `--state all` unless
  told otherwise, no `--base`, and **an empty answer is confirmed by a second query** before it prints `none`.
- A `gh` failure prints `error` in `state` for that repo and exits 4: unknown, never none.
- `single` prints one row, `.`. It replaces the skill's hand-typed `gh pr list` lookups for other branches (step 2's
  sub-task PRs, 5a's merged URLs).

### `gate --branch <b> --base <root-base>`

The phase of the issue branch's PR set, decided from GitHub alone. Jira's sub-task statuses stay with the skill. It
prints `key=value` lines, then the `prs` rows:

```text
phase=review
reason=2 member PRs open
root=none
members=open
```

| `phase` | When | Reviewer does |
| -- | -- | -- |
| `none` | No PR in any repo | Report "no PR yet" and exit |
| `review` | At least one leaf PR is OPEN. Single: the root PR. Submodules: a member PR | Review the OPEN rows (step 3) |
| `land` | Submodules: every member with commits on `<b>` has a MERGED PR, and there's no root PR | Run `land` (D1), then review the PR it opens |
| `review-landing` | Submodules: the root PR is OPEN and every member PR is MERGED | Review it, with `land --check` as a gate |
| `merged` | The root PR is MERGED (single: the issue's PR; submodules: the landing PR) | S-MERGED / R-COMPLETE |
| `stop` | Anything else, with `reason=` (below) | Relay `reason`, ask |

`stop` reasons:

- a CLOSED unmerged PR;
- an OPEN PR off its repo's expected base;
- several OPEN PRs in one repo;
- a member whose `<b>` has commits ahead of its base but no PR (*pushed, no PR*);
- a `prs` error (unknown);
- a root PR that's OPEN while member PRs are still open;
- a multistep issue across members (D2).

Member scope comes from GitHub, per MS-SC-1: a member takes part when `<b>` exists on its origin. "Commits ahead" is
`gh api repos/<slug>/compare/<base>...<b>`. Both are one call per member.

For `single`, `gate` reduces to today's single-step phase check: `none`, `review` (root OPEN), `merged`, `stop`
(CLOSED, off-base, several OPEN). The multistep track keeps its Jira split, reading `root=` where it read
`current_pr`.

### `land [--check] --branch <b>`

- **`land`** (MS-LA-2), run from the issue worktree:

  1. For each member PR in the set, take its merge commit (`gh pr view --json mergeCommit`) and check it's an
     ancestor of `origin/<member base>`.
  2. Move the gitlink there and commit `<KEY>: land <members>` on `<b>`.
  3. Push, with `push.recurseSubmodules=check` in force.
  4. Open the landing PR into the root's base. Its body lists the PR set, as the parent PR body does in 5a.
  5. Print the PR row.

  It stops, and changes nothing, if any check fails. On `single` it prints "nothing to land" and exits 0.

- **`land --check`** (MS-LA-3): every gitlink the landing PR changes points at a commit reachable from that member's
  base. It prints one row per member and exits non-zero on any failure. This is the reviewer's gate on the landing PR,
  alongside a light review of the diff.

This moves `land` from phase 6 into phase 3, because the reviewer is its first caller (D1). Phase 6 keeps `remove-check`
and jst-install.

## 4. The reviewer `SKILL.md`: what changes

Word count today: **6,348** of an accepted 6,500. The target after phase 3 is **≤ 6,100**, with the allowance ratcheted
down in `check-skill-size.sh` (AGENTS.md: "if the file shrinks, the script tells you to ratchet").

| Where | Change | Words (est.) |
| -- | -- | -- |
| Discovery table | The `current_pr` row's line → `repo_strategy` (the strategy and members). The phase checks no longer read `current_pr` | ±0 |
| *Reading PRs* (≈370 words) | Replaced by two sentences: "PRs come from `repos.sh gate` (this branch) and `repos.sh prs` (any other); never hand-type `gh pr list` — why is in the script header" | −320 |
| Single-step phase check (≈110) | Becomes the `gate` table in §3, keyed on `phase` | +40 |
| Multistep phase check (≈280) | Reads `root=` instead of `current_pr`; its Jira split stays. `gate` stops on multistep × submodules | −40 |
| Step 2, the sub-task PR lookup | `repos.sh prs --branch <subtask-branch> --state open` | −60 |
| Step 3, every `gh pr` command | One rule: "every `gh pr` call takes `-R <slug>` from the PR's row" (single too, D4) | +40 |
| 3c | Dimension 7, *Consistency across the set*: contracts changed on one side are matched on the other, using the interfaces the project's docs list; every PR targets its expected base; state the merge order. Skipped when the set has one PR | +80 |
| New 4d / 5L | `phase=land` → run `repos.sh land`, then 5b on the PR it prints, with `land --check` first. `phase=review-landing` → straight to that | +110 |
| 5a | Its find-or-create logic reads `gate`/`prs` instead of `current_pr` | −80 |
| Step 7 | On submodules, offer Done only when the landing PR is approved (R-LANDING-READY), never on member approvals alone | +30 |
| **Net** |  | **≈ −200** |

The estimate is cautious. If it misses, the next cut is 5a's PR body (it moves into `land` and a shared PR-body
template), not new prose.

### The report template (`_shared/templates/review-report.md`)

The template isn't word-capped (it's loaded once per run). It gets a **"Submodules, single-step"** outcome group (D3):

| Outcome | When | Next step (gist) |
| -- | -- | -- |
| R-MEMBER-APPROVED / R-MEMBER-CHANGES-REQUESTED | Per member PR (3d) | Approved: it merges into its member's base; re-run after all merge. Rejected: fix, push, re-run |
| R-MEMBERS-APPROVED | Every member PR approved, some still open | Merge them **in the stated order**, then re-run, which lands |
| M-SOME-BLOCKED | Reused as is: its wording is already repo-neutral | — |
| R-LANDING-READY | The landing PR approved | Merge it; Done means this merge |
| R-LANDING-CHANGES-REQUESTED | `land --check` failed, or the review did | The finding (usually a gitlink off its base), re-run |
| R-COMPLETE | The landing PR merged | No re-run needed |

`### Pull Request Summary` lines gain the repo: `- <KEY> <slug>#<n>: …`, which is also correct for single repos.

## 5. Docs

- [The submodules strategy](submodules-strategy.md): Q2 answered (the reviewer runs landing), Q4 confirmed (the
  landing PR opens at landing time), §11 delivery plan updated.
- `docs/`: a *Merge → Done automation* note for submodules projects. Scope the rule to the parent repo, or member
  merges close the issue early (MR-JIRA-1). Whether the pilot has GitHub for Jira on its member repos decides how
  urgent this is (D6).

## 6. Tests

**Script golden tests** (`check-repos.sh`, both ports): the fake `gh` grows `pr list`, `pr view --json mergeCommit`,
`compare` and `branches/<b>`.

- `prs`:
  - every state;
  - the confirm-on-empty second query (the fake answers `[]` once, then the PR);
  - `error` → exit 4.
- `gate`: every `phase` and every `stop` reason, in both strategies.
- `land`:
  - on local bare remotes, with a member PR "squash-merged" by the lab: the gitlink lands on the merged commit, the
    parent push passes the guard, and the fake receives the landing PR;
  - every refusal path changes nothing (the commit isn't on base; a member PR still open);
  - `land --check` on a good and a bad gitlink.

**Headless reviewer runs** (`claude -p "/jira-sdlc:jira-task-reviewer" --plugin-dir <working copy>`, run from the
issue worktree). These are the real end-to-end check AGENTS.md's "trace the scenario" can only approximate.

| # | Project | Scenario | Expect |
| -- | -- | -- | -- |
| H1 | chess-app (D7) | single-step, one open PR | Today's behaviour: S-APPROVED or S-CHANGES-REQUESTED |
| H2 | chess-app | multistep, two sub-task PRs | Today's: M-ALL-APPROVED, then M-PARENT-READY after merges |
| H3 | pilot | single-step across both members: an API field added in the server and consumed in the app (a real contract change) | Two member verdicts, dimension 7 checks the contract, R-MEMBERS-APPROVED with "server first" |
| H4 | pilot | H3, after both member PRs merge (one squash, one merge commit) | `phase=land` → landing PR opened → `land --check` passes → R-LANDING-READY; Done offered only now |
| H5 | pilot | H3 with the app side missing the field | Dimension 7 fails the app PR, R-MEMBER-CHANGES-REQUESTED, issue back to In Progress |
| H6 | pilot | A member branch pushed with commits but no PR | `phase=stop`, "pushed, no PR", named |

H3–H6 need member PRs that the executor can't open yet (phase 4). They're made by hand, like SKL-2.

## 7. Slicing

1. **Scripts:** `prs`, `gate`, `land` with tests. No skill change, so it can land on its own.
2. **The reviewer + template + docs**, with the headless runs H1–H6.

## 8. Decisions (settled with the user, 2026-10-24)

- **D1, the reviewer runs landing** (answers the strategy's Q2). It already creates the aggregate PR on the multistep
  track (5a), and landing is the same kind of mechanical step. `land` moves from phase 6 into phase 3.
- **D2, multistep issues across member repos are deferred.** `gate` stops with "not supported yet". That shape needs
  per-member parent PRs plus landing, a third level. Better built once single-step is proven.
- **D3, dedicated `R-*` outcomes** in the template, rather than rewording the `M-*` ones around abstract
  "leaf/aggregate" tokens. They're clearer for the model, at about 300 template words.
- **D4, `-R <slug>` on every `gh pr` call, in single mode too.** One rule, no strategy branch in the prose.
- **D5, merge order is the reviewer's judgement per issue**, stated in R-MEMBERS-APPROVED, from the dimension-7
  review. There's no order setting, because the pilot's dependencies run both ways (strategy doc §3).
- **D6, GitHub for Jira on the pilot's member repos: not installed.** Member merges can't move the issue early on the
  pilot, so the §5 docs note is for other projects and isn't urgent.
- **D7, the single-repo project for H1–H2: `~/projects/chess-app/chessapp-analyze-v1`** (`pgntools/chess-trainer-app`,
  Jira `CTA`). It's a real, active project, not a throwaway: a reviewer run posts verdicts on PRs and moves Jira
  issues. So H1/H2 run only against a test issue and PR made for the purpose, or one the user picks, and the user is
  asked before each run.

## 9. Progress

- **Slice 1, commit `5de94ad`:** `prs`, `gate`, `land` in both ports. 140 checks in `check-repos.sh`. Against the
  pilot's real SKL-2 history, `gate` reads `merged` in both ports.

- **Slice 2, the reviewer:** `gate`/`prs`, `-R <slug>` everywhere, dimension 7, step 5L, and the `R-*` outcomes.

  - 6,348 → 6,199 words; the allowance went from 6,500 to 6,250.
  - The size estimate (§4) missed. The first draft came out *longer*, at 6,507, so it took a deliberate compression
    pass: every rule and its reason kept, restatements cut.

- **H1 (chess-app CTA-265, PR #271), three runs:**

  1. S-APPROVED, the right result, but **`gate` never ran**. The model took PR #271 from statuscheck's `current_pr`
     row, which statuscheck still prints, and went straight to step 3. On a project with members that misses every
     member PR, the THS-2 failure itself.
  2. After a sentence saying "Run `gate` (*Reading PRs* above)": the same skip. A cross-reference doesn't beat a PR
     number already sitting in the statuscheck output.
  3. After putting the `gate` command block **inside each phase check**, with "never on `current_pr`, which can't see
     member repos": `gate` runs, and 3a's idempotency path is correct (already approved, no new commits, no second
     comment).

  Lesson: a command the model must run goes at the point of use, not one section up.

- **H3, pilot SKL-3 (a `--source-license` flag across both members):**

  - `gate` → `review`, then both member PRs reviewed with `-R`.
  - Dimension 7 checked the contract: the reviewer ran `convert.ts` on a real poses file and ran the cross-repo sync
    test.
  - R-MEMBERS-APPROVED with "app first, then server", no Done offer, and exactly one Jira report.
  - It also caught a stale line in the server's `ARCHITECTURE.md`.

- **H4, SKL-3 after the member merges** (app squash-merged, server with a merge commit):

  - `gate` → `land`, then `land` → the landing PR `threejs-skeleton-studio#2`.
  - `land --check` passed both rows → R-LANDING-READY, and Done is offered only now.
  - After the landing PR merged, a fresh `git clone --recurse-submodules` has both members at their merged commits.

- **H6, pilot SKL-4, the app branch pushed with no PR:** `gate` → `stop` "pushed, no PR". The reviewer named the
  repo and commit, reviewed and posted nothing, and offered next steps.

- **H5, SKL-4 with the incomplete app PR:**

  - The app PR was rejected under dimension 7: `convert.ts` lacks the flag the server passes, proven by the sync test.
  - The server PR was rejected for a real bug in the test fixture: its new test was spliced into the middle of an
    existing one.
  - SKL-4 went back to In Progress, with one Jira report.
  - SKL-4 stays open as the executor's fix-and-re-run case for phase 4.

- **Observed, worth a rule:** to run the server's DB tests, the H5 reviewer loaded the main checkout's
  `skelserver/.env.local` into its shell (not printed). A reviewer sourcing project secrets is a choice the skills
  should make explicitly, probably "don't, say what wasn't run".

- **Not run yet:** H2 (chess-app, multistep). It needs a parent, two sub-tasks and three PRs on a real project.
