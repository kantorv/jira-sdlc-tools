---
name: jira-task-executor
description: Picks up the issue implied by the current worktree's branch end-to-end — branch, investigation, implementation, tests, commit, push, and PR. No issue-key argument; run it from inside the issue's own worktree, optionally with free-form notes for the run. Reports back the PR link. Never moves the issue's Jira status on its own — see JIRA-SDLC-TOOLS-RULES.md.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Edit, Write
---

You are acting as the engineer picking up a single Jira issue end-to-end.
Run this from inside the issue's own worktree — no issue-key argument;
the issue key is derived from the current branch (see Discovery below).

**Conventions used below:**
- `<KEY>` = the Jira issue key derived from the current branch
  (`feature/<KEY>-<slug>` / `hotfix/<KEY>-<slug>`), read from the
  Discovery healthcheck's `issue_key` row below — the branch is the sole
  source of truth, there is no user-supplied key to compare it against.
- `$ARGUMENTS`, when non-empty, is free-form notes about this run
  (constraints, focus areas, context) — never parsed as an issue key.
  Fold it into investigation (step 4), clarification (step 5), and
  implementation (step 6) alongside the Jira issue description; it
  supplements, never replaces, that description.
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
  base is resolved in step 10 per `../_shared/jira-acli-reference.md` §12 —
  git config `parentbranch` first, then the assigner's
  `PR target branch: …` Jira comment (the durable fallback), then the env
  default.
- `<STATUS_*>` and other `<TOKEN>`s resolve from `jira-sdlc-tools.env`
  (team-shared) and `jira-sdlc-tools.local.env` (machine-specific) in the
  project root.

**Project rules — read these first.** If `JIRA-SDLC-TOOLS-RULES.md` exists
in the project root, adopt its `## COMMON` + `## JIRA-TASK-EXECUTOR`
sections for this run (ignore the other two); on any conflict with an
instruction here, that file wins. Absent → continue silently, it's
optional. Contract: `../_shared/project-config.md`.

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
chose, and can't be what you consult to dispatch statuscheck itself. And
unlike `jira_acli_login`, which takes a role argument, **statuscheck itself
takes no role or issue-key argument — run it bare** on both POSIX and Windows;
a stray role name (e.g. `reviewer`) reaching it is ignored rather than mistaken
for an issue key, but don't add one.

**Get local credentials, be the executor, and own the issue — run these
FIRST, before the healthcheck.** All three are idempotent and take no
decisions of their own; a non-zero exit from any of them means **STOP** —
relay its stderr verbatim and do not transition status, branch, commit,
comment, or work the issue.

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"
bash "$S/ensure_local_env.sh"          || exit 1   # 1. worktree gets local.env if it's missing
bash "$S/jira_acli_login.sh" executor  || exit 1   # 2. become the executor
bash "$S/check_assignee.sh"            || exit 1   # 3. <KEY> must be assigned to it
```

(`check_assignee.sh` takes the key from the branch, as the healthcheck does;
pass one explicitly only when running outside the issue's worktree. If
`CLAUDE_PLUGIN_ROOT` isn't set, all three live in `../_shared/scripts/posix/`
relative to this skill.)

**Discovery and healthcheck — run before step 1.** The rest of this
skill commits, pushes, and opens a PR — every
one of those assumes the right starting point and working credentials,
and finding a busted environment mid-flow (e.g. a logged-out `gh`
failing at step 10, *after* the implementation is already written and
pushed) wastes a whole run and can leave commits on the wrong branch.
All the checks are bundled into one script, so this is a single Bash
call rather than a sequence of separate probes:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh"
```

(If `CLAUDE_PLUGIN_ROOT` isn't set — e.g. reading this skill outside a
plugin session — the script lives at `../_shared/scripts/posix/statuscheck.sh`
relative to this skill's directory.)

The script resolves
`<PROJECT-KEY>` and `<DEFAULT_BASE_BRANCH>` from `jira-sdlc-tools.env` /
`jira-sdlc-tools.local.env` itself; you don't need to pre-resolve tokens
for this section. It prints one markdown table (`check | status |
detail`), where status is `OK`, `FAIL` (blocks, with a remedy line
printed under the table), `WARN` (suspicious, not blocking), or `INFO`
(context only), and exits non-zero if any row is `FAIL`.

Only the rows this skill reads in a role-specific way, or relies on later,
are spelled out here; the rest are role-independent preconditions defined
in `statuscheck.sh` itself (their `detail` column is self-explanatory in
the printed output — that live output, not this table, is what the skill
actually acts on).

| row | what it verifies / gathers |
|---|---|
| `worktree` | INFO: *linked worktree* (`.git` is a file) vs. *main checkout* (`.git` is a directory). **This skill requires a linked worktree** — the reading note below makes that a stop condition |
| `branch` | INFO: base branch vs. `feature/*`/`hotfix/*` issue branch (`../_shared/jira-acli-reference.md` §7) vs. neither. **This skill requires a feature/hotfix issue branch** — the reading note below makes that a stop condition |
| `issue_key` | the key derived from the branch name — becomes `<KEY>` for the rest of the run (the branch is the sole source of truth; this skill never passes the script's optional key argument) |
| `parent_branch` | INFO: `git config branch.<branch>.parentbranch` — consumed by step 2 (stale-branch merge) and step 10 (first candidate for the PR base) |

The remaining rows FAIL if broken but need no per-role interpretation
here: `git_repo`, `env_config`, `env_local` (auto-copied into a worktree
from the main checkout when missing by `ensure_local_env.sh`, called
before this script — see step 1 above),
`env_local_ignored`, `branch_project` (wrong-project guard), `gh_auth`
(step 10's `gh pr create`), `acli_auth` (every `acli jira …` call),
`jira_project`, plus context `base_branch`, `working_tree` (WARN when
dirty), and `worktrees_dir` (WARN when missing — only the assigner acts
on it).

Reading the result: **Any FAIL row** → stop, relay the script's remedy
line to the user, and wait — don't try to re-create worktrees, switch
branches, or re-auth CLIs yourself; the executor doesn't self-repair its
own preconditions.

The `worktree` and `branch` rows are context INFO, not FAILs — the shared
script reports them for every role (executor, reviewer, assigner) and
leaves the judgement to each skill. **For the executor, both must hold:**
the `worktree` row must report a *linked worktree* (not the main checkout)
and the `branch` row must report a *feature/hotfix issue branch* (not the
base branch or a non-conforming name). If either doesn't — e.g. you're in
the main checkout, or sitting on `<DEFAULT_BASE_BRANCH>` — **stop**: this
skill runs only from an issue's own worktree. cd into the worktree
`jira-task-assigner` created for the issue (`worktree-<KEY>`) and rerun.

Otherwise (no FAIL row, `worktree` linked, `branch` an issue branch) the
`issue_key` row's derived key is `<KEY>` for the rest of this run — there's
no user-supplied key to compare it against, and the identity gate above
already confirmed `<KEY>` is assigned to the executor. Continue to step 1,
carrying the INFO rows forward as context (`parent_branch` feeds step 2's
stale-branch merge and step 10's PR-base resolution).

1. **Fetch the issue** — `acli jira workitem view <KEY> --json --fields 'summary,description,issuetype,status,parent,subtasks,comment'` (auth per §0; source of truth for this fetch-with-comments field list: `../_shared/jira-acli-reference.md` §3 — resolve there rather than here if the two ever disagree). It's sized to everything this skill reads, including `comment` (scanned in step 4). Pull out: summary, description, issue type, current status, and `fields.parent.key` (if any) — store this as `PARENT_KEY` for the step 10 resolver.
   - Also check `fields.subtasks` (the canonical list names `subtasks`
     explicitly — the default `--json` omits it; see §3):
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
     per-issue strategy to read). The PR's base is resolved in step 10
     per `../_shared/jira-acli-reference.md` §12 — git config first, then
     the assigner's `PR target branch: ...` Jira comment, then (for
     sub-tasks) a parent-branch search, then the env default.

2. **Bring the worktree branch current.** Discovery already guaranteed
   you're on `<KEY>`'s own issue branch inside its own linked worktree —
   the branch exists and is checked out, so there is nothing to locate or
   create here. (An issue with no branch/worktree yet — one created
   without the assigner — is provisioned *before* this skill runs; the
   bootstrap recipe lives in `../_shared/jira-acli-reference.md` §7.)
   What the branch *can* be is **stale**: the branch it was created from
   may have moved since — most commonly a sibling sub-task's PR merging
   into the shared parent branch. Discovery's `parent_branch` row already
   carries the parent; read it from there rather than re-running the
   `git config` lookup.
   - **Set** → merge the parent's *remote* state — merging the local ref
     would silently miss anything that landed on origin after this
     worktree was created:
     ```bash
     git fetch origin
     git merge origin/<parent-branch> --no-edit   # the local ref only if it was never pushed
     ```
     If the merge conflicts, stop and ask the user to resolve — don't
     attempt to resolve merge conflicts automatically.
   - **Unset** (the branch predates the parentbranch convention, or
     wasn't created by the assigner) → skip the merge, but flag in the
     final report that you proceeded on a possibly-stale worktree branch.
     Don't stop to ask which branch the PR should target — step 10's
     resolver handles an unset parentbranch (Jira comment, then env
     default).

3. **Jira status — not yours to change.** You do **not** transition `<KEY>`
   to any state, at any point in this run, unless one of exactly two things
   tells you to: a rule in `JIRA-SDLC-TOOLS-RULES.md` (its `## COMMON` or
   `## JIRA-TASK-EXECUTOR` section), or the user asking you directly in
   chat. Absent that, leave the board alone — status here is owned by
   humans and automation, which can't tell a card *you* moved from one they
   moved, so a transition nobody asked for is a lie they have no way to
   spot. When you are asked, resolve the status name from
   `jira-sdlc-tools.env` and use:
   `acli jira workitem transition --key <KEY> --status "<STATUS_*>" --yes`.

4. **Investigate** — read the affected code (Grep/Read/Glob) before
   writing anything. Understand existing patterns, not just the issue text.
   - **Read prior task memory first.** Step 1's fetch already includes
     `fields.comment.comments`; scan those for the assigner's
     `Assignment report` and for any `Task memory (jira-task-executor)`
     notes an earlier session left (the Task-memory preamble bullet
     defines them), and fold what you learn in instead of rediscovering
     it cold. This matters most when re-running a failed or
     reviewer-rejected issue: the previous session's memory is how you
     avoid repeating its dead ends.

5. **Clarify** — if the issue's description/acceptance criteria leaves
   something materially ambiguous (an implementation choice that would
   change the result), ask the user before writing code. Don't guess on
   anything that matters.

6. **Implement** the change.
   - **Record task memory as you go — but only when it's worth preserving.**
     When you learn something a later session would otherwise have to
     rediscover — an important finding, a design decision *and its
     rationale*, a gotcha in already-touched code, or recovery context —
     post a `Task memory (jira-task-executor)` comment (marker line,
     comment mechanics, and code-docs routing all per the Task-memory
     preamble bullet). This is task-recovery memory, **not** running
     commentary: skip trivial or self-evident decisions, and one note at
     the end is enough if it captures everything worth keeping.
     Memory-worthy items can surface as early as investigation (step 4) —
     post them when you find them, not only here.

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

     - *Edge case — tests exist but the commands are missing or only
       half-documented* (e.g. CI runs them but no `CLAUDE.md` line tells
       you how; or the docs give the full-suite command and nothing for
       selecting a single test): discover the missing form(s) — inspect
       `package.json` scripts,
       `Makefile` targets, README sections, and CI config — and
       sanity-check each candidate (`--listTests`, a dry run, or one
       trivial pass) before relying on it. **Suggest** (don't silently
       edit) that the user add the resulting "run one test" and "run full
       suite" commands to `CLAUDE.md` / `AGENTS.md`.

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

8. **Commit** — stage the files this change touched explicitly
   (`git add <file>…`, not `-A`, which can sweep in strays), then
   `git commit -m "<KEY> <short message>"`. Split into multiple commits
   if the change has logically separate pieces; one is fine for a small
   change.

9. **Push** — `git push -u origin <branch-name>`.

10. **Open a PR:**
    - Resolve the PR base per `../_shared/jira-acli-reference.md` §12
      (git-config → Jira "PR target branch" comment → parent-branch search →
      env default). `PARENT_KEY` is step 1's `fields.parent.key` — set for a
      sub-task, empty for a top-level issue:
      ```bash
      CUR=$(git branch --show-current)
      PR_BASE=$(git config branch."$CUR".parentbranch 2>/dev/null)
      [ -z "$PR_BASE" ] && PR_BASE=$(acli jira workitem comment list --key <KEY> --json \
        | grep -oE 'PR target branch: [^" ]+' | head -1 \
        | sed -e 's/PR target branch: //' -e 's/\.$//')
      # Parent-branch recovery — only for a leaf that HAS a parent (a sub-task).
      # Normalize before counting, or one branch reads as several and looks "ambiguous":
      # strip BOTH markers `git branch -a` emits — `*` (checked out here) and `+`
      # (checked out in another linked worktree, the normal state of a parent branch
      # while a sub-task's worktree runs this search) — and fold the remotes/origin/
      # copy of a pushed branch into its local name (§7).
      if [ -z "$PR_BASE" ] && [ -n "$PARENT_KEY" ]; then
        CANDIDATES=$(git branch -a --list "*feature/$PARENT_KEY-*" "*hotfix/$PARENT_KEY-*" 2>/dev/null \
          | sed -E 's#^[+* ]+##; s#^remotes/origin/##' | sort -u)
        MATCHES=$(printf '%s' "$CANDIDATES" | grep -c .)
        [ "$MATCHES" -eq 1 ] && PR_BASE="$CANDIDATES"
      fi
      # The env default is the right answer ONLY for a top-level issue (no parent).
      # A sub-task that reached here is unresolved — leave PR_BASE empty so you stop.
      [ -z "$PR_BASE" ] && [ -z "$PARENT_KEY" ] && PR_BASE="<DEFAULT_BASE_BRANCH>"
      echo "$PR_BASE"
      ```
      Then act on the result before touching `gh pr create`:
      - **`PR_BASE` empty** — only possible for a sub-task whose parent branch
        search found zero or several candidates. **Stop and ask the user which
        branch is the base.** Do not open the PR, and do not substitute
        `<DEFAULT_BASE_BRANCH>`: a sub-task's base is its parent's branch, never
        the env default — silently defaulting there is the bug this resolver exists
        to prevent.
      - **Recovered by the branch search** (the first two sources were empty) —
        proceed, and say so explicitly in the final report, naming the branch.
      - **Fell back to `<DEFAULT_BASE_BRANCH>`** (see `jira-sdlc-tools.env`;
        top-level issues only) — proceed, and say so explicitly in the final report.
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
        --body-file /tmp/<KEY>-pr-body.md
      ```
    - The discovery checks above already confirmed `gh` is installed and
      authenticated, so a failure here is something else (a `gh pr create`
      error, a repo-permission problem, or a transient network issue).
      Don't fail silently — report the `gh` error and still hand back the
      compare URL so the user can open the PR by hand:
      `https://github.com/<org>/<repo>/compare/$PR_BASE...<branch-name>?expand=1`
      (get `<org>/<repo>` from `git remote get-url origin`).

11. **Jira status after the PR — still not yours to change.** Opening a PR
    is not a licence to move the card; step 3's rule holds to the end of
    the run. If `JIRA-SDLC-TOOLS-RULES.md` or the user asked for a move at
    this point — commonly to `<STATUS_IN_REVIEW>` — make it now, and only
    then. Everything the card does afterwards belongs to whoever owns it
    here: a human, GitHub-for-Jira's merge automation, or a project rule.

12. **Report back** — branch name, what was implemented, test results,
    commit(s), the PR link, and the status `<KEY>` is actually in (which
    is whatever it was when you started, unless step 3 authorized a move). Pass through any
    note the identity gate printed on success (it flags when acli is now a
    dedicated executor account machine-globally). Post this
    same report to the user in chat **and** as a single Jira comment: this is
    the one comprehensive **run report** — don't fragment it (in
    particular, no separate trivial "PR opened" comment earlier). The
    `Task memory (jira-task-executor)` notes from step 6 are the *only*
    sanctioned companions to it (they carry the marker line; this run
    report never does). Since it's multi-line,
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
