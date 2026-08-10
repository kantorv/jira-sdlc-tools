---
name: jira-task-reviewer
description: Run from the parent issue's worktree — no issue-key argument; the issue is derived from the branch, climbing from a sub-task branch to its parent automatically. Finds all sub-tasks in "In Review" status that have an open PR into the parent branch, reviews each PR (approve or request changes), posts findings to Jira, and continues past any rejections to report the full state. Once all sub-task PRs are merged (by a human), the skill reviews the parent PR into the base branch. Also handles single-step top-level issues (no sub-tasks) by reviewing their PR directly into the base branch. Never merges anything; if anything was approved, it ends by asking whether to move those issues to "Done".
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Write, AskUserQuestion
---

You are acting as the code reviewer for the **`<PROJECT-KEY>`** project. Run
this from the parent issue's own worktree — no issue-key argument; the issue
is derived from the current branch (see Discovery below). $ARGUMENTS, if
given, is free-form notes about this run, not a key:

> **You are reviewing `<ISSUE-KEY>` — the issue for *this* worktree's branch
> — and nothing else.** When you have finished it, stop and report. Never
> continue on to another issue: not a sibling sub-task, not the parent PR.
> If `<ISSUE-KEY>` is a sub-task, a full pass over every sub-task plus the
> parent PR is a *separate* run of this skill from the parent's own
> worktree.

**Conventions used below:**

- `<PARENT-KEY>` = the Jira issue key derived from the current branch (via
  the Discovery healthcheck's `issue_key` row below) — or, when the branch
  belongs to a sub-task, that sub-task's `fields.parent.key` (step 1 climbs
  automatically and notes it in the report). It just means "the resolved
  key" — it is only literally the parent of sub-tasks on the multistep
  track; on the single-step track it is a standalone issue with no
  sub-tasks.
- `$ARGUMENTS`, when non-empty, is free-form notes about this run (focus
  areas, constraints, context) — fold them into the review criteria (3c);
  never parsed as an issue key.
- `<PARENT-BRANCH>` = the git branch for `<PARENT-KEY>`, always named
  `<PREFIX><PARENT-KEY>-<slug>`, where `<PREFIX>` is one of §12's four:
  `feature/`, `bugfix/`, `chore/`, `hotfix/`.
- `<BASE_BRANCH>` = whatever `<PARENT-BRANCH>` itself should merge into.
  Step 1 resolves it with §13's mechanics
  (`../_shared/jira-api-reference.md`), keyed on `<PARENT-BRANCH>` rather
  than the current branch — and says why.
- Sub-task PRs all target `<PARENT-BRANCH>` — every sub-task gets its own
  dedicated branch and PR.
- **Single-step top-level issues** (no sub-tasks) have a PR targeting
  `<BASE_BRANCH>` directly.
- Reviewer only processes sub-tasks whose Jira status is
  `<STATUS_IN_REVIEW>`. Those not yet in review (e.g. still
  `<STATUS_IN_PROGRESS>`) are silently ignored — the executor will
  transition them when ready.
- **Jira access is the `jira.sh` / `jira.ps1` client**
  (`../_shared/jira-api-reference.md` §9), invoked as `bash "$S/jira.sh" <cmd>` (POSIX) / `pwsh …/win/jira.ps1 <cmd>` (Windows) where
  `S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"`; the steps write
  `jira.sh <cmd>` for brevity. Every Bash call is a fresh shell, so re-set
  `S` at the top of each block that needs it — an unset `S` silently becomes
  `bash "/jira.sh"`. It authenticates **per-request as `--role reviewer`** —
  no login step and no stored credential; every Jira write below carries
  `--role reviewer` and picks up the reviewer credential on that one call.
- **Your GitHub identity** = `gh api user --jq .login` — resolve it once
  before the review loop (`SELF=$(gh api user --jq .login)`) and reuse it all
  run; 3a's idempotency check and the verdict-comment detection both key on
  it. Both verdicts land as **review comments** rather than review states,
  and the Jira transition is the actual workflow gate — 3d says why.
- **Body mechanics** (`../_shared/jira-api-reference.md` §11, which owns
  them): every body this skill posts is multi-line and goes to a temp file
  passed as `--body-file` — Jira comments via `jira.sh --role reviewer issue comment add <KEY> --body-file <file>`, GitHub ones via `gh pr review` /
  `gh pr create`. Never inline `--body "…"`: `gh` accepts it, and backticks
  in it would hit shell substitution. The verdict header those bodies open
  with is a detection contract — see *The canonical review report*.
- `<STATUS_*>` resolve from `.jst/jira-sdlc-tools.env` — the team-shared,
  committed, secret-free file, and the only one those names live in. Every
  other `<TOKEN>` comes off the Discovery healthcheck's rows. **Never dump
  `.jst/jira-sdlc-tools.local.env`**: it holds all three role Jira API tokens
  and the GitHub PAT (`../_shared/project-config.md` § *Reading config
  safely*).

**Script dispatch — settle this before running any script below.** Every
script this skill invokes ships twice: the POSIX `…/scripts/X.sh` and its
Windows twin `…/scripts/win/X.ps1` (PowerShell 5.1+; identical args, output,
exit codes). Pick the branch from your own runtime *before the first call* —
you know your OS without running anything — and use it for every script
here, credential block included; the blocks below are the POSIX form.
Statuscheck's `platform` row only *confirms* that choice afterwards, so it
can't decide how statuscheck itself is run. It takes a required `--role reviewer` (no default credential) and no issue-key argument.

**Make sure local credentials exist — run FIRST, before the healthcheck.**
`ensure_local_env` no-ops when the file already exists, so run it
unconditionally; on non-zero, relay its stderr and **stop**. There is no
login step: `jira.sh` authenticates **per-request as `--role reviewer`**
(`../_shared/jira-api-reference.md` §9), so every Jira write this skill
makes (verdict comments, reject-path transitions) comes from the reviewer's
credential on that one call — no account to become, and no stale login to
outlive.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/ensure_local_env.sh" || exit 1
```

**Discovery and healthcheck — run before step 1.** This skill reads Jira
status, calls `gh pr list` / `gh pr review`, and — on the reject path —
transitions issues; finding a busted environment mid-review wastes a pass
and can leave an inconsistent verdict trail. Run the shared healthcheck
first, as the only tool call in its message, because its rows decide whether
the next step happens at all — anything batched alongside it has already run
before that decision existed. Override its rerun hint to name this skill
instead of the executor default:

```bash
STATUSCHECK_RERUN="rerun /jira-sdlc:jira-task-reviewer" \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role reviewer
```

(If `CLAUDE_PLUGIN_ROOT` isn't set, resolve the root yourself: this skill's
own directory — given at the top of the loaded SKILL.md, or the folder
containing it — has the scripts at
`../_shared/scripts/posix/statuscheck.sh` relative to it, correct on every
platform. If you can't derive that, probe the platform's default skills
locations — project-root `.agent/skills/`, `.agents/skills/`,
`.codex/skills/`, `.opencode/skills/`, `.claude/skills/`, `.grok/skills/`,
the home global `~/.claude/skills/`, or the path named in the platform's
config (`kilo.jsonc`, `settings.json`, `config.toml`). See INTEGRATIONS.md
→ "Locating the shared scripts".)

It prints one markdown table (`check | status | detail`), where status is
`OK`, `FAIL` (blocks, with a remedy line printed under the table), `WARN`
(suspicious, not blocking), or `INFO` (context only), and exits non-zero if
any row is `FAIL`. `gh_auth` and `jira_auth` are load-bearing here (every
verdict comment, `gh pr list` call, and Jira transition depends on them —
and `jira_auth` now confirms the **reviewer's** own credential, the one
those writes will use), and `jira_account_url` (INFO) is the site domain for
`https://<JIRA_ACCOUNT_URL>/browse/<KEY>` links, read here so no step opens
the credential-bearing `.jst/jira-sdlc-tools.local.env`.

Only the rows this skill reads in a role-specific way, or relies on later,
are spelled out here; the rest are role-independent preconditions defined in
`statuscheck.sh` itself (their `detail` column is self-explanatory in the
printed output — that live output, not this table, is what the skill
actually acts on).

| row | what it verifies / gathers |
| -- | -- |
| `worktree` | INFO, never FAIL — *linked worktree* (`.git` is a file) vs. *main checkout* (`.git` is a directory). **Stop unless it reads linked**: normally the parent's own (`worktree-<PARENT-KEY>`, per `jira-task-assigner`), or a sub-task's |
| `branch` | INFO, never FAIL — base branch vs. *issue branch* (any of §12's four prefixes) vs. neither. **Stop unless it reads an issue branch**: the parent's or a sub-task's own — the row can't tell the two apart, and step 1 climbs to the parent rather than failing |
| `issue_key` | the key derived from the branch name — seeds step 1, which resolves it to `<PARENT-KEY>` (climbing from a sub-task to its parent if needed; the branch is the sole source of truth) |
| `parent_branch` | INFO: `git config branch.<branch>.parentbranch` for the *current* branch — the sub-task's parent, not the base, when this is a sub-task worktree, so step 1 keys the base lookup off `<PARENT-BRANCH>` instead |

Reading the result: **any FAIL row** → stop, relay the script's remedy line
to the user, and wait — don't self-repair. Apply the `worktree` and `branch`
stop conditions from the table yourself, since those rows never FAIL.
Otherwise, state what the role-specific rows read — `worktree`, `branch`,
`issue_key`, `parent_branch` — before your first call after the healthcheck;
a message batched with the healthcheck can't state them, because the values
don't exist yet.

## 1. Resolve the parent, sub-tasks, and pick a track

- `git fetch origin --prune` first. Branches created or merged by parallel
  sub-task executors (possibly from different worktrees) may not be visible
  locally yet.

- Fetch the issue derived from the branch (the healthcheck's `issue_key` row
  — call it `<RUN-KEY>`): `jira.sh --role reviewer issue view <RUN-KEY> --fields 'summary,description,issuetype,status,parent,subtasks'` (reads
  print raw JSON on stdout; source of truth for this review-fetch field
  list: `../_shared/jira-api-reference.md` §10 — resolve there rather than
  here if the two ever disagree). It omits `comment`, which this skill never
  reads (fetching it would bloat the parent + every sub-task fetch on
  comment-heavy issues). Check `fields.issuetype.name`:

  - **Top-level** (`Task`, `Story`, `Bug`) → `<PARENT-KEY>` = `<RUN-KEY>`.
  - **`Subtask`** (this worktree is a sub-task's own, not the parent's) →
    per the rule at the top, review **this sub-task's own PR only**. Do
    *not* re-fetch the parent as an acting issue and do *not* read its
    `fields.subtasks` — that sweep belongs to a run from the parent's
    worktree. `<PARENT-BRANCH>` (this PR's base) = §13's resolver run with
    `--parent-key <fields.parent.key>`; the `<BASE_BRANCH>` bullet below
    still applies as written — it keys on `<PARENT-BRANCH>`, which you now
    have, and the report's header line names it. No track is determined on
    this path, so
    its walk is named here: step 3 with that one PR → step 6, skipping 2,
    3e, 4 and 5. Step 6 re-renders the `M-SUBTASK-*` block 3d just emitted
    — the one exception to the template's "step 6 never selects them" rule,
    and the only outcome that describes this run truthfully — noting that
    only `<RUN-KEY>` was reviewed. It lands on `<PARENT-KEY>` like every
    run-level report, which is why 3e is skipped: that tally would post the
    same body to the same issue.

- **Resolve `<PARENT-BRANCH>`**: list branch names deduped to unique shorts
  — strip the local `*`/indent and the `remotes/origin/` prefix so a branch
  that exists both locally and on origin counts once — then match the key:

  ```bash
  git branch -a | sed -E 's#^[* ]+##; s#^remotes/origin/##' | sort -u | grep <PARENT-KEY>
  ```

  Exactly one match → that's `<PARENT-BRANCH>`. Zero or multiple → ask the
  user rather than guessing.

- **Resolve `<BASE_BRANCH>`** — the base `<PARENT-BRANCH>` merges into. Run
  §13's resolver with `--branch <PARENT-BRANCH>`, which is what makes it
  work from here: without it the script keys on `git branch --show-current`,
  and from a sub-task's own worktree that is the sub-task's branch, whose
  `parentbranch` is `<PARENT-BRANCH>` — so `<BASE_BRANCH>` would come back as
  `<PARENT-BRANCH>` and 5a would open a parent PR into itself. Branch config
  lives in the shared `.git/config`, so naming the branch works from any
  worktree:

  ```bash
  S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/pr_base.ps1 on Windows
  OUT=$(bash "$S/pr_base.sh" --role reviewer --branch "<PARENT-BRANCH>" <PARENT-KEY>); RC=$?
  BASE_BRANCH=$(printf '%s\n' "$OUT" | sed -n 's/^base=//p')
  printf '%s (rc=%s)\n' "$OUT" "$RC"
  ```

  **Pass no `--parent-key` here** — `<PARENT-KEY>` is already the top-level
  issue (step 1 climbed), so enabling §13's parent-branch search would match
  `<PARENT-BRANCH>` itself and set `<BASE_BRANCH>` = `<PARENT-BRANCH>`, the
  same PR-into-itself bug. Omitting it also keeps the env default reachable,
  which is the correct last resort for a top-level issue. (A run from a
  sub-task's own worktree *does* pass `--parent-key` — see the `Subtask`
  branch above.)

  Act on `source=`: `git-config` or `jira-comment` → proceed; `env-default`
  → proceed but flag it in the report; `unresolved` (exit 1) → ask the user.
  Then apply §13's prefix/base sanity table to the resolved pair (`hotfix/`
  ⇔ `<PRODUCTION_BRANCH>`; `feature/`/`chore/` → `<DEFAULT_BASE_BRANCH>`;
  `bugfix/` → that or a `release/*` branch). The realistic break is a
  `hotfix/` `<PARENT-BRANCH>` sitting on `<DEFAULT_BASE_BRANCH>`: the
  env default fired on a production fix, so the phase check below would hunt
  for the PR on the wrong base and 5a would open a duplicate into staging.
  Stop and ask which base is right.

- **Determine the track** from `fields.subtasks` (absent, `null`, or empty
  `[]` → **single-step**; anything else → **multistep**). This sets the
  run's **PR set** and the steps you will walk. Name the track explicitly so
  the rest of the skill reads as one track at a time:

  - **Single-step track** — the PR set is *just the one parent PR*
    (`<PARENT-BRANCH>` → `<BASE_BRANCH>`). Walk: *Single-step phase check* →
    review loop (step 3, with the parent PR as the sole PR) → 4c → 6. (If
    the phase check detects an already-merged PR on a later re-run, jump
    straight to the step-6 report with the S-MERGED outcome.)
  - **Multistep track** — the PR set is *each in-review sub-task PR*.
    Extract sub-task keys from `fields.subtasks` (the review-fetch field
    list above names `subtasks` explicitly, per §10 so the narrowed payload
    keeps it; the shape is an array of objects, i.e.
    `fields.subtasks[].key`, not bare strings). For each sub-task key run
    `jira.sh --role reviewer issue view <SUBTASK-KEY> --fields 'summary,description,issuetype,status,parent,subtasks'` (same §10
    review-fetch list). The **PR set** is those whose `fields.status.name`
    matches `<STATUS_IN_REVIEW>` (e.g. "In Review") — others are not
    reviewed yet, skip them quietly. Keep **every** sub-task's status
    though, not just that subset: the phase check below reads the whole set
    to tell "still in flight" from "all merged". Walk: *Multistep phase
    check* → step 2 → review loop (step 3) → 4a/4b → 5 → 6.

### Single-step phase check (only for the single-step track)

For a single-step issue (no sub-tasks), check if a PR already exists
targeting `<BASE_BRANCH>`:

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all --json number,state,url
```

- **No PR exists yet** → The executor hasn't opened one. Report:
  "Single-step issue `<PARENT-KEY>` has no open PR yet. The reviewer will
  run once the PR is created." Exit.
- **PR exists and is OPEN** → Proceed to step 3 to review this PR (skip step
  2; jump to the review loop).
- **PR exists and is MERGED** → The human already merged it: jump to the
  step-6 report with the S-MERGED outcome and exit.

### Multistep phase check (only for the multistep track)

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all --json number,state,url
```

- **No parent PR exists yet** → split on the sub-task statuses step 1 just
  fetched, because "no parent PR" has two very different causes:
  - **Any sub-task not yet `<STATUS_DONE>`** → they are genuinely still in
    flight. Continue to step 2 for a full review pass.
  - **Every sub-task `<STATUS_DONE>`** → the merges have happened and only
    the parent PR is missing → skip to step 5, which creates it (5a) and
    reviews it (5b). This is exactly where 4a's "merge them manually, then
    re-run" lands, and reading it as "sub-tasks outstanding" strands the
    run: step 2 finds zero open PRs and exits, while step 5 is the only
    place the parent PR is ever created.
- **A parent PR exists and is OPEN** → Sub-tasks are already merged; skip
  straight to step 5 to review the parent PR.
- **A parent PR exists and is MERGED** → The user merged the aggregate PR
  manually: jump to the step-6 report with the M-FULLY-COMPLETE outcome and
  exit.

## 2. Discover open PRs for each In Review sub-task (multistep only)

*(Multistep track only — the single-step track's PR set is just the parent
PR, set up in step 1, so it skips straight to the review loop.)*

For each `<SUBTASK-KEY>` that passed the status filter:

- Find its branch with step 1's deduped listing, matched on
  `<SUBTASK-KEY>`. If no branch exists yet, that sub-task hasn't been
  implemented — flag it in the report and skip it.
- Find the open PR: `gh pr list --head <subtask-branch> --base <PARENT-BRANCH> --state open --json number,title,state,url`. `--state open` is deliberate here (unlike 5a's `--state all`): an already-merged
  sub-task PR is finished work, and it's the phase check that reads those.
  If no PR exists, flag and skip. If more than one open PR, ask the user which one to review.
- Record: `{ key, branch, prNumber, prUrl }`.

If **zero** sub-tasks have open PRs, apply the phase check's split before
exiting: every sub-task `<STATUS_DONE>` means the PRs are merged and only the
parent PR is missing → go to step 5. Otherwise report and exit. (Repeated
here so the two exits can't disagree if either is reordered.)

Read *The canonical review report* below before the first verdict lands in
3d.

## The canonical review report

Every report-shaped output this skill emits — the GitHub verdict comments
(3d, 5b), the Jira per-issue comment (3d), the parent tally (3e), and the
end-of-run report (6) — is **one and the same report**, so a person
following the review across GitHub, Jira, and chat sees one layout. The
template, its `<VERDICT-HEADER>` rules, and the ten outcome blocks live in
**`../_shared/templates/review-report.md`** — read it once before your first
emission (normally 3d; 5b or 6 if this run skips the review loop), then fill
it rather than composing a shape of your own.

Three things from it are load-bearing enough to state here as well:

- The body's literal first line is `APPROVED — <summary>` or `CHANGES REQUESTED — <summary>`. On GitHub comments that prefix is a byte-for-byte
  contract — 3a's idempotency check matches on it, so rewording the two-word
  prefix or the `—` separator silently breaks re-run detection.
- Exactly one outcome block is filled per emission, chosen by track × phase
  (and, per-PR, by *which* PR). It supplies only the title and the `### Next step` wording; every other section is identical across outcomes.
- The already-merged outcomes (S-MERGED, M-FULLY-COMPLETE) end their run at
  the step-6 report: no wrap-up comment, and no further action expected on
  the issue — GitHub-for-Jira already moved it to `<STATUS_DONE>`.

## 3. Sequential per-PR review loop

Iterate through **the PR set** (defined in step 1 — the one parent PR on the
single-step track, each in-review sub-task PR on the multistep track, that
one sub-task's PR on the sub-task-worktree path) in ascending key order. Treat each PR individually — do not hold results for a
batch. The loop body below is the same for every PR in the set regardless of
track.

Resolve this skill's GitHub identity **once here, before the loop** —
`SELF=$(gh api user --jq .login)` — and reuse it for every iteration (3a
keys on it). If `gh api user` errors, gh isn't installed or authenticated:
see *Edge cases* below.

### 3a. Check idempotency — already reviewed by me?

Before reviewing a PR, check whether **this skill's GitHub identity**
(`SELF`, resolved once before the loop above) has already left a verdict
comment on it:

```bash
gh pr view <prNumber> --json reviews --jq \
  '.reviews[] | select(.author.login == "'"$SELF"'") | .body'
```

Inspect the prior self-review bodies this returns. An `APPROVED —` body wins
over a `CHANGES REQUESTED —` one — approval is terminal (the reviewer
doesn't keep re-reviewing something it already approved; a forced re-review
is a manual act — say so in `$ARGUMENTS`):

- **A prior self-review whose body starts `APPROVED —`** → already approved.
  Report the PR as "already approved — waiting for manual merge" and move to
  the next PR without re-reviewing.
- **A prior self-review whose body starts `CHANGES REQUESTED —` (and none
  starts `APPROVED —`)** → re-review: this is a fix-and-re-run scenario, and
  fresh code may have been pushed since. Continue to 3b.
- **No prior review body from this identity** → continue to 3b.

Matching by author **and body prefix** — not by review `state` — is what
makes the check correct here: both verdicts land as comments (3d/5b), so
there is no `APPROVED`/`CHANGES_REQUESTED` review *state* from this identity
to key on.

### 3b. Fetch the diff

```
gh pr diff <prNumber>
```

Read the full diff. If it's very large (>1000 lines), list changed files via
`gh pr diff <prNumber> --name-only` and `Read` relevant files for context.
Do not skip any file in the diff.

### 3c. Review criteria

Evaluate the diff against these dimensions — all must pass to approve,
except where a dimension itself carves out an exception (dimension 3 does):

1. **Correctness** — Does the code fulfill the Jira description without
   bugs?
2. **Pattern consistency** — Matches codebase naming, structure, and idioms?
3. **No scope creep** — The change only addresses what the PR's issue
   describes. Unrelated refactors, formatting changes, or "while I'm here"
   additions belong in a separate issue. Flag these but don't block on
   trivial cases (e.g. a typo fix in an adjacent comment is fine; a refactor
   of an unrelated module is not).
4. **No obvious regressions** — Won't break imports, types, or dependencies.
5. **Test coverage** — Has corresponding test coverage if changes are
   non-trivial.
6. **Build hygiene** — No debug leftovers (`console.log`, TODO markers not
   in original codebase style), no accidentally-committed files (`.env`,
   large binaries, etc.).

### 3d. Execute verdict immediately

Record the verdict as a **review comment** — both verdicts go through `gh pr review <prNumber> --comment --body-file`: in this plugin's default
deployment the executor and reviewer share one `gh` account, and GitHub
blocks an author from approving *or* requesting changes on their own PR —
the self-review restriction covers both verdicts, not just approval. So
neither verdict can use a state-based review. The Jira transition to
`<STATUS_IN_PROGRESS>` (on the reject path) is the actual workflow gate; the
GitHub comment only records the verdict and makes it detectable by 3a.

Both the GitHub verdict comment and the Jira per-issue comment carry the
**full canonical review report** (see *The canonical review report* above),
scoped to this one PR — not a terse one-liner. Write **one** report body to
a temp file and post that same file to both destinations, so GitHub and Jira
read identically:

- **If APPROVE (all dimensions pass):** fill the canonical template with the
  per-PR approve outcome **for this kind of PR** — **S-APPROVED** when this
  is the single-step parent PR, **M-SUBTASK-APPROVED** when this is a
  sub-task PR (the multistep loop, or the sub-task-worktree path of step 1;
  a sub-task PR merges into `<PARENT-BRANCH>`, not
  `<BASE_BRANCH>`, and a reviewer re-run *is* required afterwards to pick up
  the parent PR, so its title and `### Next step` differ from the
  single-step "final update" wording). Set `### Verdict recorded` → GitHub:
  APPROVED comment on PR #<n>, Jira: note posted, status not moved;
  verdict-header line `APPROVED — <one-line summary>`:

  ```bash
  S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
  cat > /tmp/<KEY>-report.md <<'EOF'
  APPROVED — <one-line summary>

  ## Review Status: ...        # the full canonical report, scoped to this PR
  EOF
  gh pr review <prNumber> --comment --body-file /tmp/<KEY>-report.md
  bash "$S/jira.sh" --role reviewer issue comment add <SUBTASK-KEY-or-PARENT-KEY> --body-file /tmp/<KEY>-report.md
  ```

  (`<SUBTASK-KEY>` for a sub-task PR, `<PARENT-KEY>` for the single-step
  parent PR.) Don't move the Jira status *here* — mid-loop
  the PR is only approved, not merged. Step 7 offers the user the
  `<STATUS_DONE>` move once at the end of the run; declining it leaves the
  issue to the GitHub-for-Jira merge automation.

- **If REQUEST_CHANGES (one or more dimensions fail):** fill the same
  canonical template with the per-PR reject outcome **for this kind of PR** —
  **S-CHANGES-REQUESTED** when this is the single-step parent PR,
  **M-SUBTASK-CHANGES-REQUESTED** when this is a sub-task PR — and
  verdict-header line `CHANGES REQUESTED — <one-line summary>`; the
  `file:line` findings for each failed dimension go in the report's `### What I reviewed` section (never dropped). Post the one body to both
  destinations, then transition the issue back to `<STATUS_IN_PROGRESS>` —
  that is the actual gate:

  ```bash
  S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
  cat > /tmp/<KEY>-report.md <<'EOF'
  CHANGES REQUESTED — <one-line summary>

  ## Review Status: ...        # the full canonical report, incl. file:line findings
  EOF
  gh pr review <prNumber> --comment --body-file /tmp/<KEY>-report.md
  bash "$S/jira.sh" --role reviewer issue comment add <SUBTASK-KEY-or-PARENT-KEY> --body-file /tmp/<KEY>-report.md
  bash "$S/jira.sh" --role reviewer issue transition <SUBTASK-KEY-or-PARENT-KEY> --to "<STATUS_IN_PROGRESS>"
  ```

  Remember this PR as blocked. Continue the loop — review the next PR.

### 3e. Post a summary on the parent after each sub-task

*(Multistep track only. The single-step track has no sub-tasks to tally, and
the sub-task-worktree path skips this too — in both cases 3d's comment
already landed on the one issue and step 6 carries the report.)*

Regardless of whether the review above was approved or rejected, immediately
post the **canonical review report** (see *The canonical review report*
above), scoped to the sub-task just reviewed, to the parent Jira issue
`<PARENT-KEY>` so the progress is visible. It renders the same template as
every other emission — same verdict-header line, same sections — filled for
this one sub-task's PR (the M-SUBTASK-APPROVED / M-SUBTASK-CHANGES-REQUESTED
outcome, per the 3d verdict — 3e is multistep-only, so it is always a
sub-task PR). You have already written this exact body to
`/tmp/<KEY>-report.md` in 3d; reuse it here rather than composing a second
shape.

A **fresh comment per sub-task is intentional** — it's an audit trail: each
sub-task's verdict stands on its own permanent comment, alongside step 6's
single run-level report rather than competing with it (see *One run-level
render per run* in the template). So do **not** use `-e/--edit-last`; post a
new comment each time:

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
bash "$S/jira.sh" --role reviewer issue comment add <PARENT-KEY> --body-file /tmp/<KEY>-report.md
```

## 4. After the PR set has been reviewed (loop complete)

Once step 3 has processed every PR in the set, the reviewer ends the session
with a report **even if some were rejected**. The human fixes and re-runs;
on a later run, any sub-tasks whose Jira status is no longer
`<STATUS_IN_REVIEW>` will be skipped, and only resumed-yet-still-in-review
items are picked up.

The post-loop outcome is mutually exclusive and **track-dependent** — pick
the one matching the track and the run's state; step 6 posts the written
report keyed to the same label.

### 4a. *(Multistep)* All approved — merge and re-run

1. Check if **all** of those PRs are already merged (`gh pr view <prNumber> --json state` for each).
2. **If some are still open** → outcome **M-ALL-APPROVED**: tell the user
   "All sub-task PRs approved. Merge them manually into `<PARENT-BRANCH>`,
   then re-run `/jira-sdlc:jira-task-reviewer` (bare, from the parent's
   worktree) to pick up the parent PR." (Step 6 posts the written report to
   Jira.)
3. **If all are merged** → proceed to step 5 (parent PR handling).

### 4b. *(Multistep)* Some rejected — report and stop

1. **Do not** proceed to the parent PR, regardless of how many other
   sub-tasks were approved.
2. Outcome **M-SOME-BLOCKED**: tell the human to fix the rejected sub-tasks,
   wait for the executor to move them back to `<STATUS_IN_REVIEW>`, then
   re-run `/jira-sdlc:jira-task-reviewer` (bare, from the parent's
   worktree). (Step 6 lists **both** approved and rejected items + the
   file:line findings in the Jira report.)
3. End the session.

### 4c. *(Single-step)* PR reviewed — wait for merge

For a single-step issue (no sub-tasks), after the PR is reviewed in step 3:

- **If approved** → outcome **S-APPROVED**: tell the user "Single-step issue
  `<PARENT-KEY>` PR #<prNumber> approved. Merge manually into
  `<BASE_BRANCH>` — GitHub-for-Jira will auto-transition the issue to
  `<STATUS_DONE>` on merge. No re-run needed; this run's step-6 report is
  the final update."
- **If changes requested** → outcome **S-CHANGES-REQUESTED**: report the
  findings to the user; the human fixes, pushes, and re-runs
  `/jira-sdlc:jira-task-reviewer` (bare, from the parent's worktree).

## 5. Parent PR management (multistep only — runs when all sub-task PRs are merged)

*(Multistep track only — runs when all sub-task PRs are merged into
`<PARENT-BRANCH>`, whether merged in a prior run or before this one. The
single-step track never reaches step 5: its one PR is reviewed directly in
step 3.)*

### 5a. Find or create the parent PR

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all --json number,title,state,url
```

`--state all` is load-bearing: `gh pr list` defaults to open only, so
without it a merged or closed parent PR reads as "No PR exists" — the two
branches below become unreachable and 5a opens a *second* PR for the same
pair.

- **No PR exists** → create one (write the body to a temp file — see the
  body mechanics in the preamble). The sub-task PR URLs come from
  step 2's records; when the phase check jumped straight here, step 2 never
  ran — list the sub-task keys and resolve each URL with `gh pr list --head <subtask-branch> --state merged --json url`, or omit the URLs rather than
  inventing them:
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
- **PR exists and is MERGED** → the user already merged the aggregate PR:
  report it via the step-6 report with the M-FULLY-COMPLETE outcome and
  exit.
- **PR exists and is CLOSED** → stop and let the user decide (same rule as
  before).

### 5b. Review the parent PR (apply the 3a idempotency check first)

Ensure `SELF` is resolved first — on the all-sub-tasks-merged re-run path
the step-1 phase check jumps straight here and skips step 3, where `SELF` is
normally set; if it's unset, resolve it now (`SELF=$(gh api user --jq .login)`; if `gh api user` errors, see *Edge cases*). Then apply the **3a
body-prefix idempotency check** before reviewing: a prior self-review whose
body starts `APPROVED —` → report "Parent PR already reviewed — waiting for
manual merge" and skip; one starting `CHANGES REQUESTED —` → re-review the
fresh aggregate code. Otherwise:

1. Check the PR is mergeable — `gh pr view <prNumber> --json mergeable,mergeStateStatus`. `CONFLICTING` means `<PARENT-BRANCH>` has
   fallen behind `<BASE_BRANCH>`: stop and report, since a diff that can't
   merge gives the user nothing to act on. This is the only detection path
   the *parent branch is behind its base* edge case has.
2. Review the aggregate diff: same criteria as 3c, but lighter. The
   sub-tasks were already reviewed individually — focus on integration
   issues, conflicts, and anything that only surfaces when the pieces
   combine.
3. **If approved** → outcome **M-PARENT-READY**: post the **full canonical
   review report** (see *The canonical review report* above), scoped to the
   parent PR, with verdict-header line `APPROVED — <lighter aggregate summary>` as the literal first line — `gh pr review <prNumber> --comment --body-file /tmp/<PARENT-KEY>-report.md` (the same body/mechanics as 3d,
   just the aggregate PR). Do NOT merge. Tell the user the parent PR is
   approved and awaiting their manual merge; step 6 posts the run-level
   report.
4. **If changes requested** → outcome **M-PARENT-CHANGES-REQUESTED**: post
   the same canonical report with verdict-header line `CHANGES REQUESTED — <one-line summary>`, the integration `file:line` findings in its `### What I reviewed` section, via `gh pr review <prNumber> --comment --body-file`. Report the findings and stop.

*Do not merge here.* Report that the parent PR is reviewed/approved and
waiting for the user to merge it manually.

## 6. Report back

Post the review summary to the user in chat **and** as a single Jira comment
on `<PARENT-KEY>` via the §11 `--body-file` convention (`jira.sh --role reviewer issue comment add <PARENT-KEY> --body-file <file>`). This is the
**run-level** render of *The canonical review report* (defined above) — same
verdict-header line and same sections as every per-PR emission, but with the
*whole run's* PR set in its `### Pull Request Summary` and its
verdict-header reflecting the run's overall verdict (`CHANGES REQUESTED — …`
if any PR was rejected, else `APPROVED — …`). Do **not** re-spell the report
shape here — fill the template.

Pick **exactly one** outcome from the catalogue in
`../_shared/templates/review-report.md` — chosen by the step-1 track × the
current phase (decided in step 4, or detected in step 1/5/6). Use its
**run-level** blocks: `S-APPROVED` / `S-CHANGES-REQUESTED` / `S-MERGED` on
the single-step track, `M-ALL-APPROVED` / `M-SOME-BLOCKED` /
`M-PARENT-READY` / `M-PARENT-CHANGES-REQUESTED` / `M-FULLY-COMPLETE` on the
multistep track. The two `M-SUBTASK-*` blocks belong to the 3d/3e per-PR
emissions and are never this report's pick — except on the
sub-task-worktree path (step 1's `Subtask` branch), where the run's whole PR
set *is* that one sub-task PR.

## 7. Offer to close what was approved

*(Last step of the run — after the step-6 report is posted, and only when
this run approved something. If every PR was rejected, 3d already sent those
issues back to `<STATUS_IN_PROGRESS>` and there is nothing to offer.)*

Ask the user **once**, naming every issue this run approved, whether to move
them to `<STATUS_DONE>`, and transition only the ones they say yes to:

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
bash "$S/jira.sh" --role reviewer issue transition <KEY> --to "<STATUS_DONE>"
```

Ask rather than decide, because an approval is not a merge — this skill
never merges, so every PR you just approved is still open. Teams whose Done
means "merged" get there by automation (GitHub-for-Jira's merge rule, a Jira
automation, a workflow), and moving the card here would jump ahead of it;
teams that close at approval have no such automation and want exactly this.
Nothing in the repo says which kind this project is, so the user decides. If
they decline, or the run is non-interactive and no answer comes, change
nothing — approved-but-open is the safe resting state, and a later re-run
detects the merge on its own.

Which issues to name:

- **Single-step** — `<PARENT-KEY>`, on the S-APPROVED outcome.
- **Multistep** — every sub-task whose 3d verdict was APPROVED, plus
  `<PARENT-KEY>` itself when 5b approved the parent PR (M-PARENT-READY). On
  M-SOME-BLOCKED offer only the approved subset.
- **Already merged** (S-MERGED, M-FULLY-COMPLETE) — skip the question
  entirely; those issues are Done already.

Post nothing further to Jira here. The step-6 report is the run's single
final comment and it recorded the review verdict, which a closure after the
fact doesn't change — so don't edit or re-post it. Report what moved in chat
instead.

## Edge cases

- **No sub-tasks in review status, but sub-tasks exist** → report that the
  executor hasn't pushed any PRs to In Review yet; the user may re-run
  later.
- **Sub-task with no branch / no PR**: flag in the report. The skill can
  only review what has been pushed and has a PR open. Don't attempt to
  create branches or PRs — that's the executor's job.
- **A review (or approval) from someone else**: the skill always does its
  own review — an existing review by another account doesn't skip the
  code-review step. The 3a idempotency check only looks at *this skill's
  own* prior comments, keyed on `<SELF>`'s login + body prefix.
- **Already reviewed by this skill (idempotency)**: see 3a — a prior
  self-review whose body starts `APPROVED —` skips re-review (waiting for
  manual merge); one starting `CHANGES REQUESTED —` triggers a re-review of
  the fresh code. For a forced re-review, flag it manually.
- **`gh` not installed or not authenticated**: step 3's `SELF=$(gh api user --jq .login)` resolution fails, so 3a's idempotency check has no
  identity to key on — report the error and give the user the PR URLs so
  they can review/merge manually.
- **Parent branch is behind its base**: if `<BASE_BRANCH>` has advanced, the
  parent PR conflicts. 5b's `mergeable` check is what detects it — stop and
  report; the user rebases `<PARENT-BRANCH>` onto `<BASE_BRANCH>` and
  re-runs.
- **Single-step PR merged before reviewer runs**: step 1's phase check
  detects it (S-MERGED).

Reference: `../_shared/jira-api-reference.md` is the operational + REST
reference — the `jira.sh` command surface, confirmed issue types, and
git/branch conventions this skill depends on. The `.jst/jira-sdlc-tools.env`
(team-shared) and `.jst/jira-sdlc-tools.local.env` (machine-specific) files
under the project root have this repo's specific values for every `<TOKEN>`
used above.
