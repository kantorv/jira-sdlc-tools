---
name: jira-task-executor
description: Given a Jira issue key, picks it up end-to-end — branch, status transition, investigation, implementation, tests, commit, push, and PR. Reports back the PR link and updated Jira status.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

You are acting as the engineer picking up a single Jira issue end-to-end.
Given an issue key ($ARGUMENTS, e.g. `PROJ-278`):

**Conventions used below:**
- `<KEY>` = the Jira issue key passed as $ARGUMENTS.
- Auth follows `../_shared/jira-acli-reference.md` §0 — `acli` stores
  credentials after a one-time `acli jira auth login`, so no per-command
  token prefix; run commands bare.
- **Jira comment mechanics**: multi-line / markdown comments are written to
  a temp file and posted with `acli jira workitem comment create --key <KEY>
  --body-file <file>`. Never wrap markdown in an inline `--body` string
  (backticks → command substitution), and `--body-file -` / stdin does not
  work — see §6.
- **Task memory (Jira comments as durable per-task memory)**: treat the
  issue's Jira comments as this task's long-term memory across sessions —
  read prior notes before implementing (step 4) and record memory-worthy
  findings as you work (step 6), so a later run recovering, reimplementing,
  or reinvestigating this issue inherits the context instead of starting
  cold. Every memory comment begins with the marker line
  `Task memory (jira-task-executor)` so it stays greppable and is never
  confused with the assigner's `Assignment report`, the `PR target branch:`
  comment, or the final run report (step 12). **Routing**: truly durable or
  architectural decisions belong in the code docs
  (README / CLAUDE.md / AGENTS.md / inline) — a Jira memory comment is a
  pointer for the next session, not a permanent home for design the
  codebase itself should own; it's for task-recovery, reimplementation, and
  already-touched-code investigation context. Post memory comments with the
  same temp-file + `--body-file` mechanics as any other comment (§6) —
  never an inline `--body` with backticks.
- Every leaf gets its own dedicated branch and opens its own PR; the PR's
  base comes from the `PR target branch: …` Jira comment the assigner
  posts, resolved in step 10 via `../_shared/jira-acli-reference.md` §12.
- `<STATUS_*>` and other `<TOKEN>`s resolve from `jira-sdlc-tools.env`
  (team-shared) and `jira-sdlc-tools.local.env` (machine-specific) in the
  project root.

**Discovery and healthcheck — run before step 1.** Discover where you
are (worktree + current branch) and confirm both CLIs are logged in
before touching anything. The rest of this skill transitions Jira
status, commits, pushes, and opens a PR — every one of those assumes the
right starting point and working credentials, and finding a busted
environment mid-flow (e.g. a logged-out `gh` failing at step 10, *after*
the implementation is already written and pushed) wastes a whole run and
can leave commits on the wrong branch. Resolve every `<TOKEN>` below from
`jira-sdlc-tools.env` (team-shared) and `jira-sdlc-tools.local.env`
(machine-specific) in the project root, run the four checks in order, and
on the first failure **stop and tell the user how to fix it** (the
messages below say what) — don't try to re-create worktrees or switch
branches yourself.

**Health check 1 — in a per-issue git worktree.** `jira-task-assigner`
provisions one worktree per leaf (named `worktree-<KEY>`), and the
executor is meant to run there — never from the main checkout, where
committing onto a shared branch such as `<DEFAULT_BASE_BRANCH>` would
collide with the rest of the team. A linked worktree's root has a `.git`
*file* (pointing into the main repo's `.git/worktrees/` directory); the
main checkout's `.git` is a directory. `git rev-parse --show-toplevel`
finds the root from any subdirectory, so the check works wherever in the
worktree you started:

```bash
WT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$WT_ROOT" ] || [ ! -f "$WT_ROOT/.git" ]; then
  echo "Not in a per-issue git worktree. The executor must run in the worktree jira-task-assigner created for <KEY> (named worktree-<KEY>), not the main checkout. cd into that worktree and rerun /jira-sdlc:jira-task-executor <KEY>." >&2
  exit 1
fi
```

**Health check 2 — on a `feature/` or `hotfix/` branch whose project matches
`<PROJECT-KEY>`.** The branch must be `feature/<KEY>-<slug>` or
`hotfix/<KEY>-<slug>` (the naming convention `jira-task-assigner` uses —
see `../_shared/jira-acli-reference.md` §7), and the project key embedded
in the branch name must equal `<PROJECT-KEY>` from
`jira-sdlc-tools.env`. A mismatch means the worktree was set up for a
different project's issue — implementing here would write this change
into another project's tree:

```bash
BR=$(git branch --show-current)
case "$BR" in
  feature/*|hotfix/*) ;;
  *) echo "Current branch '$BR' is not a feature/* or hotfix/* branch. The executor must run on the issue's own feature/<KEY>-<slug> or hotfix/<KEY>-<slug> branch. Switch to that branch in its worktree (or rerun jira-task-assigner to set it up) and rerun /jira-sdlc:jira-task-executor <KEY>." >&2; exit 1 ;;
esac
# Strip the feature/ or hotfix/ prefix: <KEY>-<slug> remains, and <KEY>
# begins with <PROJECT-KEY>- (e.g. PROJ-278), so the prefix must match.
BR_TAIL=${BR#*/}
case "$BR_TAIL" in
  "<PROJECT-KEY>"-*) ;;   # branch is for this project — OK
  *) echo "Branch '$BR' doesn't start with <PROJECT-KEY> — it belongs to a different project. You're in a worktree set up for another project's issue. Switch to the branch for <KEY> in this project's worktree and rerun /jira-sdlc:jira-task-executor <KEY>." >&2; exit 1 ;;
esac
```

This confirms the branch's **project** matches settings; step 2a below
tightens it further to confirm the branch is this **specific** issue's
(its `<KEY>` is in the branch name), so you're not about to write one
issue's change onto a sibling issue's branch within the same project.

**Health check 3 — `gh` (GitHub CLI) is authenticated.** Step 10 opens
the PR with `gh pr create`, so a logged-out `gh` surfaces here — before
the work is done — rather than an hour in:

```bash
if ! { gh auth status 2>&1 | grep -q 'Logged in to github.com'; }; then
  echo "gh (GitHub CLI) is not installed or not authenticated. Install it (https://cli.github.com) and run 'gh auth login', then rerun /jira-sdlc:jira-task-executor <KEY>." >&2
  exit 1
fi
```

**Health check 4 — `acli` (Atlassian CLI) is authenticated.** Steps 1,
3, 11, and 12 all call `acli jira ...`, riding on the one-time login
`jira-task-assigner` verified in its own health check; confirm it still
holds (acli stores credentials in its keyring, so it works from a
worktree even though `jira-sdlc-tools.local.env` is gitignored and not
copied into the worktree). See `../_shared/jira-acli-reference.md` §0:

```bash
if ! { acli jira auth status 2>&1 | grep -q '✓ Authenticated'; }; then
  echo "acli (Atlassian CLI) is not installed or not authenticated with Jira, so the executor can't fetch/transition/comment on the issue. Run the one-time acli login (../_shared/jira-acli-reference.md §0 has the exact command, using <JIRA_ACCOUNT_URL>, <JIRA_ACCOUNT_EMAIL>, <JIRA_TOKEN> from jira-sdlc-tools.local.env), then rerun /jira-sdlc:jira-task-executor <KEY>." >&2
  exit 1
fi
```

All four green — continue to step 1. Any red — stop, tell the user, and
wait; the executor doesn't try to self-repair its own preconditions.

1. **Fetch the issue** — `acli jira workitem view <KEY> --json --fields '*all'`
   (auth per §0). Pull out: summary, description, issue type, current
   status, and parent (if any).
   - Also check `fields.subtasks` (the default `--json` *omits* subtasks,
     so `--fields '*all'` is required here — see §3):
     - **Non-empty** → `<KEY>` is a parent: a merge target for its
       sub-tasks' PRs, not an implementation surface. Implementing here
       risks conflicting with / shadowing the sub-tasks' separate PRs that
       target this same branch, and breaks the "every leaf gets its own PR"
       invariant. Confirm with the user before continuing — don't proceed
       on a "this one's small" judgment call.
     - **Empty** → `<KEY>` is a leaf: either a sub-task, or a
       single-step top-level issue the assigner provisioned for direct
       implementation (its own worktree + dedicated branch, PR targeting
       the base branch). Proceed normally.
   - Every leaf gets its own dedicated branch and opens its own PR (no
     per-issue strategy to read). The PR's base comes from the
     `PR target branch: ...` Jira comment posted by `jira-task-assigner`,
     read in step 10 below.

2. **Branch setup:**

   - **2a. Confirm this worktree is for THIS issue.** The discovery
     section above already established you're in a per-issue worktree on
     a `feature/`/`hotfix/` branch whose project matches `<PROJECT-KEY>`.
     What's left is the finer-grained check: that the branch is this
     **specific** issue's — its `<KEY>` (from $ARGUMENTS) appears in the
     branch name — so you're not about to write one issue's change onto
     a sibling issue's branch within the same project:
     ```bash
     case "$(git branch --show-current)" in
       *"$KEY"*) ;;   # this branch is the issue's own — OK
       *) echo "Worktree branch '$(git branch --show-current)' doesn't \
     match $KEY; this worktree wasn't set up for this issue. Stop and \
     ask the user before continuing." >&2; exit 1 ;;
     esac
     ```
     If the user explicitly asked to run from a parent's worktree, they'll
     confirm it in response — treat that confirmation as overriding the
     gate, not as a reason to skip it.

   - **2b. Bring the worktree branch current.** The worktree's branch may
     be behind the branch it was created from. Look that up via
     `git config branch."$(git branch --show-current)".parentbranch`.
     - If found → bring the worktree branch up to date:
       `git merge <that-branch> --no-edit`. If this produces conflicts,
       stop and ask the user to resolve them — don't attempt to resolve
       merge conflicts automatically.
     - If not set (this worktree branch wasn't created by this skill, or
       predates this convention) → skip the merge, but flag in the final
       report that you proceeded on a possibly-stale worktree branch.

   - **2c. Locate or create the issue branch.** `git fetch origin` then
     `git branch -a | grep <KEY>` to check whether a branch for this issue
     already exists, local or remote.
     - **Normal path — branch already exists** (the assigner pre-created
       it): check it out — don't create a second branch for the same
       issue. Recover its parent via
       `git config branch."<branch-name>".parentbranch` — if that's unset
       (branch predates the parentbranch convention, or wasn't created by
       this skill), ask the user which branch the PR should target rather
       than guessing.
     - **Fallback — branch doesn't exist** (issue created without the
       assigner): derive the prefix:
       - `<KEY>` is `Task`/`Story` → `feature/`.
       - `<KEY>` is `Bug` → `hotfix/`.
       - `<KEY>` is `Subtask` → look at its parent's type instead (one
         level up is always top-level — see §7) and use *that* type to
         pick feature/hotfix.
       - Capture the base branch **before** checkout (the branch you're
         branching *from* will be the PR target):
         `BASE=$(git branch --show-current)`
       - Branch from the current branch directly —
         `git checkout -b <prefix>/<KEY>-<slugified-summary>` (naming
         convention per §7).
       - Record the parent (new branch need not be checked out to set its
         config — the `<new-branch-name>` is already known):
         `git config branch."<prefix>/<KEY>-<slugified-summary>".parentbranch "$BASE"`
       - Also post the durable fallback the assigner posts for issues it
         creates (single-line form — see §6 for comment mechanics):
         `acli jira workitem comment create --key <KEY> --body "PR target branch: $BASE."`

3. **Transition the issue** to in-progress:
   `acli jira workitem transition --key <KEY> --status "<STATUS_IN_PROGRESS>" --yes` (see
   `jira-sdlc-tools.env` in the project root for the confirmed status name for this
   project — default example `In Progress`).

4. **Investigate** — read the affected code (Grep/Read/Glob) before
   writing anything. Understand existing patterns, not just the issue text.
   - **Read prior task memory first.** Step 1 already fetched the issue with
     `--fields '*all'`, which includes `fields.comment.comments`; scan those
     (or re-list with `acli jira workitem comment list --key <KEY> --json`)
     for the assigner's `Assignment report` context and for any
     `Task memory (jira-task-executor)` notes an earlier session left —
     findings, gotchas, design decisions + rationale, and recovery context.
     Fold what you learn into this investigation instead of rediscovering it
     cold. This matters most when re-running a failed or reviewer-rejected
     issue: the previous session's memory is how you avoid repeating its
     dead ends.

5. **Clarify** — if the issue's description/acceptance criteria leaves
   something materially ambiguous (an implementation choice that would
   change the result), ask the user before writing code. Don't guess on
   anything that matters.

6. **Implement** the change.
   - **Record task memory as you go — but only when it's worth preserving.**
     When you learn something a later session would otherwise have to
     rediscover — an important finding, a non-obvious piece of logic, a
     design decision *and its rationale*, a gotcha in already-touched code,
     or context that would help recover or reimplement this task — post a
     `Task memory (jira-task-executor)` comment (marker + temp-file/
     `--body-file` mechanics per the preamble and §6). This is
     task-recovery memory, **not** running commentary: skip trivial or
     self-evident decisions, and if a single note at the end captures
     everything worth keeping, one comment is enough. Memory-worthy items
     can surface as early as investigation (step 4) — post them when you
     find them, not only here. **Routing reminder**: if the decision is
     truly durable or architectural, put it in the code docs
     (README / CLAUDE.md / AGENTS.md / inline) — a Jira memory comment is a
     pointer for the next session, not a substitute for documentation the
     codebase should own.

7. **Test before committing:**

   - **7a. Find this project's test commands.** Which runner a project
     uses, how it selects a single test, and how it runs the whole suite
     all vary too much to ship a plugin default. Look for `CLAUDE.md`,
     `AGENTS.md`, a "Tests" section in `README.md`, or similar in the
     repo root.
     - **Found, and covers both forms** (run a single test, run the full
       suite) → use those commands throughout the rest of this step.
     - **Not documented anywhere** → ask the user whether to install a
       test runner and the testing dependencies now. This is its own task;
       don't decide on their behalf.
       - If they say yes → once everything's in, fold the discovered
         "run one test" / "run full suite" commands into `CLAUDE.md` /
         `AGENTS.md` so the next session doesn't have to re-derive them.
       - If they say no, or this stack genuinely has no test layer →
         skip the rest of this step. Note in the final report that
         testing was skipped and why, then continue to step 8 (commit).

     - *Edge case — tests exist but commands aren't documented* (e.g. CI
       runs them, `package.json` has scripts, but no `CLAUDE.md` line
       tells you how): discover them — inspect `package.json` scripts,
       `Makefile` targets, README sections, and CI config — and
       sanity-check each candidate (`--listTests`, a dry run, or one
       trivial pass) before relying on it. **Suggest** (don't silently
       edit) that the user add the resulting "run one test" and "run full
       suite" commands to `CLAUDE.md` / `AGENTS.md`.

   - **7b. Run tests for this change.** If test coverage exists already,
     identify the affected tests; if it doesn't, add the new test(s) to
     the relevant suite file first. Run each new/affected test
     individually, one at a time — don't move on until the current one
     passes. Use the project's documented single-test command. If that
     command selects by line number but your runner doesn't actually
     support it, filter by name or pattern instead — the policy matters
     more than the exact invocation. Once every individual test passes,
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

8. **Commit** — `git commit -m "<KEY> <short message>"`. Split into
   multiple commits if the change has logically separate pieces; one is
   fine for a small change.

9. **Push** — `git push -u origin <branch-name>`.

10. **Open a PR:**
    - Resolve the PR base per `../_shared/jira-acli-reference.md` §12
      (git-config → Jira "PR target branch" comment → env default):
      ```bash
      CUR=$(git branch --show-current)
      PR_BASE=$(git config branch."$CUR".parentbranch 2>/dev/null)
      [ -z "$PR_BASE" ] && PR_BASE=$(acli jira workitem comment list --key <KEY> --json \
        | grep -oE 'PR target branch: [^ .]+' | head -1 | sed 's/PR target branch: //')
      [ -z "$PR_BASE" ] && PR_BASE="<DEFAULT_BASE_BRANCH>"   # last resort — flag in the final report
      ```
      Only fall back to `<DEFAULT_BASE_BRANCH>` (see `jira-sdlc-tools.env`) if
      *both* the local config and the Jira comment come up empty, and say
      so explicitly in the final report if you had to.
    - Build the issue's canonical URL as `https://<JIRA_ACCOUNT_URL>/browse/<KEY>`
      (`<JIRA_ACCOUNT_URL>` comes from `jira-sdlc-tools.env` in the
      project root — acli has no browse-URL subcommand, so construct the
      link from the token) to link back to it in the PR body, rather than
      hardcoding the Jira site domain anywhere.
    - Write the PR body to a temp file and use `--body-file` (backticks
      inside an inline `--body` string trigger shell command substitution —
      the same hazard the comment convention avoids):
      ```bash
      cat > /tmp/<KEY>-pr-body.md <<'EOF'
      <what changed + link to the issue>
      EOF
      gh pr create --base "$PR_BASE" --title "<KEY>: <summary>" \
        --body-file /tmp/<KEY>-pr-body.md --label <semver-label>
      ```
      The `--label` flag is **required** — the repo's semver-based release
      workflow reads it to decide the next version bump. Pick the label by
      what the PR actually changes in the app's semantics (these three
      names assume the `<SEMVER_LABELS>` default from `jira-sdlc-tools.env`
      — adjust if yours differ):
      - `patch` — bug fixes, small internal improvements, no new
        functionality or breaking changes
      - `minor` — new features or non-breaking enhancements
      - `major` — breaking changes (API removals, behaviour reversals)
      Labels must already exist in the repo (confirm with
      `gh api repos/<org>/<repo>/labels --jq '.[].name'`).
    - The discovery checks above already confirmed `gh` is installed and
      authenticated, so a failure here is something else (a `gh pr create`
      error, a repo-permission problem, or a transient network issue).
      Don't fail silently — report the `gh` error and still hand back the
      compare URL so the user can open the PR by hand:
      `https://github.com/<org>/<repo>/compare/$PR_BASE...<branch-name>?expand=1`
      (get `<org>/<repo>` from `git remote get-url origin`).

11. **Update Jira — status transition, no comment yet:**
    You just opened a PR (step 10), so the work is now under review —
    transition it to in-review:
    `acli jira workitem transition --key <KEY> --status "<STATUS_IN_REVIEW>" --yes` (see
    `jira-sdlc-tools.env` in the project root for the confirmed status
    name for this project — default example `In Review`).
    How it later reaches `<STATUS_DONE>` depends on whether `<KEY>` has
    a parent (check `fields.parent` from step 1):
    - **Has a parent (multistep sub-task)** → Once the reviewer
      approves the PR, the human merges it into the parent branch.
      GitHub-for-Jira automation (if connected) transitions the
      sub-task to `<STATUS_DONE>` on merge. If the reviewer rejects
      it, the sub-task moves to `<STATUS_IN_PROGRESS>` and the
      executor must re-run `/jira-sdlc:jira-task-executor <KEY>` to fix it.
    - **No parent (single-step top-level issue)** → the reviewer
      (when run on that issue) will review this PR targeting the
      base branch. `<STATUS_DONE>` is handled when the human merges the
      PR into the base branch — via GitHub-for-Jira's merge automation
      if connected, or a manual `acli jira workitem transition --key <KEY> --status "<STATUS_DONE>" --yes`
      otherwise. Don't transition to Done here.

12. **Report back** — branch name, what was implemented, test results,
    commit(s), the PR link, and the issue's new status. Post this same
    report to the user in chat **and** as a single Jira comment: this is
    the one comprehensive **run report** — don't fragment it (in
    particular, no separate trivial "PR opened" comment earlier). The
    `Task memory (jira-task-executor)` notes from step 6 are the *only*
    sanctioned companions to it: they carry their own marker, serve a
    different purpose (task-recovery context, not the run summary), and are
    expected whenever the run turned up something worth preserving between
    sessions. Keep the two kinds distinct — memory notes always carry the
    marker line; this final run report never does. Since it's multi-line,
    post it using the temp-file + `--body-file` convention (see the preamble
    above and §6):
    ```
    acli jira workitem comment create --key <KEY> --body-file /tmp/<KEY>-report.md
    ```
    (Write the report content to `/tmp/<KEY>-report.md` first with a
    `cat > … <<'EOF'` heredoc, as shown in §6.)

Reference: `../_shared/jira-acli-reference.md` has the full acli syntax,
confirmed issue types, and git/branch conventions this skill depends on.
The `jira-sdlc-tools.env` (team-shared) and `jira-sdlc-tools.local.env`
(machine-specific) files in the project root have this repo's specific values for every
`<TOKEN>` used above.
