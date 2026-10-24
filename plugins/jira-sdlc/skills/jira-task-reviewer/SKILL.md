---
name: jira-task-reviewer
description: Reviews the pull requests for the issue implied by the current worktree's branch — no issue-key argument. From a parent's worktree it reviews every sub-task PR that is in review, then the parent PR once those are merged; from a sub-task's worktree, just that sub-task's PR; single-step issues are reviewed directly. Posts an approve/request-changes verdict to GitHub and Jira, sends rejected issues back to In Progress, and continues past rejections to report the full state. Never merges; ends by offering to move approved issues to Done.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Write, AskUserQuestion
---

You are acting as the code reviewer for the **`<PROJECT-KEY>`** project. Run
this from the issue's own worktree — no issue-key argument; the issue is
derived from the current branch (see Discovery below).

> **Scope is set by the worktree you're standing in.** From the **parent's**
> worktree you review its whole PR set — every in-review sub-task PR, then
> the parent PR (steps 2–5). From a **sub-task's** worktree you review *that
> sub-task's PR and nothing else*: not a sibling, not the parent PR. A full
> pass is then a separate run from the parent's own worktree.

**Script dispatch — settle this before running any script below.** Every
script this skill invokes ships twice: the POSIX `…/scripts/X.sh` and its
Windows twin `…/scripts/win/X.ps1` (PowerShell 5.1+; identical args, output,
exit codes). Pick the branch from your own runtime *before the first call* —
you know your OS without running anything — and use it for every script
here, credential block included; the blocks below are the POSIX form.
Statuscheck's `platform` row only *confirms* that choice afterwards, so it
can't decide how statuscheck itself is run. It takes a required `--role reviewer` (no default credential) and no issue-key argument.

**Conventions used below:**

- `<PARENT-KEY>` = the Jira issue key derived from the current branch (via
  the Discovery healthcheck's `issue_key` row below) — or, when the branch
  belongs to a sub-task, that sub-task's `fields.parent.key` (step 1 climbs
  automatically and notes it in the report). It just means "the resolved
  key": it is literally a parent only on the multistep track — on the
  single-step track it is a standalone issue with no sub-tasks.
- `$ARGUMENTS`, when non-empty, is free-form notes about this run (focus
  areas, constraints, context) — fold them into the review criteria (3c); a
  re-review request in them also overrides 3a's already-approved skip. Never
  parsed as an issue key.
- `<PARENT-BRANCH>` = the git branch for `<PARENT-KEY>`, always named
  `feature/<PARENT-KEY>-<slug>` or `hotfix/<PARENT-KEY>-<slug>`.
- `<BASE_BRANCH>` = whatever `<PARENT-BRANCH>` itself should merge into.
  Step 1 resolves it with §13's mechanics
  (`../_shared/jira-api-reference.md`), keyed on `<PARENT-BRANCH>` rather
  than the current branch — and says why.
- Sub-task PRs all target `<PARENT-BRANCH>` — every sub-task gets its own
  dedicated branch and PR.
- **Single-step top-level issues** (no sub-tasks) have a PR targeting
  `<BASE_BRANCH>` directly.
- Reviewer only processes sub-tasks whose Jira status is
  `<STATUS_IN_REVIEW>`; the rest are silently ignored — the executor
  transitions them when ready.
- **`CLAUDE_PLUGIN_ROOT`** is this plugin's root, and every script path below
  hangs off it. If it isn't set (a non-Claude client), resolve the root
  yourself, in order: (1) this skill's own directory — given at the top of the
  loaded SKILL.md, or the folder containing it — so the scripts are at
  `../_shared/scripts/posix/` relative to it (correct on every platform); (2) if
  you can't derive that, probe the platform's default skills locations —
  project-root `.agent/skills/`, `.agents/skills/`, `.codex/skills/`,
  `.opencode/skills/`, `.claude/skills/`, `.grok/skills/`, the home global
  `~/.claude/skills/`, or the path named in the platform's config
  (`kilo.jsonc`, `settings.json`, `config.toml`). `jira.sh` and every other
  script the steps call live there; see INTEGRATIONS.md → "Locating the shared
  scripts".
- **Jira access is the `jira.sh` / `jira.ps1` client**
  (`../_shared/jira-api-reference.md` §9), where
  `S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"`; the steps write
  `jira.sh <cmd>` for brevity. Every Bash call is a fresh shell, so re-set
  `S` at the top of each block that needs it — an unset `S` silently becomes
  `bash "/jira.sh"`. It authenticates **per-request as `--role reviewer`** —
  no login step and no stored credential; every Jira write below carries
  `--role reviewer` and picks up the reviewer credential on that one call.
- **Your GitHub identity** = `gh api user --jq .login` — resolve it once
  before the review loop and substitute the value as `<SELF>` wherever the
  steps show it; 3a's idempotency check and the verdict-comment detection
  both key on it. Both verdicts land as **review comments** rather than review states,
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

**Make sure local credentials exist — run FIRST, before the healthcheck.**
`ensure_local_env` fills in only what `.jst/` lacks, so run it
unconditionally; on non-zero, relay its stderr and **stop**. There's no login
step to follow it (see the Jira-access bullet) — this only provisions config,
never an unignored credential.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/ensure_local_env.sh" || exit 1
```

**Discovery and healthcheck — run before step 1**, as the only tool call in
its message: its rows decide whether the next step happens at all, and
anything batched alongside it has already run before that decision existed (a
busted environment found mid-review wastes a pass and can leave an
inconsistent verdict trail). Override its rerun hint to name this skill:

```bash
STATUSCHECK_RERUN="rerun /jira-sdlc:jira-task-reviewer" \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role reviewer
```

It prints one markdown table (`check | status | detail`; status `OK`,
`FAIL` — blocks, remedy printed under the table — `WARN`, or `INFO`) and
exits non-zero on any `FAIL`. `gh_auth` and `jira_auth` (the reviewer
credential) carry every verdict, PR lookup and transition; `jira_account_url`
is the site domain for `https://<JIRA_ACCOUNT_URL>/browse/<KEY>` links — their
only source, so no step opens the credential-bearing
`.jst/jira-sdlc-tools.local.env` (`../_shared/project-config.md` § *Issue
browse links*). The table spells out only the rows this skill reads in a
role-specific way; the live output of the rest explains itself.

| row | what it verifies / gathers |
| -- | -- |
| `worktree` | INFO, never FAIL — *linked worktree* (`.git` is a file) vs. *main checkout* (`.git` is a directory). **Stop unless it reads linked**: normally the parent's own (`worktree-<PARENT-KEY>`, per `jira-task-assigner`), or a sub-task's |
| `branch` | INFO, never FAIL — base branch vs. `feature/*`/`hotfix/*` issue branch (§12) vs. neither. **Stop unless it reads a feature/hotfix issue branch**: the parent's or a sub-task's own — the row can't tell the two apart, and step 1 climbs to the parent rather than failing |
| `issue_key` | the key derived from the branch name — seeds step 1, which resolves it to `<PARENT-KEY>` (climbing from a sub-task to its parent if needed; the branch is the sole source of truth) |
| `parent_branch` | INFO: `git config branch.<branch>.parentbranch` for the *current* branch — the sub-task's parent, not the base, when this is a sub-task worktree, so step 1 keys the base lookup off `<PARENT-BRANCH>` instead |
| `repo_strategy` | `single`, or `submodules` with its member repos — an issue's PRs can then sit in several repos; *Reading PRs* reads them all either way |

Reading the result: **any FAIL row** → stop, relay the script's remedy line
to the user, and wait — don't self-repair. Apply the `worktree` and `branch`
stop conditions from the table yourself, since those rows never FAIL.
Otherwise, state what the role-specific rows read — `worktree`, `branch`,
`issue_key`, `parent_branch`, `repo_strategy` — before your first call after the healthcheck;
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
    review **this sub-task's own PR only**: do *not* re-fetch the parent as
    an acting issue or read its `fields.subtasks`, because that sweep belongs
    to a run from the parent's worktree.
    `<PARENT-BRANCH>` (this PR's base) = §13's resolver run with
    `--parent-key <fields.parent.key>`; the `<BASE_BRANCH>` bullet below
    still applies as written — it keys on `<PARENT-BRANCH>`, which you now
    have, and the report's header line names it. No track is determined on
    this path; the walk table below names its walk. **Step 2 runs, for this
    one sub-task only** — it is the only place a branch becomes a
    `prNumber`, which step 3a's first command needs.
    Step 6 re-renders the `M-SUBTASK-*` block 3d just emitted
    — the one exception to the template's "step 6 never selects them" rule,
    and the only outcome that describes this run truthfully — noting that
    only `<RUN-KEY>` was reviewed. It lands on `<PARENT-KEY>` like every
    run-level report, which is why 3e is skipped: that tally would post the
    same body to the same issue.

- **Resolve `<PARENT-BRANCH>`**: list branch names deduped to unique shorts
  — strip the markers and the `remotes/origin/` prefix so a branch that
  exists both locally and on origin counts once:

  ```bash
  git branch -a --list "*feature/<PARENT-KEY>-*" "*hotfix/<PARENT-KEY>-*" \
    | sed -E 's#^[+* ]+##; s#^remotes/origin/##' | sort -u
  ```

  `--list` with the trailing `-` anchors the key, so `<KEY>-2` never matches
  `<KEY>-25`; `[+* ]` strips both markers `git branch -a` emits — `*`
  (checked out here) and `+` (checked out in another linked worktree, the
  normal state of the parent branch while a sub-task's worktree runs this).
  Same rule as `pr_base.sh`'s branch search (§13, source 3), deliberately.

  Exactly one match → that's `<PARENT-BRANCH>`. Zero or multiple → ask the
  user rather than guessing.

- **Resolve `<BASE_BRANCH>`** — the base `<PARENT-BRANCH>` merges into — with
  §13's resolver, naming the branch and passing **no `--parent-key`**:

  ```bash
  S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/pr_base.ps1 on Windows
  OUT=$(bash "$S/pr_base.sh" --role reviewer --branch "<PARENT-BRANCH>" <PARENT-KEY>); RC=$?
  BASE_BRANCH=$(printf '%s\n' "$OUT" | sed -n 's/^base=//p')
  printf '%s\nBASE_BRANCH=%s (rc=%s)\n' "$OUT" "$BASE_BRANCH" "$RC"
  ```

  Both guard against one bug — `<BASE_BRANCH>` coming back as
  `<PARENT-BRANCH>`, so 5a opens a parent PR into itself. Without `--branch`
  the script keys on the current branch, which from a sub-task's worktree is
  the sub-task's (whose `parentbranch` *is* `<PARENT-BRANCH>`); with
  `--parent-key`, §13's parent-branch search matches `<PARENT-BRANCH>`
  itself, and the env default — the right last resort for a top-level issue —
  goes unreachable. (The sub-task-worktree path passes `--parent-key` only on
  its *other* call, the one resolving `<PARENT-BRANCH>`.) Branch config is
  shared, so naming the branch works from any worktree.

  Act on `source=`: `git-config` or `jira-comment` → proceed; `env-default`
  → proceed but flag it in the report; `unresolved` (exit 1) → ask the user.
  Then apply §13's prefix/base sanity check to the resolved pair: a
  `hotfix/` `<PARENT-BRANCH>` sitting on `<DEFAULT_BASE_BRANCH>` means the
  env default fired on a production fix, so the phase check below would hunt
  for the PR on the wrong base and 5a would open a duplicate into staging.
  Stop and ask which base is right.

- **Determine the track** from `fields.subtasks` (absent, `null`, or empty
  `[]` → **single-step**; anything else → **multistep**). This sets the
  run's **PR set** and the steps you will walk. Name the track explicitly so
  the rest of the skill reads as one track at a time:

  - **Single-step track** — the PR set is *just the one parent PR*
    (`<PARENT-BRANCH>` → `<BASE_BRANCH>`).
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
    to tell "still in flight" from "all merged".

**The walk**, once the track is named — three entry shapes, one table:

| you are in | PR set | walk |
| -- | -- | -- |
| parent's worktree, no sub-tasks (**single-step**) | the one parent PR (`<PARENT-BRANCH>` → `<BASE_BRANCH>`) — or, with member repos, one PR per member, then the landing PR | single-step phase check → 3 → 4c *(or 5L)* → 6 → 7 |
| parent's worktree, has sub-tasks (**multistep**) | each sub-task PR in `<STATUS_IN_REVIEW>` (→ `<PARENT-BRANCH>`) | multistep phase check → 2 → 3 → 4a *(all approved)* / 4b *(any rejected)* → 5 *(only when every sub-task is `<STATUS_DONE>`)* → 6 → 7 |
| a **sub-task's** worktree | that one sub-task's PR | 2 *(for this sub-task only)* → 3 → 6 → 7 |

### Reading PRs — `repos.sh`, never a hand-typed `gh pr list`

PRs come from two verbs, each covering every repo of the set (a single repo is
a set of one): `gate` for this issue's own branch — the phase checks below run
it — and `prs` for any other:

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/repos.ps1 on Windows
bash "$S/repos.sh" prs --branch "<other-branch>" [--state open]
```

`gate` prints `phase=`, `reason=`, `root=` (the PR from `<PARENT-BRANCH>` in the
root repo) and `members=`, then the PR rows; `prs` prints the rows alone. Every
row carries `slug`: pass it as `-R <slug>` to **every** `gh pr` command below.
**Statuscheck's `current_pr` row is not a substitute**: it sees the root repo
only, so on a project with member repos it misses every member PR. Don't
re-query by hand either — `gh` answers a filter that misses with `[]`, not an
error, so a narrowed query reads an open PR as none (JST-310); the script asks
the one exact query twice before it says `none`. A row in state `error` is
unknown, never none: stop and name the repo.

### Single-step phase check (only for the single-step track)

Run `gate` and act on its `phase=` — never on `current_pr`, which can't see
member repos:

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/repos.ps1 on Windows
bash "$S/repos.sh" gate --branch "<PARENT-BRANCH>" --base "<BASE_BRANCH>"
```

| phase | means | do |
| -- | -- | -- |
| `none` | no PR in any repo yet | report "`<PARENT-KEY>` has no PR yet — the reviewer runs once the executor opens one" and exit |
| `review` | the issue's PR is open — or, with member repos, member PRs are | step 3 on the OPEN rows (skip step 2) |
| `land` / `review-landing` | every member PR merged; the workspace's landing PR is missing / open | step 5L |
| `merged` | the issue's PR (or the landing PR) is merged | the step-6 report with S-MERGED (R-COMPLETE for a landing PR), then exit |
| `stop` | anything else — a CLOSED PR, an off-base one, a branch pushed with no PR, a `gh` error | relay `reason=` and ask; never read it as "no PR", never open a second one |

### Multistep phase check (only for the multistep track)

Run `gate` with `--multistep` and read its `root=` for the parent PR,
`<PARENT-BRANCH>` → `<BASE_BRANCH>`; `phase=stop` → relay `reason=` and ask:

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/repos.ps1 on Windows
bash "$S/repos.sh" gate --branch "<PARENT-BRANCH>" --base "<BASE_BRANCH>" --multistep
```

- **`root=none` — no parent PR exists yet** → split on the sub-task statuses step 1 just
  fetched, because "no parent PR" has two very different causes:
  - **Any sub-task not yet `<STATUS_DONE>`** → they are genuinely still in
    flight. Continue to step 2 for a full review pass.
  - **Every sub-task `<STATUS_DONE>`** → the merges have happened and only
    the parent PR is missing → skip to step 5, which creates it (5a) and
    reviews it (5b). This is where 4a's "merge them manually, then re-run"
    lands; reading it as "sub-tasks outstanding" strands the run, because
    step 2 finds zero open PRs and exits while step 5 is the only place the
    parent PR is ever created.
- **`root=open`** → split on the sub-task statuses, same
  as above: **every sub-task `<STATUS_DONE>`** → the merges have happened,
  skip straight to step 5 to review the parent PR. **Any sub-task not yet
  `<STATUS_DONE>`** → the parent PR was opened early; the sub-tasks are still
  the work, so continue to step 2 for a full review pass and leave the parent
  PR to a later run.
- **`root=merged`** → The user merged the aggregate PR
  manually: jump to the step-6 report with the M-FULLY-COMPLETE outcome and
  exit.

## 2. Discover open PRs for each In Review sub-task

*(Skipped on the single-step track, whose PR set is the parent PR itself. The
sub-task-worktree path runs it once, with `<RUN-KEY>` as the only
`<SUBTASK-KEY>` — see the walk table.)*

For each `<SUBTASK-KEY>` that passed the status filter:

- Find its branch with step 1's listing, with `<SUBTASK-KEY>` in place of
  `<PARENT-KEY>` in both `--list` patterns. If no branch exists yet, that
  sub-task hasn't been implemented — flag it in the report and skip it.
- Find the open PR: `repos.sh prs --branch <subtask-branch> --state open`
  (*Reading PRs*). `--state open` is deliberate: an already-merged sub-task
  PR is finished work, and it's the phase check that reads those. No OPEN
  row → flag and skip; several, or one whose base isn't `<PARENT-BRANCH>` →
  ask the user.
- Record: `{ key, branch, prNumber, prUrl, slug }`.

If **zero** sub-tasks have open PRs, report and exit — **except on the
multistep track**, where the phase check's split applies first: every
sub-task `<STATUS_DONE>` means the PRs are merged and only the parent PR is
missing → go to step 5. The sub-task-worktree path has no track and no step
5 on its walk.

Read *The canonical review report* below before the first verdict lands in
3d.

## The canonical review report

Every report-shaped output this skill emits (3d, 3e, 5b, 6) is **one and the
same report**, so a person following the review across GitHub, Jira, and chat
sees one layout. The template, its `<VERDICT-HEADER>` rules, and the ten
outcome blocks live in **`../_shared/templates/review-report.md`** — read it
once before your first emission (normally 3d; 5b or 6 if this run skips the
review loop), then fill it rather than composing a shape of your own.

Two things from it are load-bearing enough to state here as well:

- The body's literal first line is `APPROVED — <summary>` or `CHANGES REQUESTED — <summary>`. On GitHub comments that prefix is a byte-for-byte
  contract — 3a's idempotency check matches on it, so rewording the two-word
  prefix or the `—` separator silently breaks re-run detection.
- The already-merged outcomes (S-MERGED, M-FULLY-COMPLETE) end their run at
  the step-6 report: no wrap-up comment, and no further action expected on
  the issue — GitHub-for-Jira already moved it to `<STATUS_DONE>`.

## 3. Sequential per-PR review loop

Iterate through **the PR set** (step 1's walk table names it per entry shape)
in ascending key order. Treat each PR individually — do not hold results for
a batch. The loop body below is the same for every PR in the set regardless
of track.

Resolve this skill's GitHub identity **once, before the loop**, and
**substitute the value literally** as `<SELF>` in 3a — never a shell
variable: each Bash call is a fresh shell, and an unexpanded `$SELF` makes the
jq filter `== ""`, so 3a silently reports "not reviewed yet" forever.

```bash
gh api user --jq .login    # -> <SELF>, e.g. task-executor-bot
```

If this errors, gh isn't installed or authenticated: see *Edge cases*.

### 3a. Check idempotency — already reviewed by me?

Before reviewing a PR, check whether **this skill's GitHub identity**
(`<SELF>`, resolved once before the loop above) has already left a verdict
comment on it:

```bash
gh pr view <prNumber> -R <slug> --json reviews --jq '.reviews[] | select(.author.login == "<SELF>") | .body'
```

Take the **most recent** self-review body (they come back in chronological
order) — a later verdict supersedes an earlier one, which is what makes an
approve→regression→reject sequence readable:

- **Most recent starts `APPROVED —`** → already approved. Report the PR as
  "already approved — waiting for manual merge" and move to the next PR
  without re-reviewing — **unless `$ARGUMENTS` asks for a re-review**, which
  is the manual override for exactly this case; then continue to 3b.
- **Most recent starts `CHANGES REQUESTED —`** → re-review: this is a
  fix-and-re-run scenario, and fresh code may have been pushed since.
  Continue to 3b.
- **No prior review body from `<SELF>`** → continue to 3b.

Match on author **and body prefix**, never review `state`: both verdicts land
as comments (3d/5b), so this identity leaves no `APPROVED`/`CHANGES_REQUESTED`
review state to key on.

### 3b. Fetch the diff

```bash
gh pr diff <prNumber> -R <slug>
```

Read the full diff. If it's very large (>1000 lines), list changed files via
`gh pr diff <prNumber> -R <slug> --name-only` and `Read` relevant files for
context — a member PR's files sit under that member's folder in this
worktree. Do not skip any file in the diff.

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
7. **Consistency across the set** — only when the set spans member repos.
   An interface one PR changes (an API field, a CLI flag, an event name, a
   shared constant) is matched by the PR on the other side — the project's
   docs say which interfaces cross repos — and no repo the change needs is
   missing. Decide the merge order (what's depended on merges first) and
   state it in the report.

### 3d. Execute verdict immediately

Record the verdict as a **review comment** — both verdicts go through `gh pr review <prNumber> -R <slug> --comment --body-file`: in this plugin's default
deployment the executor and reviewer share one `gh` account, and GitHub's
self-review restriction blocks an author from approving *or* requesting
changes on their own PR, so neither verdict can use a state-based review. The
Jira transition to `<STATUS_IN_PROGRESS>` (on the reject path) is the actual
workflow gate; the GitHub comment only records the verdict and makes it
detectable by 3a.

Both the GitHub verdict comment and the Jira per-issue comment carry the
**full canonical review report** (see *The canonical review report* above),
scoped to this one PR — not a terse one-liner. Write **one** report body to a
temp file and post that same file to both destinations, so GitHub and Jira
read identically.

**Post the Jira half only on a sub-task PR**, where 3d lands on
`<SUBTASK-KEY>` and step 6 on `<PARENT-KEY>`. Otherwise both land on
`<PARENT-KEY>` and step 6's report covers this PR: post the GitHub comment
(and, on the reject path, the transition — a gate, not a report) and let step
6 be the single Jira record.

- **If APPROVE (all dimensions pass):** fill the canonical template with the
  per-PR approve outcome **for this kind of PR** — **S-APPROVED** for the
  single-step parent PR, **R-MEMBER-APPROVED** for a member repo's PR,
  **M-SUBTASK-APPROVED** for a sub-task PR (the multistep loop, or the
  sub-task-worktree path of step 1; the template says why they differ). Set `### Verdict recorded` → GitHub: APPROVED comment on
  PR #<n>; Jira: note posted (or "—" when the rule above skips it), status
  not moved. Verdict-header line `APPROVED — <one-line summary>`:

  ```bash
  S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
  cat > /tmp/<KEY>-report.md <<'EOF'
  APPROVED — <one-line summary>

  ## Review Status: ...        # the full canonical report, scoped to this PR
  EOF
  gh pr review <prNumber> -R <slug> --comment --body-file /tmp/<KEY>-report.md
  bash "$S/jira.sh" --role reviewer issue comment add <SUBTASK-KEY> --body-file /tmp/<KEY>-report.md   # sub-task PRs only — see above
  ```

  Don't move the Jira status *here* — mid-loop
  the PR is only approved, not merged. Step 7 offers the user the
  `<STATUS_DONE>` move once at the end of the run; declining it leaves the
  issue to the GitHub-for-Jira merge automation.

- **If REQUEST_CHANGES (one or more dimensions fail):** fill the same
  canonical template with the per-PR reject outcome **for this kind of PR** —
  **S-CHANGES-REQUESTED** when this is the single-step parent PR,
  **R-MEMBER-CHANGES-REQUESTED** for a member repo's PR,
  **M-SUBTASK-CHANGES-REQUESTED** when this is a sub-task PR — and
  verdict-header line `CHANGES REQUESTED — <one-line summary>`; the
  `file:line` findings for each failed dimension go in the report's `### What I reviewed` section (never dropped). Post the one body per the rule
  above, then transition the issue back to `<STATUS_IN_PROGRESS>` — that
  transition is the actual gate and fires on both tracks:

  ```bash
  S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
  cat > /tmp/<KEY>-report.md <<'EOF'
  CHANGES REQUESTED — <one-line summary>

  ## Review Status: ...        # the full canonical report, incl. file:line findings
  EOF
  gh pr review <prNumber> -R <slug> --comment --body-file /tmp/<KEY>-report.md
  bash "$S/jira.sh" --role reviewer issue comment add <SUBTASK-KEY> --body-file /tmp/<KEY>-report.md   # sub-task PRs only — see above
  bash "$S/jira.sh" --role reviewer issue transition <SUBTASK-KEY-or-PARENT-KEY> --to "<STATUS_IN_PROGRESS>"
  ```

  Remember this PR as blocked. Continue the loop — review the next PR.

### 3e. Post a summary on the parent after each sub-task

*(Multistep track only. The single-step track has no sub-tasks to tally; the
sub-task-worktree path skips it because step 6's run-level report already
lands on `<PARENT-KEY>` carrying this same body.)*

Whatever the verdict, immediately post 3d's `/tmp/<KEY>-report.md` — the
canonical report, scoped to the sub-task — to `<PARENT-KEY>` too, so progress
is visible. A **fresh comment per sub-task is intentional** (the template's
*One run-level render per run*), so never `-e/--edit-last`:

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
bash "$S/jira.sh" --role reviewer issue comment add <PARENT-KEY> --body-file /tmp/<KEY>-report.md
```

## 4. After the PR set has been reviewed (loop complete)

Once step 3 has processed every PR in the set, the run ends with a report
**even if some were rejected**; the human fixes and re-runs, and a later run
picks up only what's back in `<STATUS_IN_REVIEW>`.

The post-loop outcome is mutually exclusive; the walk table picks which of
4a/4b/4c applies, and step 6 posts the written report keyed to the same
label.

### 4a. *(Multistep)* All approved — merge and re-run

1. Check if **all** of those PRs are already merged (`gh pr view <prNumber> -R <slug> --json state` for each).
2. **If some are still open** → outcome **M-ALL-APPROVED**: tell the user its
   `Next step` wording from the template — merge them manually, then re-run.
   (Step 6 posts the written report to Jira.)
3. **If all are merged** → apply the phase check's test before continuing:
   every sub-task `<STATUS_DONE>` → proceed to step 5 (parent PR handling).
   Any sub-task not yet `<STATUS_DONE>` — still in progress, or skipped by
   step 2 for having no branch or no PR — → **stay on M-ALL-APPROVED** and go
   to step 6. The PR set only ever contained the sub-tasks that were in
   `<STATUS_IN_REVIEW>` at step 1, so "every PR in the set is merged" is not
   the same claim as "the feature is complete", and step 5 would open an
   aggregate PR missing the outstanding work.

### 4b. *(Multistep)* Some rejected — report and stop

1. **Do not** proceed to the parent PR, regardless of how many other
   sub-tasks were approved.
2. Outcome **M-SOME-BLOCKED**: its `Next step` wording tells the human to fix
   the rejected sub-tasks and re-run once the executor has moved them back to
   `<STATUS_IN_REVIEW>`. (Step 6 lists **both** approved and rejected items +
   the file:line findings in the Jira report.)
3. Skip step 5 and go to step 6; step 7 has nothing to offer if nothing was
   approved.

### 4c. *(Single-step)* PR reviewed — wait for merge

After the PR is reviewed in step 3:
**approved** → outcome **S-APPROVED**; **changes requested** → outcome
**S-CHANGES-REQUESTED**. With member PRs instead: every one approved →
**R-MEMBERS-APPROVED** (its `Next step` carries the merge order); any
rejected → **M-SOME-BLOCKED**. Tell the user that outcome's `Next step`
wording from the template rather than composing your own.

## 5. Parent PR management

*(Multistep track only — runs when all sub-task PRs are merged into
`<PARENT-BRANCH>`, whether merged in a prior run or before this one.)*

### 5a. Find or create the parent PR

Use the phase check's `root=` — still current, since this run has opened no
PR. Re-querying by hand is how 5a once missed an off-base parent PR and nearly
opened a *second* one (JST-286).

- **`root=none`** → create one (write the body to a temp file — see the
  body mechanics in the preamble). The sub-task PR URLs come from
  step 2's records; when the phase check jumped straight here, step 2 never
  ran — list the sub-task keys and resolve each URL with `repos.sh prs --branch <subtask-branch>`, or omit the
  URLs rather than inventing them:
  ```bash
  cat > /tmp/<PARENT-KEY>-pr-body.md <<'EOF'
  Aggregate PR for <PARENT-KEY>.

  Sub-tasks merged:
  - <SUBTASK-KEY>: <PR URL>
  - ...
  EOF
  gh pr create -R <slug> --base <BASE_BRANCH> --head <PARENT-BRANCH> \   # the root row's slug
    --title "<PARENT-KEY>: <summary>" \
    --body-file /tmp/<PARENT-KEY>-pr-body.md
  ```
- **`root=open`** → use it.
- **`root=merged`** → the user already merged the aggregate PR: report it
  via the step-6 report with the M-FULLY-COMPLETE outcome and exit.

### 5b. Review the parent PR (apply the 3a idempotency check first)

Resolve `<SELF>` now if step 3 never ran (the all-sub-tasks-merged path and
5L land here directly): `gh api user --jq .login`, substituted literally (an
error → *Edge cases*). Then apply the **3a body-prefix idempotency check**: a prior self-review whose
body starts `APPROVED —` → report "Parent PR already reviewed — waiting for
manual merge" and skip; one starting `CHANGES REQUESTED —` → re-review the
fresh aggregate code. Otherwise:

1. Check the PR is mergeable — `gh pr view <prNumber> -R <slug> --json mergeable,mergeStateStatus`. `CONFLICTING` means `<PARENT-BRANCH>` has
   fallen behind `<BASE_BRANCH>`: stop and report, since a diff that can't
   merge gives the user nothing to act on. This is the only detection path
   the *parent branch is behind its base* edge case has.
2. Review the aggregate diff: same criteria as 3c, but lighter. The
   sub-tasks were already reviewed individually — focus on integration
   issues, conflicts, and anything that only surfaces when the pieces
   combine.
3. **If approved** → outcome **M-PARENT-READY**: post the **full canonical
   review report** (see *The canonical review report* above), scoped to the
   parent PR, with verdict-header line `APPROVED — <lighter aggregate summary>` as the literal first line — `gh pr review <prNumber> -R <slug> --comment --body-file /tmp/<PARENT-KEY>-report.md` (the same body/mechanics as 3d,
   just the aggregate PR). Do NOT merge. Tell the user the parent PR is
   approved and awaiting their manual merge; step 6 posts the run-level
   report.
4. **If changes requested** → outcome **M-PARENT-CHANGES-REQUESTED**: post
   the same canonical report with verdict-header line `CHANGES REQUESTED — <one-line summary>`, the integration `file:line` findings in its `### What I reviewed` section, via `gh pr review <prNumber> -R <slug> --comment --body-file`. Then go to step 6.

### 5L. Land the member PRs, then review the landing PR

*(Single-step, on `gate`'s `land` or `review-landing`.)* The member PRs are
merged; the workspace's gitlinks still point at the old commits. On `land`,
run `land`: it moves each gitlink to its PR's merged commit, commits, pushes
and opens the landing PR, checking everything first. `error=` → relay it and
stop.

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/repos.ps1 on Windows
bash "$S/repos.sh" land --branch "<PARENT-BRANCH>" --base "<BASE_BRANCH>"           # on `land` only
bash "$S/repos.sh" land --check --branch "<PARENT-BRANCH>" --base "<BASE_BRANCH>"
```

Then review the landing PR (its row in `gate`, or `land`'s `pr=`) as 5b does,
3a's idempotency check first. Its diff is gitlinks only, so the review is
`land --check`: every row `ok` → **R-LANDING-READY**; any failing row →
**R-LANDING-CHANGES-REQUESTED**, that row being the finding.

## 6. Report back

Post the review summary to the user in chat **and** as a single Jira comment
on `<PARENT-KEY>` via the §11 `--body-file` convention (`jira.sh --role reviewer issue comment add <PARENT-KEY> --body-file <file>`). This is the
**run-level** render of *The canonical review report* (defined above): the
*whole run's* PR set in its `### Pull Request Summary`, and a verdict header
carrying the run's overall verdict (`CHANGES REQUESTED — …` if any PR was
rejected, else `APPROVED — …`). Fill the template; don't re-spell its shape.

Pick **exactly one** outcome from the catalogue in
`../_shared/templates/review-report.md` — chosen by the step-1 track × the
current phase (decided in step 4, or detected in step 1/5/6). Use its
**run-level** blocks — the `S-*` ones on the single-step track (`R-*` when
its set spans member repos), the `M-*` ones on the multistep track. The two `M-SUBTASK-*` blocks belong to the 3d/3e
per-PR emissions and are never this report's pick — except on the
sub-task-worktree path, where the run's whole PR set *is* that one sub-task
PR.

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

Ask rather than decide: this skill never merges, so every PR you just
approved is still open. Teams whose Done means "merged" get there by
automation, and moving the card here jumps ahead of it; teams that close at
approval want exactly this — and nothing in the repo says which kind this is.
Declined, or no answer → change nothing: approved-but-open is the safe
resting state, and a later re-run detects the merge on its own.

Which issues to name:

- **Single-step** — `<PARENT-KEY>`, on S-APPROVED, or with member repos on
  R-LANDING-READY only: approved member PRs haven't landed yet.
- **Sub-task worktree** (step 1's `Subtask` branch) — just `<RUN-KEY>`, when
  3d approved it. Never `<PARENT-KEY>`: that run reviewed one sub-task PR and
  looked at nothing else.
- **Multistep** — every sub-task approved in this run, plus any 3a reported
  as already approved, plus `<PARENT-KEY>` itself when 5b approved the parent
  PR (M-PARENT-READY). On M-SOME-BLOCKED offer only the approved subset.
- **Already merged** (S-MERGED, M-FULLY-COMPLETE, R-COMPLETE) — skip the question
  entirely; those issues are Done already.

Post nothing further to Jira here. The step-6 report is the run's single
final comment and it recorded the review verdict, which a closure after the
fact doesn't change — so don't edit or re-post it. Report what moved in chat
instead.

## Edge cases

- **Sub-tasks exist, none in review / one without a branch or PR** → report
  it; the user re-runs later. Never create branches or PRs for them — that's
  the executor's job (5a's parent PR and 5L's landing PR are the reviewer's).
- **A review (or approval) from someone else**: the skill always does its
  own review — an existing review by another account doesn't skip the
  code-review step. The 3a idempotency check only looks at *this skill's
  own* prior comments, keyed on `<SELF>`'s login + body prefix.
- **`gh` missing or logged out** → step 3's identity resolution fails:
  report the error and hand the user the PR URLs.

Reference: `../_shared/jira-api-reference.md` is the operational + REST
reference — the `jira.sh` command surface, confirmed issue types, and
git/branch conventions this skill depends on. The `.jst/jira-sdlc-tools.env`
(team-shared) and `.jst/jira-sdlc-tools.local.env` (machine-specific) files
under the project root have this repo's specific values for every `<TOKEN>`
used above.
