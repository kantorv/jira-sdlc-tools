---
name: jira-task-reviewer
description: Run from the parent issue's worktree — no issue-key argument; the issue is derived from the branch, climbing from a sub-task branch to its parent automatically. Finds all sub-tasks in "In Review" status that have an open PR into the parent branch, reviews each PR (approve or request changes), posts findings to Jira, and continues past any rejections to report the full state. After a reject-and-fix cycle, re-run to resume. Once all sub-task PRs are merged (by a human), the skill reviews the parent PR into the base branch. Also handles single-step top-level issues (no sub-tasks) by reviewing their PR directly into the base branch. Never merges anything.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are acting as the code reviewer for the **`<PROJECT-KEY>`** project. Run this from the parent issue's own worktree — no issue-key argument; the issue is derived from the current branch (see Discovery below). $ARGUMENTS, if given, is free-form notes about this run, not a key:

> **You are reviewing `<ISSUE-KEY>` — the issue for *this* worktree's branch — and nothing else.** When you have finished it, stop and report. Never continue on to another issue: not a sibling sub-task, not the parent PR. If `<ISSUE-KEY>` is a sub-task, a full pass over every sub-task plus the parent PR is a *separate* run of this skill from the parent's own worktree.

**Conventions used below:**
- `<PARENT-KEY>` = the Jira issue key derived from the current branch (via the Discovery healthcheck's `issue_key` row below) — or, when the branch belongs to a sub-task, that sub-task's `fields.parent.key` (step 1 climbs automatically and notes it in the report). It just means "the resolved key" — it is only literally the parent of sub-tasks on the multistep track; on the single-step track it is a standalone issue with no sub-tasks.
- `$ARGUMENTS`, when non-empty, is free-form notes about this run (focus areas, constraints, context) — fold them into the review criteria (3c); never parsed as an issue key.
- `<PARENT-BRANCH>` = the git branch for `<PARENT-KEY>`, always named `feature/<PARENT-KEY>-<slug>` or `hotfix/<PARENT-KEY>-<slug>`.
- `<BASE_BRANCH>` = whatever `<PARENT-BRANCH>` itself should merge into — resolve with §12's mechanics (`../_shared/jira-acli-reference.md`: git-config → Jira "PR target branch" comment → `<DEFAULT_BASE_BRANCH>` env default) but keyed on `<PARENT-BRANCH>`/`<PARENT-KEY>`, **not** `git branch --show-current`: from a sub-task's own worktree the current branch is the sub-task's, whose `parentbranch` is `<PARENT-BRANCH>` (not the base). Step 1 gives the exact resolution.
- Sub-task PRs all target `<PARENT-BRANCH>` — every sub-task gets its own dedicated branch and PR.
- **Single-step top-level issues** (no sub-tasks) have a PR targeting `<BASE_BRANCH>` directly.
- Reviewer only processes sub-tasks whose Jira status is `<STATUS_IN_REVIEW>`. Those not yet in review (e.g. still `<STATUS_IN_PROGRESS>`) are silently ignored — the executor will transition them when ready.
- Auth follows `../_shared/jira-acli-reference.md` §0 — `acli` stores credentials after a one-time `acli jira auth login`, so no per-command `JIRA_API_TOKEN` prefix; run commands bare.
- **Your GitHub identity** = `gh api user --jq .login` — resolve it once and reuse it for the whole run (hold it in a shell variable, e.g. `SELF=$(gh api user --jq .login)`). The executor opens PRs with the *same* `gh` account in this plugin's default deployment, and GitHub blocks an author from approving *or* requesting changes on their own PR, so both verdicts are recorded as **review comments** carrying the decision in their body prefix (`APPROVED — …` / `CHANGES REQUESTED — …`; see 3d/5b); the Jira transition to `<STATUS_IN_PROGRESS>` is the actual workflow gate, the comment only records findings. The idempotency check (3a) and the verdict-comment detection both key on this identity.
- **Jira-comment mechanics**: reports and updates are multi-line — write them to a temp file and post with `acli jira workitem comment create --key <KEY> --body-file <file>` (see `../_shared/jira-acli-reference.md` §6). Single-line comments can use the `--body "<text>"` form. *Never wrap markdown in a quoted inline `--body` string* — backticks are interpreted as shell command substitutions, and `--body-file -` / stdin does not work.
- **GitHub-body mechanics**: the same backtick hazard applies to `gh pr review` / `gh pr create` bodies. Write every GitHub-side body to a temp file and pass `--body-file` (never inline `--body "…"`). The `APPROVED — …` / `CHANGES REQUESTED — …` body prefix is what makes a prior verdict machine-detectable later (see 3a) — keep it verbatim, byte-for-byte.

**Script dispatch — settle this before running any script below.** Every
script this skill invokes ships twice: the POSIX `…/scripts/X.sh` and its
Windows twin `…/scripts/win/X.ps1` (PowerShell 5.1+; identical args, output,
exit codes). Read your OS from your own runtime *before the first call* —
you know it without running anything — and dispatch **every** script that
way, the leading credential block included: `bash …/scripts/X.sh` on
Linux/macOS, `pwsh`/`powershell …/scripts/win/X.ps1` on Windows. The blocks
below are the POSIX form; on Windows substitute the `.ps1` port each time.
Statuscheck's `platform` row then *confirms* that OS (and, on Windows, that
the runtime + ports are present) — it verifies the dispatch you already
chose, and can't be what you consult to dispatch statuscheck itself.

**Make sure local credentials exist, then log in as the reviewer — run
both FIRST, before the healthcheck.** Every Jira write this skill makes
(verdict comments, reject-path transitions) should come from the
reviewer's account, not from whoever was last logged in. Both calls are
safe to run every time (`ensure_local_env` no-ops when the file already
exists; `jira_acli_login` always logs out then back in as the role, so a
stale token can't survive), so run them unconditionally. On non-zero from
either, relay its stderr and **stop**.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/ensure_local_env.sh" || exit 1
bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/jira_acli_login.sh" reviewer || exit 1
```

**Discovery and healthcheck — run before step 1.** This skill reads Jira
status, calls `gh pr list` / `gh pr review`, and — on the reject path —
transitions issues; finding a busted environment mid-review wastes a
pass and can leave an inconsistent verdict trail. Run the shared
healthcheck first, overriding its rerun hint to name this skill instead
of the executor default:

```bash
STATUSCHECK_RERUN="rerun /jira-sdlc:jira-task-reviewer" \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/statuscheck.sh"
```

(If `CLAUDE_PLUGIN_ROOT` isn't set, the script lives at
`../_shared/scripts/statuscheck.sh` relative to this skill's directory.)

It prints one markdown table (`check | status | detail`), where status is
`OK`, `FAIL` (blocks, with a remedy line printed under the table), `WARN`
(suspicious, not blocking), or `INFO` (context only), and exits non-zero
if any row is `FAIL`. `gh_auth` and `acli_auth` are load-bearing here
(every verdict comment, `gh pr list` call, and Jira transition depends on
them). The `worktree` and `branch` rows are context INFO — the shared
script reports them for every role and never FAILs on them.

Only the rows this skill reads in a role-specific way, or relies on later,
are spelled out here; the rest are role-independent preconditions defined
in `statuscheck.sh` itself (their `detail` column is self-explanatory in
the printed output — that live output, not this table, is what the skill
actually acts on).

| row | what it verifies / gathers |
|---|---|
| `worktree` | INFO: *linked worktree* (`.git` is a file) vs. *main checkout* (`.git` is a directory). **This skill requires a linked worktree** — the parent's, or a sub-task's own; the reading note below makes that a stop condition |
| `branch` | INFO: base branch vs. `feature/*`/`hotfix/*` issue branch (§7) vs. neither. **This skill requires a feature/hotfix issue branch** — the parent's or a sub-task's; the reading note below makes that a stop condition |
| `issue_key` | the key derived from the branch name — seeds step 1, which resolves it to `<PARENT-KEY>` (climbing from a sub-task to its parent if needed; the branch is the sole source of truth) |
| `parent_branch` | INFO: `git config branch.<branch>.parentbranch` for the *current* branch — equals `<BASE_BRANCH>` only from the parent worktree; from a sub-task worktree it's `<PARENT-BRANCH>`, so step 1 keys the base lookup off `<PARENT-BRANCH>` instead |

The remaining rows FAIL if broken but need no per-role interpretation
here: `git_repo`, `env_config`, `env_local` (auto-copied into a worktree
from the main checkout when missing by `ensure_local_env.sh`, called
before this script — see the login step above),
`env_local_ignored`, `branch_project` (wrong-project guard), `gh_auth` and
`acli_auth` (both load-bearing, as noted above), `jira_project`, plus
context `base_branch`, `working_tree` (WARN when dirty), and
`worktrees_dir` (WARN when missing — only the assigner acts on it).

This skill normally runs from the **parent worktree**
(`worktree-<PARENT-KEY>`, per `jira-task-assigner`), but a sub-task's own
worktree is an equally valid feature/hotfix branch — the `branch` row only
distinguishes feature/hotfix vs. anything else (base branch, detached
HEAD, non-conforming name), not parent vs. sub-task; step 1 below handles
the sub-task case by climbing to the parent rather than treating it as a
failure.

Reading the result: **any FAIL row** → stop, relay the script's remedy
line to the user, and wait — don't self-repair. The `worktree` and
`branch` rows never FAIL, so judge them yourself: the `worktree` row must
report a **linked worktree** and the `branch` row a **feature/hotfix issue
branch** (the parent's or a sub-task's). If not — the main checkout, the
base branch, a detached HEAD, or a non-conforming name — stop, because
this skill runs from an issue's worktree. Otherwise the `issue_key` row's
derived key seeds step 1 below (which resolves it to `<PARENT-KEY>`,
climbing from a sub-task to its parent if needed).

## 1. Resolve the parent, sub-tasks, and pick a track

- `git fetch origin --prune` first. Branches created or merged by parallel sub-task executors (possibly from different worktrees) may not be visible locally yet.
- Fetch the issue derived from the branch (the healthcheck's `issue_key` row — call it `<RUN-KEY>`): `acli jira workitem view <RUN-KEY> --json --fields 'summary,description,issuetype,status,parent,subtasks'` (source of truth for this review-fetch field list: `../_shared/jira-acli-reference.md` §3 — resolve there rather than here if the two ever disagree). It omits `comment`, which this skill never reads (fetching it would bloat the parent + every sub-task fetch on comment-heavy issues). Check `fields.issuetype.name`:
  - **Top-level** (`Task`, `Story`, `Bug`) → `<PARENT-KEY>` = `<RUN-KEY>`.
  - **`Subtask`** (this worktree is a sub-task's own, not the parent's) → per the rule at the top, review **this sub-task's own PR only**. Do *not* re-fetch the parent as an acting issue and do *not* read its `fields.subtasks` — that sweep belongs to a run from the parent's worktree. `<PARENT-BRANCH>` (this PR's base) = §12's resolver with `PARENT_KEY` = `fields.parent.key`; then skip to step 3 with that one PR, and skip steps 2, 4a/4b, and 5 entirely. Note in the final report (step 6) that only `<RUN-KEY>` was reviewed.
- **Resolve `<PARENT-BRANCH>`**: list branch names deduped to unique shorts — strip the local `*`/indent and the `remotes/origin/` prefix so a branch that exists both locally and on origin counts once — then match the key:
  ```bash
  git branch -a | sed -E 's#^[* ]+##; s#^remotes/origin/##' | sort -u | grep <PARENT-KEY>
  ```
  Exactly one match → that's `<PARENT-BRANCH>`. Zero or multiple → ask the user rather than guessing.
- **Resolve `<BASE_BRANCH>`** — the base `<PARENT-BRANCH>` merges into. Use §12's resolver (`../_shared/jira-acli-reference.md`) but keyed on `<PARENT-BRANCH>`/`<PARENT-KEY>`, **not** `git branch --show-current` (they coincide only in the parent worktree; from a sub-task's own worktree the current branch is the sub-task's, whose `parentbranch` is `<PARENT-BRANCH>` — using it would set `<BASE_BRANCH>` = `<PARENT-BRANCH>` and make step 5a open a parent PR into itself). Branch config lives in the shared `.git/config`, so keying off `<PARENT-BRANCH>` works from any worktree:
  ```bash
  BASE_BRANCH=$(git config branch."<PARENT-BRANCH>".parentbranch 2>/dev/null)
  [ -z "$BASE_BRANCH" ] && BASE_BRANCH=$(acli jira workitem comment list --key <PARENT-KEY> --json \
    | grep -oE 'PR target branch: [^" ]+' | head -1 \
    | sed -e 's/PR target branch: //' -e 's/\.$//')
  [ -z "$BASE_BRANCH" ] && BASE_BRANCH="<DEFAULT_BASE_BRANCH>"   # last resort — flag it in the report
  ```
  Only ask the user if all three come up empty.

  **Why this copy has no parent-branch search, unlike §12's resolver.** That
  recovery step exists for a *sub-task*, whose base is its parent's branch and
  never `<DEFAULT_BASE_BRANCH>`. Here the key is always `<PARENT-KEY>` — step 1
  already climbed from any sub-task to its parent — and a parent is by
  definition top-level, with no grandparent branch to search for. So the
  `<DEFAULT_BASE_BRANCH>` fallback is the *correct* last resort on this path,
  exactly as it is for a top-level issue in §12. Don't copy the search here.
- **Determine the track** from `fields.subtasks` (absent, `null`, or empty `[]` → **single-step**; anything else → **multistep**). This sets the run's **PR set** and the steps you will walk. Name the track explicitly so the rest of the skill reads as one track at a time:
  - **Single-step track** — the PR set is *just the one parent PR* (`<PARENT-BRANCH>` → `<BASE_BRANCH>`). Walk: *Single-step phase check* → review loop (step 3, with the parent PR as the sole PR) → 4c → 6. (If the phase check detects an already-merged PR on a later re-run, jump straight to the step-6 report with the S-MERGED outcome — GitHub-for-Jira auto-transitions the issue to `<STATUS_DONE>` on merge, so no re-run is required and no further action is expected on the issue.)
  - **Multistep track** — the PR set is *each in-review sub-task PR*. Extract sub-task keys from `fields.subtasks` (the review-fetch field list above names `subtasks` explicitly, per §3 — the default `--json` omits it; the shape is an array of objects, i.e. `fields.subtasks[].key`, not bare strings). For each sub-task key run `acli jira workitem view <SUBTASK-KEY> --json --fields 'summary,description,issuetype,status,parent,subtasks'` (same §3 review-fetch list) and keep only those whose `fields.status.name` matches `<STATUS_IN_REVIEW>` (e.g. "In Review") — others are not reviewed yet, skip quietly. Walk: *Multistep phase check* → step 2 → review loop (step 3) → 4a/4b → 5 → 6.

### Single-step phase check (only for the single-step track)

For a single-step issue (no sub-tasks), check if a PR already exists targeting `<BASE_BRANCH>`:

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all --json number,state,url
```

- **No PR exists yet** → The executor hasn't opened one. Report: "Single-step issue `<PARENT-KEY>` has no open PR yet. The reviewer will run once the PR is created." Exit.
- **PR exists and is OPEN** → Proceed to step 3 to review this PR (skip step 2; jump to the review loop).
- **PR exists and is MERGED** → The human already merged it. GitHub-for-Jira has transitioned the issue to `<STATUS_DONE>` — jump to the step-6 report with the S-MERGED outcome and exit. No wrap-up comment, and no further action is expected on the issue.

### Multistep phase check (only for the multistep track)

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all --json number,state,url
```

- **No parent PR exists yet** → Sub-tasks aren't all merged. Continue to step 2 for a full review pass.
- **A parent PR exists and is OPEN** → Sub-tasks are already merged; skip straight to step 5 to review the parent PR.
- **A parent PR exists and is MERGED** → The user merged the aggregate PR manually. GitHub-for-Jira has transitioned all related issues to `<STATUS_DONE>` — jump to the step-6 report with the M-FULLY-COMPLETE outcome and exit. No wrap-up comment, and no further action is expected.

## 2. Discover open PRs for each In Review sub-task (multistep only)

*(Multistep track only — the single-step track's PR set is just the parent PR, set up in step 1, so it skips straight to the review loop.)*

For each `<SUBTASK-KEY>` that passed the status filter:

- Find its branch: `git branch -a | sed -E 's#^[* ]+##; s#^remotes/origin/##' | sort -u | grep <SUBTASK-KEY>` (dedupes the local + `remotes/origin/` pair so a branch present in both counts once). If no branch exists yet, that sub-task hasn't been implemented — flag it in the report and skip it.
- Find the open PR: `gh pr list --head <subtask-branch> --base <PARENT-BRANCH> --json number,title,state,url`. If no PR exists, flag and skip. If more than one open PR, ask the user which one to review.
- Record: `{ key, branch, prNumber, prUrl }`.

If **zero** sub-tasks have open PRs, report and exit.

## The canonical review report

Every report-shaped output this skill emits is **one and the same
report**, defined here once and *referenced* — never re-spelled — by the
steps that emit it:

- the GitHub PR verdict comments (3d approve/reject, 5b parent),
- the Jira per-issue comment (3d),
- the parent per-sub-task tally (3e), and
- the end-of-run chat + parent report (6).

A person following the same review across GitHub, Jira, and chat therefore
sees one layout at one level of detail. An individual emission only varies
along two axes; the section structure never changes:

- **PR set in scope** — a *per-PR* emission (3d, 5b, 3e) fills the report
  for the single PR just reviewed; the *end-of-run* emission (6) fills it
  for every PR in the run's PR set (step 1).
- **Which outcome block is filled** — exactly one outcome from step 6's
  catalogue (S-APPROVED, S-CHANGES-REQUESTED, S-MERGED, M-SUBTASK-APPROVED,
  M-SUBTASK-CHANGES-REQUESTED, M-ALL-APPROVED, M-SOME-BLOCKED, M-PARENT-READY,
  M-PARENT-CHANGES-REQUESTED, M-FULLY-COMPLETE), chosen by track × phase —
  and, for a *per-PR* emission, by *which* PR: the single-step parent PR
  uses the `S-*` outcomes, a multistep sub-task PR uses the `M-SUBTASK-*`
  outcomes, and the multistep parent PR uses M-PARENT-READY (5b approve) or
  M-PARENT-CHANGES-REQUESTED (5b reject). It supplies the
  `<OUTCOME_TITLE>` and the `### Next step` wording; everything else is the
  same for all outcomes.

**Template — fill every section:**

```text
<VERDICT-HEADER>

## Review Status: <OUTCOME_TITLE>
Parent: <PARENT-KEY> (<PARENT-BRANCH> → <BASE_BRANCH>)

### Pull Request Summary
- <KEY> PR #<n>: [✅ approved | ❌ changes requested | ⏳ skipped] <PR URL>
- ...   (one line per PR in scope — a single PR for 3d/5b/3e, every PR in the set for 6)

### What I reviewed
- Track: <single-step | multistep>
- <KEY> PR #<n> — the six 3c dimensions, each ✅/❌ with a one-line note:
  Correctness · Pattern consistency · No scope creep · No obvious
  regressions · Test coverage · Build hygiene.
- Per-AC results, when the issue defines acceptance criteria:
  | # | Acceptance criterion | Result |
  |---|---|---|
  | 1 | <criterion> | ✅ / ❌ <note> |
- On the reject path, the `file:line` findings for each failed dimension
  (this is the detail the CHANGES REQUESTED verdict is made of — never drop it).

### Verdict recorded
- GitHub: <APPROVED / CHANGES REQUESTED comment on PR #<n>, or "—" if none posted this emission>
- Jira: <note posted on <KEY>; whether status moved to <STATUS_IN_PROGRESS>>

### Next step
<the outcome block's guidance from step 6: manual-merge / fix-and-re-run / no re-run needed>
```

**`<VERDICT-HEADER>` — the load-bearing first line.** It is always the
literal first line of the body and starts with `APPROVED — ` or
`CHANGES REQUESTED — ` followed by a one-line summary:

- On a **GitHub verdict comment** (3d, 5b) this prefix is a byte-for-byte
  contract — 3a's idempotency detection matches on it. Keep it verbatim;
  never reword the two-word prefix or the ` — ` separator.
- On the **Jira per-issue comment** (3d), the **parent tally** (3e), and
  the **end-of-run report** (6), the same line leads the body so every
  destination opens identically. On a per-PR emission it is that PR's
  verdict; on the end-of-run report it is the run's overall verdict
  (`CHANGES REQUESTED — …` whenever any PR in the set was rejected — e.g.
  M-SOME-BLOCKED — otherwise `APPROVED — …`, including the already-merged
  S-MERGED / M-FULLY-COMPLETE outcomes).

The idempotency-detection contract (3a) and workflow gates (the reject
transition to `<STATUS_IN_PROGRESS>`, the "never merge" rule) are unchanged
by this unification — the template only fixes the *shape* of what those
steps already emit; it does not add, remove, or reorder any of their
side-effects.

## 3. Sequential per-PR review loop

Iterate through **the PR set** (defined in step 1 — the one parent PR on the single-step track, each in-review sub-task PR on the multistep track) in ascending key order. Treat each PR individually — do not hold results for a batch. The loop body below is the same for every PR in the set regardless of track.

Resolve this skill's GitHub identity **once here, before the loop** — `SELF=$(gh api user --jq .login)` — and reuse it for every iteration (3a keys on it). If `gh api user` errors, gh isn't installed or authenticated: see the edge case in step 7.

### 3a. Check idempotency — already reviewed by me?

Before reviewing a PR, check whether **this skill's GitHub identity** (`SELF`, resolved once before the loop above) has already left a verdict comment on it:

```bash
gh pr view <prNumber> --json reviews --jq \
  '.reviews[] | select(.author.login == "'"$SELF"'") | .body'
```

Inspect the prior self-review bodies this returns. An `APPROVED —` body wins over a `CHANGES REQUESTED —` one — approval is terminal (the reviewer doesn't keep re-reviewing something it already approved; request a forced re-review via the step-7 flag if you genuinely need a fresh pass):

- **A prior self-review whose body starts `APPROVED —`** → already approved. Report the PR as "already approved — waiting for manual merge" and move to the next PR without re-reviewing.
- **A prior self-review whose body starts `CHANGES REQUESTED —` (and none starts `APPROVED —`)** → re-review: this is a fix-and-re-run scenario, and fresh code may have been pushed since. Continue to 3b.
- **No prior review body from this identity** → continue to 3b.

Matching by author **and body prefix** — not by review `state` — is what makes the check correct in this plugin's same-account deployment: both verdicts land as comments (3d/5b), so there is no `APPROVED`/`CHANGES_REQUESTED` review *state* from this identity to key on; the leading header is the contract the detection relies on.

### 3b. Fetch the diff

```
gh pr diff <prNumber>
```

Read the full diff. If it's very large (>1000 lines), list changed files via `gh pr diff <prNumber> --name-only` and `Read` relevant files for context. Do not skip any file in the diff.

### 3c. Review criteria

Evaluate the diff against these dimensions (all must pass for approve):

1. **Correctness** — Does the code fulfill the Jira description without bugs?
2. **Pattern consistency** — Matches codebase naming, structure, and idioms?
3. **No scope creep** — The change only addresses what the PR's issue describes. Unrelated refactors, formatting changes, or "while I'm here" additions belong in a separate issue. Flag these but don't block on trivial cases (e.g. a typo fix in an adjacent comment is fine; a refactor of an unrelated module is not).
4. **No obvious regressions** — Won't break imports, types, or dependencies.
5. **Test coverage** — Has corresponding test coverage if changes are non-trivial.
6. **Build hygiene** — No debug leftovers (`console.log`, TODO markers not in original codebase style), no accidentally-committed files (`.env`, large binaries, etc.).

### 3d. Execute verdict immediately

Record the verdict as a **review comment** — both verdicts go through `gh pr review <prNumber> --comment --body-file`: in this plugin's default deployment the executor and reviewer share one `gh` account, and GitHub blocks an author from approving *or* requesting changes on their own PR — the self-review restriction covers both verdicts, not just approval. So neither verdict can use a state-based review. The Jira transition to `<STATUS_IN_PROGRESS>` (on the reject path) is the actual workflow gate; the GitHub comment only records the verdict and makes it detectable by 3a. The leading `APPROVED — …` / `CHANGES REQUESTED — …` header is that detection contract — keep it verbatim.

Both the GitHub verdict comment and the Jira per-issue comment carry the **full canonical review report** (see *The canonical review report* above), scoped to this one PR — not a terse one-liner. Write **one** report body to a temp file and post that same file to both destinations, so GitHub and Jira read identically:

* **If APPROVE (all dimensions pass):** fill the canonical template with the per-PR approve outcome **for this track** — **S-APPROVED** when this is the single-step parent PR, **M-SUBTASK-APPROVED** when this is a multistep sub-task PR (a sub-task PR merges into `<PARENT-BRANCH>`, not `<BASE_BRANCH>`, and a reviewer re-run *is* required afterwards to pick up the parent PR, so its title and `### Next step` differ from the single-step "final update" wording). Set `### Verdict recorded` → GitHub: APPROVED comment on PR #<n>, Jira: note posted, status not moved; verdict-header line `APPROVED — <one-line summary>`:
  ```bash
  cat > /tmp/<KEY>-report.md <<'EOF'
  APPROVED — <one-line summary>

  ## Review Status: ...        # the full canonical report, scoped to this PR
  EOF
  gh pr review <prNumber> --comment --body-file /tmp/<KEY>-report.md
  acli jira workitem comment create --key <SUBTASK-KEY-or-PARENT-KEY> --body-file /tmp/<KEY>-report.md
  ```
  (`<SUBTASK-KEY>` for a sub-task PR, `<PARENT-KEY>` for the single-step parent PR.) Do NOT move the Jira status — let the GitHub-for-Jira automation handle it when the PR is merged.

* **If REQUEST_CHANGES (one or more dimensions fail):** fill the same canonical template with the per-PR reject outcome **for this track** — **S-CHANGES-REQUESTED** when this is the single-step parent PR, **M-SUBTASK-CHANGES-REQUESTED** when this is a multistep sub-task PR — and verdict-header line `CHANGES REQUESTED — <one-line summary>`; the `file:line` findings for each failed dimension go in the report's `### What I reviewed` section (never dropped). Post the one body to both destinations, then transition the issue back to `<STATUS_IN_PROGRESS>` — that is the actual gate:
  ```bash
  cat > /tmp/<KEY>-report.md <<'EOF'
  CHANGES REQUESTED — <one-line summary>

  ## Review Status: ...        # the full canonical report, incl. file:line findings
  EOF
  gh pr review <prNumber> --comment --body-file /tmp/<KEY>-report.md
  acli jira workitem comment create --key <SUBTASK-KEY-or-PARENT-KEY> --body-file /tmp/<KEY>-report.md
  acli jira workitem transition --key <SUBTASK-KEY-or-PARENT-KEY> --status "<STATUS_IN_PROGRESS>" --yes
  ```
  Remember this PR as blocked. Continue the loop — review the next PR.

### 3e. Post a summary on the parent after each sub-task

*(Multistep track only — the single-step track has no sub-tasks to tally: the 3d verdict comment already landed on the one issue, and step 6 carries the report.)*

Regardless of whether the review above was approved or rejected, immediately post the **canonical review report** (see *The canonical review report* above), scoped to the sub-task just reviewed, to the parent Jira issue `<PARENT-KEY>` so the progress is visible. It renders the same template as every other emission — same verdict-header line, same sections — filled for this one sub-task's PR (the M-SUBTASK-APPROVED / M-SUBTASK-CHANGES-REQUESTED outcome, per the 3d verdict — 3e is multistep-only, so it is always a sub-task PR). You have already written this exact body to `/tmp/<KEY>-report.md` in 3d; reuse it here rather than composing a second shape.

A **fresh comment per sub-task is intentional** — it's an audit trail: each sub-task's verdict stands on its own permanent comment. This is reconciled with the single-final-comment invariant exactly as step 6 is — the step-6 report is the one *run-level* canonical render, and these 3e comments are its per-sub-task audit-trail companions, not replacements for it. So do **not** use `-e/--edit-last`; post a new comment each time:

```
acli jira workitem comment create --key <PARENT-KEY> --body-file /tmp/<KEY>-report.md
```

## 4. After the PR set has been reviewed (loop complete)

Once step 3 has processed every PR in the set, the reviewer ends the session with a report **even if some were rejected**. The human fixes and re-runs; on a later run, any sub-tasks whose Jira status is no longer `<STATUS_IN_REVIEW>` will be skipped, and only resumed-yet-still-in-review items are picked up.

The post-loop outcome is mutually exclusive and **track-dependent** — pick the one matching the track and the run's state; step 6 posts the written report keyed to the same label.

### 4a. *(Multistep)* All approved — merge and re-run

1. Check if **all** of those PRs are already merged (`gh pr view <prNumber> --json state` for each).
2. **If some are still open** → outcome **M-ALL-APPROVED**: tell the user "All sub-task PRs approved. Merge them manually into `<PARENT-BRANCH>`, then re-run `/jira-sdlc:jira-task-reviewer` (bare, from the parent's worktree) to pick up the parent PR." (Step 6 posts the written report to Jira.)
3. **If all are merged** → proceed to step 5 (parent PR handling).

### 4b. *(Multistep)* Some rejected — report and stop

1. **Do not** proceed to the parent PR, regardless of how many other sub-tasks were approved.
2. Outcome **M-SOME-BLOCKED**: tell the human to fix the rejected sub-tasks, wait for the executor to move them back to `<STATUS_IN_REVIEW>`, then re-run `/jira-sdlc:jira-task-reviewer` (bare, from the parent's worktree). (Step 6 lists **both** approved and rejected items + the file:line findings in the Jira report.)
3. End the session.

### 4c. *(Single-step)* PR reviewed — wait for merge

For a single-step issue (no sub-tasks), after the PR is reviewed in step 3:

- **If approved** → outcome **S-APPROVED**: tell the user "Single-step issue `<PARENT-KEY>` PR #<prNumber> approved. Merge manually into `<BASE_BRANCH>` — GitHub-for-Jira will auto-transition the issue to `<STATUS_DONE>` on merge. No re-run needed; this run's step-6 report is the final update."
- **If changes requested** → outcome **S-CHANGES-REQUESTED**: report the findings to the user; the human fixes, pushes, and re-runs `/jira-sdlc:jira-task-reviewer` (bare, from the parent's worktree).

## 5. Parent PR management (multistep only — runs when all sub-task PRs are merged)

*(Multistep track only — runs when all sub-task PRs are merged into `<PARENT-BRANCH>`, either merged by the user in a prior run or already merged before this one. The single-step track never reaches step 5; its one PR is reviewed directly in step 3, and after merge GitHub-for-Jira handles the `<STATUS_DONE>` transition — there is no post-merge step.)*

### 5a. Find or create the parent PR

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --json number,title,state,url
```

- **No PR exists** → create one (write the body to a temp file — see the GitHub-body mechanics in the preamble):
  ```bash
  cat > /tmp/<PARENT-KEY>-pr-body.md <<'EOF'
  Aggregate PR for <PARENT-KEY>.

  Sub-tasks merged:
  - <SUBTASK-KEY>: <PR URL>
  - ...
  EOF
  gh pr create --base <BASE_BRANCH> --head <PARENT-BRANCH> \
    --title "<PARENT-KEY>: <summary>" \
    --body-file /tmp/<PARENT-KEY>-pr-body.md
  ```
- **PR exists (state OPEN)** → use it.
- **PR exists and is MERGED** → the user already merged the aggregate PR; GitHub-for-Jira has transitioned all related issues to `<STATUS_DONE>`. Report the merged state via the step-6 report with the M-FULLY-COMPLETE outcome and exit — no wrap-up, no further action.
- **PR exists and is CLOSED** → stop and let the user decide (same rule as before).

### 5b. Review the parent PR (apply the 3a idempotency check first)

Ensure `SELF` is resolved first — on the all-sub-tasks-merged re-run path the step-1 phase check jumps straight here and skips step 3, where `SELF` is normally set; if it's unset, resolve it now (`SELF=$(gh api user --jq .login)`; if `gh api user` errors, see step 7). Then apply the **3a body-prefix idempotency check** before reviewing: a prior self-review whose body starts `APPROVED —` → report "Parent PR already reviewed — waiting for manual merge" and skip; one starting `CHANGES REQUESTED —` → re-review the fresh aggregate code. Otherwise:

1. Review the aggregate diff: same criteria as 3c, but lighter. The sub-tasks were already reviewed individually — focus on integration issues, conflicts, and anything that only surfaces when the pieces combine.
2. **If approved** → outcome **M-PARENT-READY**: post the **full canonical review report** (see *The canonical review report* above), scoped to the parent PR, with verdict-header line `APPROVED — <lighter aggregate summary>` as the literal first line — `gh pr review <prNumber> --comment --body-file /tmp/<PARENT-KEY>-report.md` (the same body/mechanics as 3d, just the aggregate PR). Do NOT merge. Tell the user the parent PR is approved and awaiting their manual merge; step 6 posts the run-level report.
3. **If changes requested** → outcome **M-PARENT-CHANGES-REQUESTED**: post the same canonical report with verdict-header line `CHANGES REQUESTED — <one-line summary>`, the integration `file:line` findings in its `### What I reviewed` section, via `gh pr review <prNumber> --comment --body-file`. Report the findings and stop.

*Do not merge here.* Report that the parent PR is reviewed/approved and waiting for the user to merge it manually.

## 6. Report back

Post the review summary to the user in chat **and** as a single Jira comment on `<PARENT-KEY>` via the §6 `--body-file` convention. This is the **run-level** render of *The canonical review report* (defined above) — same verdict-header line and same sections as every per-PR emission, but with the *whole run's* PR set in its `### Pull Request Summary` and its verdict-header reflecting the run's overall verdict (`CHANGES REQUESTED — …` if any PR was rejected, else `APPROVED — …`). Do **not** re-spell the report shape here — fill the template.

Pick **exactly one** outcome from the catalogue below — chosen by the step-1 track × the current phase (decided in step 4 or detected in step 1/5/6). The outcome supplies only the `<OUTCOME_TITLE>` and the `### Next step` wording; the rest of the report is identical across outcomes. Do not emit more than one outcome. The **per-sub-task-PR outcomes** (M-SUBTASK-APPROVED / M-SUBTASK-CHANGES-REQUESTED) are for the 3d/3e per-PR emissions only — this run-level step-6 report never selects them; on the multistep track it uses the `M-*` outcomes.

#### Single-step track

- **S-APPROVED** — single-step PR approved, awaiting manual merge (final update — no re-run needed). Title: `Single-step PR approved — merge manually`. Next step:
  ```
  Single-step PR #<n>: ✅ reviewed and approved. Merging is manual — merge it yourself on GitHub when ready: <PR URL>.
  GitHub-for-Jira will auto-transition the issue to <STATUS_DONE> on merge. No re-run needed — this is the final update.
  ```
- **S-CHANGES-REQUESTED** — single-step PR rejected. Title: `Single-step PR changes requested — see findings`. (The `file:line` findings live in the report's `### What I reviewed` section.) Next step:
  ```
  Fix the findings above, push, then re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree).
  ```
- **S-MERGED** — single-step PR already merged (detected by the step-1 phase check). Title: `Single-step PR merged — complete`. Next step:
  ```
  Single-step PR #<n>: ✅ merged into <BASE_BRANCH> (Jira auto-transitioned by GitHub-for-Jira). No re-run needed.
  ```

#### Multistep track

- **M-ALL-APPROVED** — all sub-task PRs approved, some still open. Title: `All sub-task PRs approved — merge manually and re-run`. Next step:
  ```
  All sub-task PRs approved. Merge them manually into <PARENT-BRANCH>, then re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree) to pick up the parent PR.
  ```
- **M-SOME-BLOCKED** — some approved, some rejected. Title: `Some PRs approved, some blocked — see below`. The approved-vs-blocked split is already visible in `### Pull Request Summary` (✅ vs. ❌ per PR, with URLs) and the per-PR `file:line` findings in `### What I reviewed` — no separate breakdown section. Next step:
  ```
  Fix the findings above in each blocked branch, push, then re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree).
  ```
- **M-PARENT-READY** — all sub-tasks merged, parent PR reviewed/approved, awaiting manual merge into base. Title: `All sub-tasks merged — parent PR ready`. Next step:
  ```
  Parent PR #<n>: ✅ reviewed and approved. Merging is manual — merge it yourself on GitHub when ready: <PR URL>.
  GitHub-for-Jira will auto-transition all related issues to <STATUS_DONE> on merge. No re-run is needed after merge — this report is the final update, and no further action or skill call is expected on the issue.
  ```
- **M-PARENT-CHANGES-REQUESTED** — all sub-tasks merged, parent PR rejected on the 5b integration review. Title: `Parent PR changes requested — see findings`. (The integration `file:line` findings live in the report's `### What I reviewed` section — never dropped.) Next step:
  ```
  Fix the integration findings above on <PARENT-BRANCH>, push, then re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree) to re-review the parent PR.
  ```
- **M-FULLY-COMPLETE** — parent PR merged into base (detected by the step-1 phase check or step 5a). Title: `Fully complete — parent PR merged`. Next step:
  ```
  Parent PR #<n>: ✅ merged into <BASE_BRANCH> (Jira auto-transitioned by GitHub-for-Jira). No re-run needed.
  ```

#### Per-sub-task-PR outcomes (multistep track — 3d/3e emissions only, never the run-level step-6 pick)

These fill the *per-PR* emission for a single sub-task PR on the multistep
track (the 3d verdict comment + its 3e parent-tally reuse). They exist
because a sub-task PR is not single-step — it merges into `<PARENT-BRANCH>`
rather than `<BASE_BRANCH>`, and a reviewer re-run *is* required afterwards
to pick up the parent PR — so the single-step `S-*` wording ("merge into
`<BASE_BRANCH>`", "final update, no re-run needed") would be wrong on it.
Step 6's own run-level report never selects these; it uses the `M-*`
outcomes above.

- **M-SUBTASK-APPROVED** — a sub-task PR approved. Title: `Sub-task PR approved — awaiting merge into parent`. Next step:
  ```
  Sub-task PR #<n>: ✅ reviewed and approved. It merges into <PARENT-BRANCH>, not <BASE_BRANCH> — merging is manual. Once every sub-task PR is approved and merged into <PARENT-BRANCH>, re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree) to pick up the parent PR. A re-run IS required — this is not the final update.
  ```
- **M-SUBTASK-CHANGES-REQUESTED** — a sub-task PR rejected. Title: `Sub-task PR changes requested — see findings`. (The `file:line` findings live in the report's `### What I reviewed` section.) Next step:
  ```
  Fix the findings above in the sub-task's branch and push; the executor re-run moves the sub-task back to <STATUS_IN_REVIEW>. Then re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree).
  ```

## 7. Edge cases

- **No sub-tasks in review status, but sub-tasks exist** → report that the executor hasn't pushed any PRs to In Review yet; the user may re-run later.
- **Sub-task with no branch / no PR**: flag in the report. The skill can only review what has been pushed and has a PR open. Don't attempt to create branches or PRs — that's the executor's job.
- **A review (or approval) from someone else**: the skill always does its own review — an existing review by another account doesn't skip the code-review step. The 3a idempotency check only looks at *this skill's own* prior comments, keyed on `<SELF>`'s login + body prefix.
- **Already reviewed by this skill (idempotency)**: see 3a — a prior self-review whose body starts `APPROVED —` skips re-review (waiting for manual merge); one starting `CHANGES REQUESTED —` triggers a re-review of the fresh code. For a forced re-review, flag it manually.
- **`gh` not installed or not authenticated**: the step-3 `SELF=$(gh api user --jq .login)` resolution fails, so 3a's idempotency check has no identity to key on — report the error and give the user the PR URLs so they can review/merge manually.
- **Parent branch is behind its base**: If `<BASE_BRANCH>` has advanced, the parent PR may show conflicts. Stop and report. The user can rebase `<PARENT-BRANCH>` onto `<BASE_BRANCH>` and re-run.
- **Single-step PR merged before reviewer runs**: The phase check in step 1 detects this and reports the merged state via step 6 (S-MERGED), then exits — no wrap-up; GitHub-for-Jira already handled the `<STATUS_DONE>` transition.

Reference: `../_shared/jira-acli-reference.md` has the full acli syntax, confirmed issue types, and git/branch conventions this skill depends on. The `jira-sdlc-tools.env` (team-shared) and `jira-sdlc-tools.local.env` (machine-specific) files in the project root have this repo's specific values for every `<TOKEN>` used above.
