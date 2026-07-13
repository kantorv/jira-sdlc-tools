# Plan: shortening `jira-task-reviewer` without degrading review quality

Status: **plan approved for implementation — refactor not yet applied.**
This document is the deliverable of a planning sub-task; the migration
steps in §8 are executed by follow-up issues, not by the change that
commits this file.

## 1. Problem

`jira-task-reviewer/SKILL.md` is ~453 dense lines: a canonical-report
template with two variation axes, a ten-outcome catalogue, per-emission
rules about which outcomes are legal where, and prose reconciling the
per-sub-task audit-trail comments (3e) with the single-final-comment
invariant. Every rule earned its place, but the skill is past the point
where adding prose increases reliability — an over-specified prompt makes
the model drop constraints under context pressure, and *which* constraint
it drops is nondeterministic.

The remedy is the pattern this plugin already proved with
`statuscheck.sh`: **move the deterministic ~80% into
`skills/_shared/scripts/`, keep judgment in prose.** After the refactor
the LLM does only the things that need an LLM: reading the diff, judging
the six dimensions, writing findings, and choosing what to say to the
human. Target size: **≈230 lines, hard ceiling 250** (§6).

## 2. Design principle

A line of SKILL.md prose is *scriptable* if a shell script could execute
it byte-identically every run: command sequences, output parsing,
fallback chains, filtering, format contracts. It must *stay prose* if it
requires reading code, weighing evidence, or wording a finding. The
`statuscheck.sh` conventions carry over to every new script:

- lives in `skills/_shared/scripts/`, callable from any skill;
- resolves its own `<TOKEN>`s from `jira-sdlc-tools.env` /
  `jira-sdlc-tools.local.env` (parsed, not sourced) — no hardcoded
  project values, ever;
- emits markdown an agent reads directly (tables for facts);
- `set -u`, a `timeout` cap on every network call, FAIL rows carry a
  remedy line;
- **reports facts, never judges roles** — the skill decides what the
  facts mean.

One deliberate deviation: `post-verdict.sh` performs writes (it posts
verdicts). It is therefore the only script with a `--dry-run` flag and a
hard validation gate before any side effect (§3.3).

## 3. Scripts to extract

### 3.1 `resolve-base.sh <branch> [key]`

The §12 PR-base resolver, currently pasted as an inline snippet in
**three** places (`jira-acli-reference.md` §12, `jira-task-executor`
step 10, `jira-task-reviewer` step 1). Snippets drift; scripts don't.

- **Input**: the branch whose base is wanted (explicit, because the
  reviewer keys on `<PARENT-BRANCH>`, not `git branch --show-current`).
  `[key]` defaults to the issue key parsed from the branch tail.
- **Resolution chain** (unchanged): `git config
  branch.<branch>.parentbranch` → the issue's `PR target branch: …` Jira
  comment → `DEFAULT_BASE_BRANCH` from env.
- **Bug fix folded in** (review finding 4.5): the Jira-comment fallback
  stops being `grep -oE` across the whole comments JSON (hijackable by
  any later comment quoting the phrase — a run report, a task-memory
  note, a pasted assignment report). The script matches on comment-body
  *start* with `jq` and prefers the **newest** match. This is the one
  behavior change in the whole extraction, and it is strictly a
  correctness fix.
- **Output**: one line to stdout — `<base-branch>\t<source>` with
  `source` ∈ `git-config` | `jira-comment` | `env-default` — so callers
  (skills *and* `pr-set.sh`) can both use the value and flag an
  `env-default` last resort in their reports, as the prose already
  requires. Exit non-zero with a remedy line only if all three tiers are
  empty.
- **Call sites after extraction**: executor step 10 and reviewer step 1
  replace their snippets with one script call; `jira-acli-reference.md`
  §12 stops carrying code and instead documents the script as the
  normative resolver.

### 3.2 `pr-set.sh <key>`

Everything the reviewer currently does between the healthcheck and the
first diff: issue fetch + parent climb, track determination, branch and
base resolution, phase detection, PR discovery, In-Review filtering, and
the 3a prior-verdict lookup. Read-only — **zero writes to git, GitHub,
or Jira** — which is what makes it safe to smoke-test against live data
and idempotent to re-run.

- **Input**: the healthcheck-derived key (`issue_key` row). The script
  climbs to the parent itself when the key is a sub-task's
  (`fields.issuetype` → `fields.parent.key`), absorbing the reviewer's
  step-1 climb.
- **Gathers**, in order: the §3 review-fetch of the issue (and the
  parent re-fetch after a climb); track from `fields.subtasks` (empty →
  single-step, else multistep); `<PARENT-BRANCH>` via the deduped
  `git branch -a` match (zero or multiple matches → FAIL row with a
  remedy, so the skill asks the user instead of guessing);
  `<BASE_BRANCH>` via `resolve-base.sh`; `SELF` via
  `gh api user --jq .login`; the parent-PR phase probe (`gh pr list
  --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all`); and, on the
  multistep track, per-sub-task status, branch, open PR into
  `<PARENT-BRANCH>`, and prior self-verdict.
- **Prior-verdict column** — subsumes 3a. For each PR (each leaf, and
  the parent PR itself for 5b's re-run path): scan
  `gh pr view --json reviews` for bodies authored by `SELF`; report
  `APPROVED` if any body starts `APPROVED — ` (approval is terminal and
  wins over a later rejection), else `CHANGES-REQUESTED` if any starts
  `CHANGES REQUESTED — `, else `none`. Matching by author + byte-exact
  body prefix — never review *state* — is the same-account deployment
  contract, now implemented in exactly one place.
- **Output**: two markdown tables.
  1. Run header — `run_key`, `parent_key` (+ a `climbed` note),
     `track`, `parent_branch`, `base_branch`, `base_source`, `self`,
     `parent_pr` (number/state or `none`), `parent_pr_prior_verdict`,
     `phase`.
  2. Per-leaf (multistep only) — `| key | status | branch | PR | state |
     prior_verdict | note |`, one row per sub-task including
     not-in-review ones (marked skipped) and missing-branch/missing-PR
     ones (flagged), so the step-6 report can enumerate the whole set
     without re-querying.
- **`phase`** ∈ `leaf-review` (no parent PR; in-review leaves exist),
  `no-prs` (nothing reviewable yet), `parent-review` (parent PR open, or
  all leaves merged), `complete` (parent PR merged). On the single-step
  track the "parent PR" is the issue's only PR, so the same four values
  cover both tracks — this replaces the two separate phase-check
  sections in step 1.
- **What it deliberately does not do**: pick an outcome code, decide to
  review, or create the missing parent PR. Facts in the table, judgment
  in the skill.

### 3.3 `post-verdict.sh <pr> <key> <report-file> <approve|reject> [--parent <parent-key>] [--dry-run]`

Dual-destination verdict posting, so the byte-exact prefix contract
lives in exactly one file.

- **Validation gate (before any side effect)**: the first line of
  `<report-file>` must start byte-for-byte with `APPROVED — ` when the
  verdict argument is `approve`, or `CHANGES REQUESTED — ` when it is
  `reject`. Mismatch → exit non-zero, nothing posted. The 3a detection
  contract stops depending on model discipline and becomes enforced
  code.
- **Posts the one body to every destination**:
  `gh pr review <pr> --comment --body-file <report-file>`, then
  `acli jira workitem comment create --key <key> --body-file
  <report-file>`, then — with `--parent` — the same body to the parent
  issue (the 3e audit-trail tally). One body, one file, identical
  everywhere, exactly as the canonical-report section already demands.
- **No status transition.** See §5 — by the time this script exists,
  JST-72 has removed every plugin-side transition; the
  `CHANGES REQUESTED — ` verdict comment *is* the reject signal, and
  status movement belongs to the repo's `jira_issue_transition_*.yml`
  workflows.
- **Partial failure**: if the GitHub post succeeds and a Jira post
  fails, exit non-zero and say exactly which destinations landed, so
  the skill reports accurately instead of blindly re-posting (the
  GitHub comment must not be duplicated — it is what 3a keys on).
- **`--dry-run`**: print the exact commands and the validation result,
  post nothing. This is the routine smoke path (§7).

## 4. Prose that remains (the judgment core)

- **The six review dimensions (3c), verbatim** — correctness, pattern
  consistency, no scope creep (with its triviality judgment), no obvious
  regressions, test coverage, build hygiene — plus the per-AC results
  table. This is the review; not one word of it is scriptable.
- **Diff-reading guidance (3b)** — full diff, `--name-only` + `Read` for
  >1000-line diffs, never skip a file.
- **The canonical review report template** — it is the LLM's writing
  spec. It stays, compressed: the two variation axes shrink to a couple
  of sentences once the outcome catalogue is consolidated (§5), and the
  `### Verdict recorded` section loses its status-moved clause (JST-72).
- **Verdict decision points** — approve vs. reject per dimension; the
  parent-PR review's lighter, integration-focused scope (5b); the
  outcome → next-step wording the human acts on.
- **The never-merge rule** and the reject-path meaning (verdict comment
  as the signal, per JST-72's ownership decision).
- **Discovery/healthcheck reading** — FAIL handling and the
  worktree/branch stop conditions stay prose; they are role judgment by
  design (statuscheck is role-agnostic).
- **Edge cases that need a human or a judgment call** — foreign reviews
  never skip the self-review; forced re-review; multiple open PRs → ask;
  parent behind base → stop and report; `gh` identity failure fallback.
- **Mechanics bullets, compressed** — temp-file + `--body-file` for
  every multi-line body and the model-sign-line rule remain (the report
  heredoc is still written by the model); the posting-command mechanics
  around them move into `post-verdict.sh`.

## 5. The outcome catalogue: JST-72's effect, then consolidation

**JST-72 (total removal of plugin-side status transitions) lands first**
and simplifies the reviewer before this refactor touches it:

- 3d's reject-path `acli jira workitem transition … <STATUS_IN_PROGRESS>`
  command is gone, and with it the "the Jira transition is the actual
  workflow gate" rationale that is currently restated in the preamble
  identity bullet, 3d, and the template. The reject signal is the
  `CHANGES REQUESTED — ` verdict comment; status movement is owned by
  the repo's `jira_issue_transition_*.yml` workflows.
- Every "GitHub-for-Jira automation (if connected)" attribution in the
  outcome texts becomes a reference to those workflows (this also clears
  review finding 4.5's doc drift).
- The template's `### Verdict recorded` Jira line simplifies to "note
  posted" — there is no "whether status moved" to report.
- Reading status is untouched: the `<STATUS_IN_REVIEW>` filter stays
  (inside `pr-set.sh`), which is also why `pr-set.sh` can be strictly
  read-only.

**Consolidation — 10 outcomes → 7.** Three `S-*`/`M-*` pairs differ only
in their title noun and target-branch name; with JST-72 removing the
transition-wording differences, each pair collapses into one outcome
with the PR's role (`single-step PR` / `parent PR`) and target branch
filled from `pr-set.sh`'s header table:

| current (10) | after (7) | rationale |
|---|---|---|
| S-APPROVED + M-PARENT-READY | **APPROVED-AWAITING-MERGE** | both: final PR approved, merge manually, final update, no re-run |
| S-CHANGES-REQUESTED + M-PARENT-CHANGES-REQUESTED | **CHANGES-REQUESTED** | both: fix findings on the reviewed branch, push, re-run |
| S-MERGED + M-FULLY-COMPLETE | **MERGED-COMPLETE** | both: PR already merged, workflows own the Done transition, no re-run |
| M-ALL-APPROVED | **ALL-APPROVED-MERGE-AND-RERUN** | unchanged: merge leaves into parent branch, re-run for the parent PR |
| M-SOME-BLOCKED | **SOME-BLOCKED** | unchanged: fix blocked leaves, re-run |
| M-SUBTASK-APPROVED | **SUBTASK-APPROVED** | per-PR emission only; "re-run required" wording is genuinely different |
| M-SUBTASK-CHANGES-REQUESTED | **SUBTASK-CHANGES-REQUESTED** | per-PR emission only |

The per-PR vs. run-level split survives (the `SUBTASK-*` pair exists
precisely because a sub-task PR's next step differs from a final PR's),
but the "chosen by track × phase" selection prose collapses into a
five-line mapping keyed to `pr-set.sh`'s `phase` value plus the run's
verdicts — outcome choice becomes near-mechanical, which is the point:
fewer codes and a table lookup leave less for the model to drop.

## 6. Expected size after the refactor

| section | now (≈lines) | after (≈lines) | why it shrinks |
|---|---|---|---|
| frontmatter + preamble bullets | 22 | 14 | posting/identity mechanics move into scripts |
| Discovery & healthcheck | 61 | 30 | keep FAIL handling + stop conditions; drop rows now restated by `pr-set.sh` |
| steps 1–2 (resolve, track, phase, PR discovery) | 57 | 25 | one `pr-set.sh` call + how to judge its table |
| canonical review report | 83 | 45 | template stays; axes + reconciliation prose compress (§5) |
| step 3 review loop (3a–3e) | 86 | 40 | 3a → prior-verdict column; 3d/3e mechanics → `post-verdict.sh`; 3b/3c stay whole |
| steps 4–5 (post-loop, parent PR) | 61 | 30 | phase logic → `pr-set.sh`; 5a PR creation + 5b judgment stay |
| step 6 + outcome catalogue | 65 | 35 | 10 → 7 outcomes; selection becomes a mapping table |
| edge cases + reference footer | 11 | 11 | unchanged |
| **total** | **~453** | **~230** | target ≈ half; hard ceiling 250 |

If a migration step cannot meet its section budget without cutting a
judgment rule, the budget yields — the ceiling is a review gate for the
refactor PRs, not a license to delete review criteria.

## 7. Test approach

There is no test suite in this repo; each script gets a documented smoke
procedure (in its header comment, statuscheck-style), and every skill
change gets the repo's standard scenario-trace validation.

- **`resolve-base.sh`** — deterministic, read-only. Three cases, all
  runnable in a live checkout: (1) a branch with `parentbranch` config →
  expect `git-config` source; (2) config unset (use a scratch branch or
  `git config --unset` on a disposable clone) with an issue that has a
  `PR target branch: …` comment → expect `jira-comment` and the *newest*
  body-start match, including the negative case of a later comment that
  merely quotes the phrase (the finding-4.5 hijack) being ignored;
  (3) neither → expect `env-default`, and non-zero exit when
  `DEFAULT_BASE_BRANCH` is also unset.
- **`pr-set.sh`** — read-only, so it can run against live data at will.
  Run it against a real multistep parent with open in-review sub-task
  PRs and against a single-step issue, in each reachable phase, and
  cross-check every table cell against the manual `acli`/`gh` command it
  replaced (the commands currently in SKILL.md steps 1–2/3a are the
  expected-value oracle). Re-run twice to confirm idempotence.
- **`post-verdict.sh`** — the only writer. Routine check is `--dry-run`
  (validates the report file, prints the exact commands, posts nothing).
  Negative test: a report file whose first line doesn't match the
  verdict argument → non-zero exit, nothing posted. One live end-to-end
  test posts an `approve` verdict to a sandbox or already-closed PR plus
  a scratch Jira issue, then verifies the GitHub body is detected by the
  prior-verdict logic in `pr-set.sh` (round-tripping the 3a contract
  through both scripts).
- **Skill-level validation** — after each migration step, trace the
  reviewer end-to-end for the scenarios that step touched (single-step
  approve/reject/merged; multistep leaf phase, mixed verdicts, parent
  phase, fully-complete; the re-run/idempotency paths), per the repo's
  "the files are the behavior" doctrine, plus
  `claude plugin validate .`.
- **Follow-up, out of scope here**: a `bats` harness for
  `_shared/scripts/` (seasonal review priority #10) once three-plus
  scripts share conventions worth pinning.

## 8. Migration order

Each step is a separate PR; the skill stays fully functional after every
one. Steps 1–2 are independent of JST-72; step 3 onward assumes it.

0. **Precondition**: JST-72 (transition removal) is merged into the
   shared parent branch before step 3 begins — `post-verdict.sh` must be
   born transition-free, not have a transition removed later. (Steps 1–2
   may land before or in parallel with JST-72; they don't touch
   transitions.)
1. **Extract `resolve-base.sh`** and swap the three call sites
   (executor step 10, reviewer step 1, reference §12 → normative doc
   pointing at the script). Includes the finding-4.5 `jq` fix. Smoke
   test §7 cases.
2. **Extract `pr-set.sh`**; rewrite reviewer steps 1–2 and 3a to one
   script call plus table-reading prose. No other skill changes. Smoke
   test read-only against live issues in both tracks.
3. **Extract `post-verdict.sh`**; rewrite 3d/3e/5b posting to script
   calls (3e becomes the `--parent` flag). Dry-run + negative +
   sandbox round-trip tests.
4. **Consolidate the outcome catalogue** (10 → 7 per §5) and compress
   the canonical-report axes prose. Wording-only PR — no mechanics
   change — traced against every outcome scenario, old → new mapping in
   the PR body.
5. **Final pass**: verify the ≤250 ceiling, update README / AGENTS.md
   cross-references (the reviewer's step names and the §12 pointer), and
   re-trace both tracks end to end.

## 9. Why review quality is preserved at each step

- **Step 1 (`resolve-base.sh`)**: the resolution chain is unchanged and
  was never a judgment call; three drifting copies become one tested
  implementation. The only behavior delta is the finding-4.5 fix, which
  removes a silent *mis*-resolution path — strictly safer. Review inputs
  (the diff, the criteria) are untouched.
- **Step 2 (`pr-set.sh`)**: fact-gathering was never review judgment —
  it was six-plus command invocations the model could mis-execute or
  partially skip under context pressure. A single authoritative table
  *raises* quality: the attention budget freed from mechanics goes to
  the diff, and the 3a idempotency contract (author + byte-exact prefix)
  is implemented once instead of re-derived per run. The
  `<STATUS_IN_REVIEW>` filter and phase semantics are the same rules,
  relocated.
- **Step 3 (`post-verdict.sh`)**: the report body — the actual review
  content — is still authored entirely by the model; the script only
  delivers it. The byte-exact verdict-prefix contract moves from "the
  model must never reword it" to a validation gate that refuses to post
  a malformed verdict, making the *next* run's idempotency check more
  reliable, not less. Dual-destination identity (GitHub body == Jira
  body) becomes guaranteed instead of requested.
- **Step 4 (catalogue consolidation)**: each merged pair had identical
  semantics and next-step meaning, differing only in a noun and a branch
  name — now parameters filled from the `pr-set.sh` table. Nothing the
  human needs to know disappears: the same next-step instructions are
  emitted, chosen from 7 codes instead of 10, with a mechanical
  selection table. Fewer near-duplicate codes is precisely the
  reliability failure mode (nondeterministic constraint-dropping) this
  plan exists to remove. The `SUBTASK-*` pair, whose wording is
  genuinely different, is deliberately *not* merged.
- **Step 5 (final pass)**: pure verification; the ceiling check exists
  so shrinkage never silently costs a judgment rule (§6's yield clause).
- **Throughout**: the six dimensions, the AC table, the findings format
  (`file:line` per failed dimension), the never-merge rule, and the
  canonical report template — the parts of the skill that *are* the
  review — are never moved, thinned, or reworded except where JST-72
  changed ownership facts.

## 10. Explicitly out of scope

- Flagging `mergeable == false` PRs in the report (seasonal review 4.5)
  — a good `pr-set.sh` column *later*, but it is new behavior; this plan
  is zero-behavior-change apart from the finding-4.5 resolver fix.
- The `bats` harness (review priority #10) — follow-up once the scripts
  exist.
- Shortening the executor/assigner — they benefit from
  `resolve-base.sh` incidentally; their own dense sections are separate
  work.
- Worktree/branch cleanup tooling (JST-75) and the statusboard (JST-73)
  — siblings, tracked separately.
