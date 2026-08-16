---
name: jira-task-executor
description: Implements the Jira issue whose worktree you are standing in — branch, status transition, investigation, implementation, tests, commit, push, PR — and reports the PR link and new status. Run it bare from inside the issue's own worktree (created by jira-task-assigner); the issue key comes from the branch name, never from an argument. Re-run it the same way after a review rejects the PR — it reads the reviewer's findings from the issue and updates the existing PR instead of opening a second one. Any argument you pass is treated as free-form notes for this run.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, AskUserQuestion
---

You are acting as the engineer picking up a single Jira issue end-to-end.
Run this from inside the issue's own worktree — no issue-key argument;
the issue key is derived from the current branch (see Discovery below).

**Conventions used below:**

- `<KEY>` = the issue key from Discovery's `issue_key` row, parsed off the
  branch (`feature/<KEY>-<slug>` / `hotfix/<KEY>-<slug>`).
- `$ARGUMENTS`, when non-empty, is free-form notes about this run
  (constraints, focus areas, context) — never parsed as an issue key.
  Fold it into steps 4–6 alongside the issue description, which it
  supplements rather than replaces.
- **`CLAUDE_PLUGIN_ROOT`** is this plugin's root, and every script path below
  hangs off it. Unset (a non-Claude client) → resolve it from this skill's own
  directory instead, which puts the scripts at `../_shared/scripts/posix/`
  relative to it on every platform. If even that isn't derivable, the
  platform-by-platform skills locations are in
  [INTEGRATIONS.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/INTEGRATIONS.md)
  → "Locating the shared scripts".
- **Jira access is the `jira.sh` / `jira.ps1` client, not a global CLI.** It
  lives at `$S/jira.sh` (POSIX) / the `win/jira.ps1` port (Windows), where `S`
  is the scripts dir set in the credential block below. The steps write Jira
  calls as `jira.sh <cmd>` for brevity — actually invoke it as
  `bash "$S/jira.sh" <cmd>` (POSIX) / `pwsh …/win/jira.ps1 <cmd>` (Windows),
  re-setting `S` at the top of each shell block that needs it — an unset `S`
  silently becomes `bash "/jira.sh"`. It authenticates **per-request as
  `--role executor`** (`../_shared/jira-api-reference.md` §9).
- **Jira comment mechanics**: comments are written to a temp file and posted
  with `jira.sh --role executor issue comment add <KEY> --body-file <file>`.
  There is no inline-body form — the body always comes from a file, so backticks
  in it are never at risk of shell substitution; `jira.sh` stores plain text as
  ADF (one paragraph per non-blank line). See
  `../_shared/jira-api-reference.md` §11.
- **Task memory (Jira comments as durable per-task memory)**: the issue's
  Jira comments are this task's long-term memory across sessions — step 4
  reads what earlier runs left, step 6 records what this one learns, so a
  later run recovering or reimplementing this issue inherits the context
  instead of starting cold. Every memory comment begins with the marker line
  `Task memory (jira-task-executor)`, which keeps it greppable and distinct
  from the assigner's `Assignment report`, the `PR target branch:` comment
  and the final run report (step 12).
  **Routing**: durable or architectural decisions belong in the code docs
  (README / CLAUDE.md / AGENTS.md / inline) — a memory comment is a pointer
  for the next session, not a permanent home for design the codebase owns.
- `<STATUS_*>` resolve from `.jst/jira-sdlc-tools.env` — the team-shared,
  committed, secret-free file, and the only one those names live in; it
  carries this project's confirmed status names. Every
  other `<TOKEN>` comes off the Discovery healthcheck's rows. **Never dump
  `.jst/jira-sdlc-tools.local.env`**: it holds all three role Jira API
  tokens and the GitHub PAT (`../_shared/project-config.md` § *Reading
  config safely*).

**Script dispatch — settle this before running any script below.** Every
script this skill invokes ships twice: the POSIX `…/scripts/X.sh` and its
Windows twin `…/scripts/win/X.ps1` (PowerShell 5.1+; identical args, output,
exit codes). Pick the branch from your own runtime *before the first call* —
you know your OS without running anything — and use it for every script
here, credential block included; the blocks below are the POSIX form.
Statuscheck's `platform` row only *confirms* that choice afterwards, so it
can't decide how statuscheck itself is run.

**Get local credentials and confirm you own the issue — run these FIRST,
before the healthcheck.** Both are idempotent and take no decisions of their
own; a non-zero exit from either means **STOP** — relay its stderr verbatim and
do not transition status, branch, commit, comment, or work the issue. There is
no "become the executor" login step: `jira.sh` authenticates per-request as
`--role executor`, so ownership is *confirmed* here, not *assumed* by switching
a global account.

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"
bash "$S/ensure_local_env.sh"                || exit 1   # 1. worktree gets local.env if it's missing
bash "$S/check_assignee.sh" --role executor  || exit 1   # 2. <KEY> must be assigned to the executor
```

(`check_assignee.sh` resolves the executor identity via
`jira.sh --role executor whoami` and takes the key from the branch, as the
healthcheck does.)

**Discovery and healthcheck — run before step 1.** The rest of this skill
transitions Jira status, commits, pushes and opens a PR, all of which assume
the right starting point and working credentials; finding a busted
environment mid-flow (a logged-out `gh` failing at step 10, *after* the
implementation is written and pushed) wastes the run and can leave commits on
the wrong branch. One script bundles every check. Send it as the only tool
call in its message, because its rows decide whether the next step happens at
all — anything batched alongside it has already run before that decision
existed:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role executor
```

`--role executor` is required (there is no default credential) and no issue-key
argument is passed: the branch is the only source of the key.

It resolves `<PROJECT-KEY>` and `<DEFAULT_BASE_BRANCH>` from the env files
itself, so you don't pre-resolve tokens for this section, and prints one
markdown table (`check | status | detail`) — `OK`, `FAIL` (blocks, with a
remedy line printed under the table), `WARN` (suspicious, not blocking),
`INFO` (context only) — exiting non-zero if any row is `FAIL`.

Only the rows this skill reads in a role-specific way, or relies on later,
are spelled out here; the rest are role-independent preconditions defined
in `statuscheck.sh` itself (their `detail` column is self-explanatory in
the printed output — that live output, not this table, is what the skill
actually acts on). The first two are INFO for every role because the script
leaves that judgement to each skill; **for the executor they are stop
conditions, decided in the rows themselves — there is no second reading
note below**:

| row | what it verifies / gathers |
| -- | -- |
| `worktree` | INFO: *linked worktree* (`.git` is a file) vs. *main checkout* (`.git` is a directory). **Anything but a linked worktree → stop**: this skill runs only from an issue's own worktree. `cd` into the one `jira-task-assigner` created (`worktree-<KEY>`) and rerun |
| `branch` | INFO: base branch vs. `feature/*`/`hotfix/*` issue branch (`../_shared/jira-api-reference.md` §12) vs. neither. **Anything but an issue branch → stop** (same remedy) — sitting on `<DEFAULT_BASE_BRANCH>` means you're not in an issue's worktree |
| `issue_key` | the key derived from the branch name — becomes `<KEY>` for the rest of the run |
| `parent_branch` | INFO: `git config branch.<branch>.parentbranch` — consumed by step 2's stale-branch merge (step 10's resolver reads it for itself) |
| `production_branch` | INFO: `<PRODUCTION_BRANCH>` — this skill's only source for it, consumed by step 10's prefix/base sanity check |
| `bootstrap` | INFO either way: whether this project ships an optional `.jst/bootstrap.sh` (POSIX) / `.jst/bootstrap.ps1` (Windows). Present → step 1 runs it; absent → nothing to do, and most projects won't have one |
| `jira_account_url` | INFO: `<JIRA_ACCOUNT_URL>` — step 10 builds the PR body's issue link from it, so it never has to open the credential-bearing `.jst/jira-sdlc-tools.local.env` |

Two of those other rows matter later: `gh_auth` and `gh_repo_access` together
are what step 10's `gh pr create` depends on (a login *and* a PAT that can see
this repo), so a FAIL there is not a problem to discover at step 10.

Reading the result: **Any FAIL row** → stop, relay the script's remedy
line to the user, and wait — don't try to re-create worktrees, switch
branches, or re-auth CLIs yourself; the executor doesn't self-repair its
own preconditions.

Otherwise the `issue_key` row's derived key is `<KEY>` for the rest of this
run. Before your first call after the healthcheck, state what each of the rows
above read (a message batched with the healthcheck can't: the values don't
exist yet). Then continue to step 1, carrying the INFO rows forward as
context.

01. **Run the project's bootstrap hook, then fetch the issue.**

    **1a. Bootstrap the worktree** — only if Discovery's `bootstrap` row read
    *present*. A worktree is a source tree, not a running instance; this hook is
    how a project closes that gap (clone the database, pick per-instance ports,
    install deps). Run it from the worktree root, **automatically — no
    confirmation prompt** — passing the `JST_*` contract
    (`../_shared/project-config.md` § *the optional worktree hook* defines every
    variable):

    ```bash
    cd "$(git rev-parse --show-toplevel)"
    JST_ISSUE_KEY=<KEY> JST_WORKTREE_DIR="$PWD" JST_BRANCH="$(git branch --show-current)" \
    JST_PARENT_BRANCH="<parent_branch row, empty when unset>" JST_PROJECT_KEY="<PROJECT-KEY>" \
      bash .jst/bootstrap.sh; echo "bootstrap exit: $?"
    ```

    (Windows: set the same five as `$env:JST_*`, then
    `pwsh -NoProfile -File .jst\bootstrap.ps1`.)
    **Fail-soft, always**: report a non-zero exit and its output in your final
    report, then carry on with the issue — a broken hook is the project's
    environment problem, not a reason to abandon work the executor can still do.
    Absent row → say nothing and go straight to 1b. Re-runs re-invoke the hook
    by design; tolerating that is the script's job, not yours.

    **1b. Fetch the issue** —

    ```bash
    jira.sh --role executor issue view <KEY> \
      --fields 'summary,description,issuetype,status,parent,subtasks,comment'
    ```

    Reads print raw JSON on stdout. The field list's source of truth is
    `../_shared/jira-api-reference.md` §10 — resolve there rather than here if
    the two ever disagree — and it's sized to everything this skill reads,
    including `comment` (scanned in step 4). Pull out: summary, description,
    current status (steps 3 and 11 branch on it) and `fields.parent.key` if
    present — store it as `PARENT_KEY`, which step 10's base resolver and step
    11's routing both read.

    - Also check `fields.subtasks` (§10's canonical list names it explicitly,
      so the narrowed payload keeps it):
      - **Non-empty** → `<KEY>` is a parent: a merge target for its
        sub-tasks' PRs, not an implementation surface. Implementing here
        shadows the separate PRs those sub-tasks target at this same branch
        and breaks the "every leaf gets its own PR" invariant. Confirm with
        the user before continuing — not on a "this one's small" call.
      - **Empty** → `<KEY>` is a leaf: a sub-task, or a single-step top-level
        issue the assigner provisioned for direct implementation. Proceed.

02. **Bring the worktree branch current.** Discovery already guaranteed you're
    on `<KEY>`'s own issue branch inside its own linked worktree, so there is
    nothing to locate or create here. (An issue with no branch/worktree yet is
    provisioned *before* this skill runs, by `../_shared/jira-api-reference.md`
    §12's no-assigner recipe.)
    What the branch *can* be is **stale**: the branch it was created from may
    have moved since — most commonly a sibling sub-task's PR merging into the
    shared parent. Read the parent from Discovery's `parent_branch` row rather
    than re-running the `git config` lookup.

    - **Set** → merge the parent's *remote* state — merging the local ref
      would silently miss anything that landed on origin after this
      worktree was created. A never-pushed parent has no remote ref, and
      `git merge origin/…` then fails with an unknown-revision error that
      reads like a broken repo, so decide which ref to merge rather than
      guessing:
      ```bash
      git fetch origin
      if git rev-parse --verify --quiet origin/<parent-branch> >/dev/null; then
        git merge origin/<parent-branch> --no-edit
      else
        git merge <parent-branch> --no-edit   # never pushed — no remote ref to merge
      fi
      ```
      If the merge conflicts, stop and ask the user to resolve — don't
      attempt to resolve merge conflicts automatically.
    - **Unset** (the branch predates the parentbranch convention, or
      wasn't created by the assigner) → skip the merge, but flag in the
      final report that you proceeded on a possibly-stale worktree branch.
      Don't stop to ask which branch the PR should target — step 10's
      resolver handles an unset parentbranch (Jira comment, then env
      default).

03. **Transition the issue to `<STATUS_IN_PROGRESS>`** — unless step 1b's
    `status` already reads it, which is the normal state on a re-run after a
    reject (the reviewer put it back there). Workflows generally offer no
    transition into the status an issue already occupies, so asking anyway
    exits 8, and `jira-api-reference.md` §9's "non-zero is a stop condition"
    would abort the re-run
    before step 4 ever reads the reviewer's findings. Already there → note it
    and continue.

    `jira.sh --role executor issue transition <KEY> --to "<STATUS_IN_PROGRESS>"`
    (by target status *name*; `jira.sh` resolves it to the id).

04. **Investigate** — read the affected code (Grep/Read/Glob) before
    writing anything. Understand existing patterns, not just the issue text.
    Read the issue's prior comments first — step 1's fetch already includes
    `fields.comment.comments` — so you inherit earlier context instead of
    rediscovering it cold, in this order of authority:

    - **A reviewer verdict whose body starts `CHANGES REQUESTED — `**, if
      present. On the re-run after a reject (step 11) it outranks everything
      else here: its per-dimension `file:line` findings *are* the
      specification for this pass, and a run that ignores them gets rejected
      again. That prefix is the reviewer's own detection contract, kept
      verbatim, so matching on it is stable.
    - **The assigner's `Assignment report`** — how this issue was scoped.
    - **Any `Task memory (jira-task-executor)` notes** an earlier session
      left — on a re-run, how you avoid repeating its dead ends.
    - **The previous run report** (step 12), which deliberately carries no
      marker: find it by position — the most recent long comment that isn't
      one of the above — not by grepping a prefix.

05. **Clarify** — if the issue's description/acceptance criteria leaves
    something materially ambiguous (an implementation choice that would
    change the result), ask the user before writing code. Don't guess on
    anything that matters. Step 3's transition stands while you wait —
    someone *has* picked the issue up — so don't roll it back to
    `<STATUS_TODO>` even if the answer never comes.

06. **Implement** the change.

    - **Record task memory as you go — but only when it's worth preserving.**
      Post a `Task memory (jira-task-executor)` comment (per the Task-memory
      preamble bullet) when you learn something a later session would
      otherwise rediscover: a finding, a design decision *and its rationale*,
      a gotcha in already-touched code, recovery context. This is
      task-recovery memory, **not** running commentary — skip the trivial and
      self-evident, and one note at the end is enough if it captures
      everything worth keeping. The first can surface as early as step 4.

07. **Test before committing:**

    - **7a. Find this project's test commands.** Which runner a project
      uses, how it selects a single test, and how it runs the whole suite
      all vary too much to ship a plugin default. Look for `CLAUDE.md`,
      `AGENTS.md`, a "Tests" section in `README.md`, or similar in the
      repo root.

      - **Both forms documented** (run a single test, run the full suite) →
        use those commands throughout the rest of this step.
      - **The repo has tests, but the commands are missing or half-documented**
        — the common case: CI runs them and no `CLAUDE.md` line says how, or
        the docs give the full-suite command and nothing for selecting one
        test → recover the missing form(s) from `package.json` scripts,
        `Makefile` targets, README sections and CI config, and sanity-check
        each candidate (`--listTests`, a dry run, one trivial pass) before
        relying on it. **Suggest** — don't silently edit — that the user add
        the two resulting commands to `CLAUDE.md` / `AGENTS.md`.
      - **The repo has no test layer at all** → ask whether to install a runner
        and the testing dependencies now. That is its own task; don't decide it
        on their behalf.
        - Yes → once it's in, fold the "run one test" / "run full suite"
          commands into `CLAUDE.md` / `AGENTS.md` so the next session doesn't
          re-derive them.
        - No → skip the rest of this step, note in the final report that
          testing was skipped and why, and continue to step 8 (commit).

    - **7b. Run tests for this change.** If test coverage exists already,
      identify the affected tests; if it doesn't, add the new test(s) to
      the relevant suite file first. Run each new/affected test
      individually, one at a time — don't move on until the current one
      passes. Use the project's documented single-test command; if its
      exact form doesn't fit your runner, adapt it (filter by name or
      pattern) — the policy matters more than the exact invocation. Once
      every individual test passes,
      run the whole affected suite to catch regressions.

    - **7c. Handle suite-level failures.** If the full suite run reports
      failures, don't treat that as final — timing/flakiness can fail a
      test that's actually fine on its own. Re-run just the failed tests
      individually (not the whole suite again):

      - If they pass individually → treat the suite as passing overall.
        Don't re-run the whole suite a second time.
      - If an individually re-run test fails again → stop. Report the
        failure and wait for instructions — don't commit, push, or open a
        PR, and don't keep retrying on your own.

08. **Commit** — stage the files this change touched explicitly
    (`git add <file>…`, not `-A`, which can sweep in strays), then
    `git commit -m "<KEY> <short message>"`. Split into multiple commits
    if the change has logically separate pieces; one is fine for a small
    change.

09. **Push** — `git push -u origin <branch-name>`.

10. **Open the PR — or update the one that's already open:**

    - **Check for an existing PR first.** After a reject (step 11) this skill
      re-runs on a branch that already has one, step 9's push has already
      updated it, and `gh pr create` would fail with "a pull request already
      exists":
      ```bash
      gh pr list --head "$(git branch --show-current)" --state open \
        --json number,url --jq '.[] | "\(.number) \(.url)"' | head -1
      ```
      - **Non-empty** → that PR now carries this run's commits. Don't create a
        second one, and don't resolve a base — an open PR's base isn't this
        run's decision. Write what changed to `/tmp/<KEY>-fix-summary.md`
        (`cat > … <<'EOF'`) and post it with
        `gh pr comment <number> --body-file …`, so the reviewer's next pass
        sees the fix instead of re-reading the whole diff. Carry that PR's
        link into steps 11 and 12.
      - **Empty** → resolve the base and create the PR, below.
    - Resolve the PR base with `pr_base.sh`, which *is*
      `../_shared/jira-api-reference.md` §13 (git config → the Jira
      `PR target branch:` comment → a parent-branch search for sub-tasks → the
      env default for top-level issues only). Passing step 1's `PARENT_KEY`
      is what keeps a sub-task from defaulting to the env base:
      ```bash
      S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/pr_base.ps1 on Windows
      OUT=$(bash "$S/pr_base.sh" --role executor \
              --parent-key "<PARENT_KEY, empty for a top-level issue>"); RC=$?
      PR_BASE=$(printf '%s\n' "$OUT" | sed -n 's/^base=//p')
      printf '%s (rc=%s)\n' "$OUT" "$RC"
      ```
      It prints `base=` and `source=` and exits non-zero when unresolved. Act
      on that before touching `gh pr create`:
      - **`source=unresolved`** (exit 1) — a sub-task whose parent-branch
        search matched zero or several branches. **Stop and ask the user which
        branch is the base.** Don't open the PR, and don't substitute
        `<DEFAULT_BASE_BRANCH>`: a sub-task's base is its parent's branch, and
        silently defaulting is the bug this resolver exists to prevent.
      - **`source=branch-search`** — the two recorded sources were both empty
        and the base was recovered by searching. Proceed, and name the branch
        explicitly in the final report.
      - **`source=env-default`** — top-level issues only. Proceed, and say so
        explicitly in the final report.
      - **Prefix and base disagree** (top-level issues only — the §13 sanity
        check): you're on `hotfix/…` but `PR_BASE` isn't `<PRODUCTION_BRANCH>`
        (Discovery's `production_branch` row), or on `feature/…` but it is.
        §12 ties the prefix to the base, so one of
        the two is wrong — **stop and ask.** A hotfix that fell through to
        `source=env-default` is the realistic case, and
        retargeting a production fix at staging neither ships it nor gets it
        versioned. A sub-task is exempt: its base is its parent's branch.
    - Link the issue from the PR body as
      `https://<JIRA_ACCOUNT_URL>/browse/<KEY>`, built from Discovery's
      `jira_account_url` row and from nothing else — not the REST `self` URL,
      not the git remote you just read for the PR
      (`../_shared/project-config.md` § *Issue browse links*).
    - Write the PR body to a temp file and use `--body-file` — same reason as
      Jira comments:
      ```bash
      cat > /tmp/<KEY>-pr-body.md <<'EOF'
      <what changed + link to the issue>
      EOF
      gh pr create --base "$PR_BASE" --title "<KEY>: <summary>" \
        --body-file /tmp/<KEY>-pr-body.md
      ```
    - Discovery already confirmed `gh` is installed and authenticated, so a
      failure here is something else (a repo-permission problem, a transient
      network issue). Don't fail silently — report the `gh` error and still
      hand back the compare URL so the user can open the PR by hand:
      `https://github.com/<org>/<repo>/compare/$PR_BASE...<branch-name>?expand=1`
      (`<org>/<repo>` from `git remote get-url origin`).

11. **Update Jira — status transition, no comment yet:**
    The PR from step 10 is open (whether this run created it or updated an
    existing one), so the work is under review — transition it unless it
    already reads `<STATUS_IN_REVIEW>` (step 3's exit-8 reason, and by now the
    work is committed and pushed, so a hard stop here would be the worst place
    to take one):
    `jira.sh --role executor issue transition <KEY> --to "<STATUS_IN_REVIEW>"`.
    How it later reaches `<STATUS_DONE>` depends on whether `<KEY>` has
    a parent (check `fields.parent` from step 1):

    - **Has a parent (multistep sub-task)** → Once the reviewer
      approves the PR, the human merges it into the parent branch.
      GitHub-for-Jira automation (if connected) transitions the
      sub-task to `<STATUS_DONE>` on merge. If the reviewer rejects
      it, the sub-task moves to `<STATUS_IN_PROGRESS>` and the
      executor must re-run `/jira-sdlc:jira-task-executor` (bare, from
      this same worktree) to fix it — that re-run reads the reviewer's
      findings at step 4 and updates this same PR at step 10.
    - **No parent (single-step top-level issue)** → the reviewer
      (when run on that issue) will review this PR targeting the
      base branch. `<STATUS_DONE>` is handled when the human merges the
      PR into the base branch — via GitHub-for-Jira's merge automation
      if connected, or a manual `jira.sh --role executor issue transition <KEY> --to "<STATUS_DONE>"`
      otherwise. Don't transition to Done here.

12. **Report back** — branch name, what was implemented, test results,
    commit(s), the PR link, and the issue's new status. Post this same report
    to the user in chat **and** as a single Jira comment: it is the one
    comprehensive **run report**, so don't fragment it (no separate trivial
    "PR opened" comment earlier). Step 10's fix-summary on a re-run isn't a
    second run report: it's a *GitHub* PR comment, for the reviewer. Post the
    report with the temp-file + `--body-file` convention:

    ```bash
    S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"   # win/jira.ps1 on Windows
    bash "$S/jira.sh" --role executor issue comment add <KEY> --body-file /tmp/<KEY>-report.md
    ```

    (Write it to `/tmp/<KEY>-report.md` first with a `cat > … <<'EOF'` heredoc.)

Reference: `../_shared/jira-api-reference.md` — the `jira.sh` command surface,
field lists, comment mechanics and git/branch conventions this skill depends
on.
