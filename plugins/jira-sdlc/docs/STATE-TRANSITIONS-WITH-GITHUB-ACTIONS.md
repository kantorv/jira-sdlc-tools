# Driving Jira state from GitHub Actions

Three workflows move an issue through its states from git events, with no
Jira app installed and no skill running. They are how a card keeps up with
reality when a human — not `jira-task-executor` — pushes the branch or
merges the PR.

| Workflow | Fires on | Transition |
|---|---|---|
| `jira_issue_transition_on_branch.yml` | `create` of a `feature/*` or `hotfix/*` branch | `<STATUS_TODO>` → `<STATUS_IN_PROGRESS>` |
| `jira_issue_transition_on_pr_open.yml` | PR opened/reopened from a `feature/*` / `hotfix/*` head | → `<STATUS_IN_REVIEW>` |
| `jira_issue_transition_on_merge.yml` | PR closed **as merged** on an issue branch | → `<STATUS_DONE>` |

They live in **this repo's own `.github/workflows/`**, not inside
`plugins/jira-sdlc/` — a marketplace install copies only the plugin root, so
you won't get them by installing the plugin. Copy the three files out of this
repository into your project.

This is an alternative to [GitHub for Jira](INSTALLING-GITHUB-FOR-JIRA.md),
not a companion to it. The app is less setup and covers more surface; these
workflows win when you need the exact status names, sources and guards to be
yours, or you can't install a Marketplace app in the org. Running both means
two things racing to set the same status — pick one.

## How all three work

Every one of them follows the same five moves, so learning one is learning
all three:

1. **Derive the key from the branch name** — `^(feature|hotfix)/([A-Z]+-[0-9]+)-`.
   Note the trailing hyphen: `feature/PROJ-12-add-login` matches,
   `feature/PROJ-12` alone does **not**. No match → the step exits 0 quietly.
2. **Resolve the Jira cloud id** from `https://<site>/_edge/tenant_info`, a
   public endpoint, and address the API as
   `https://api.atlassian.com/ex/jira/<cloudId>/rest/api/3`. This is not
   decoration: a *scoped* API token is rejected by Basic auth on the
   `*.atlassian.net` domain and only works through this gateway. Resolving the
   id at runtime is what keeps it from being a fourth secret.
3. **Read the current status** and decide whether to act (see the guards
   below). Nothing is assumed about where the issue currently is.
4. **Look up the transition id** whose `to.name` equals the target status —
   Jira's API takes a transition id, not a status name.
5. **POST the transition.**

No workflow checks out the repo; they are pure API calls against a key parsed
from a branch name.

### The guards — why they rarely fight anything

Each workflow re-reads the issue first and stands down rather than regressing
it, which is what makes them safe to run alongside the skills, alongside a
human dragging cards, and alongside each other:

- **on-branch** advances *only* from exactly `To Do`. Anything further along
  → logs the current status and exits 0.
- **on-pr-open** skips when the issue is already `In Review` or `Done`;
  otherwise it advances, including straight from `To Do` if your board allows
  that edge.
- **on-merge** skips when the issue is already `Done`.

The one hard failure is deliberate: if the target status exists but **no
transition to it is available from the current one**, the job fails with a
`::error::`. Jira transitions are edges in a workflow graph, not a free
jump to any status — a red job here means your board has no path from where
the issue is to where the workflow wants it, which is worth knowing rather
than swallowing.

## Integrating them

### 1. Copy the workflows in

Copy all three files into `.github/workflows/` in your project, keeping the
names. They have no dependency on each other and you can adopt a subset — the
merge one alone is already useful.

### 2. Create a Jira API token

Any account's token works; the transition shows up in the issue history as
**that** user, so a dedicated automation account keeps the audit trail honest.

If you create a **scoped** token, give it the coarse `read:jira-work` and
`write:jira-work` scopes. The granular per-issue scopes look like the right
answer and fail with *"scope does not match"* — the same trap `acli` hits
(see [JIRA-ACLI.md](JIRA-ACLI.md)).

### 3. Add three repository secrets

*Settings → Secrets and variables → Actions → New repository secret.*

| Secret | Value | Notes |
|---|---|---|
| `JIRA_ACCOUNT_URL` | `yourteam.atlassian.net` | Scheme optional — the workflows strip `https://` if present |
| `JIRA_ACCOUNT_EMAIL` | the token owner's Atlassian email | Must be the account the token belongs to |
| `JIRA_ISSUE_TRANSITION_TOKEN` | the API token from step 2 | |

### 4. Make the status names match your board

**If you change nothing else after copying the files, change these.** The
status names are **literals inside each workflow**, not values read from
`jira-sdlc-tools.env` — the workflows never check out the repo, so they
cannot read that file, and it isn't necessarily committed anyway. The
in-file comments saying *"Mirrors `STATUS_TODO` / `STATUS_IN_PROGRESS`"* are
a promise you keep by hand.

There are **five** literals across the three files. Line numbers are as of
this writing — if they've drifted, the variable names are the reliable
anchor (`grep -n 'SOURCE=\|TARGET=\|DONE=' .github/workflows/jira_issue_transition_on_*.yml`):

| File | Line | Literal | Role | Replace with your… |
|---|---|---|---|---|
| [`jira_issue_transition_on_branch.yml`](../../../.github/workflows/jira_issue_transition_on_branch.yml#L35) | 35 | `SOURCE="To Do"` | only status it will advance *from* | `<STATUS_TODO>` |
| [`jira_issue_transition_on_branch.yml`](../../../.github/workflows/jira_issue_transition_on_branch.yml#L36) | 36 | `TARGET="In Progress"` | where it moves the issue | `<STATUS_IN_PROGRESS>` |
| [`jira_issue_transition_on_pr_open.yml`](../../../.github/workflows/jira_issue_transition_on_pr_open.yml#L44) | 44 | `TARGET="In Review"` | where it moves the issue | `<STATUS_IN_REVIEW>` |
| [`jira_issue_transition_on_pr_open.yml`](../../../.github/workflows/jira_issue_transition_on_pr_open.yml#L45) | 45 | `DONE="Done"` | **guard only** — don't drag a closed issue back to In Review | `<STATUS_DONE>` |
| [`jira_issue_transition_on_merge.yml`](../../../.github/workflows/jira_issue_transition_on_merge.yml#L45) | 45 | `TARGET="Done"` | where it moves the issue | `<STATUS_DONE>` |

The fourth one is the easy miss: `DONE` in the PR-open workflow is not a
target, it's the sentinel that stops a merged-and-closed issue being pulled
back to In Review when someone reopens the PR. Leave it as `"Done"` on a
board that calls the state `Shipped` and the guard silently never matches.

Names must match your board **exactly, including case and spacing** — Jira
compares them literally against `status.name` and `transitions[].to.name`.
`in progress` will not match `In Progress`. A name that exists nowhere on the
board fails the run with the "no available transition" error above, which is
the good outcome; a name that matches the *wrong* state moves cards quietly
to the wrong place, which isn't.

If your board reads `Backlog` / `Doing` / `Code Review` / `Shipped`, the five
edits are:

```bash
# jira_issue_transition_on_branch.yml
SOURCE="Backlog"
TARGET="Doing"
# jira_issue_transition_on_pr_open.yml
TARGET="Code Review"
DONE="Shipped"
# jira_issue_transition_on_merge.yml
TARGET="Shipped"
```

Keep them consistent with the `STATUS_*` values in your `jira-sdlc-tools.env`
— the skills read that file, these workflows don't, and the two only agree
because you make them agree. [JIRA-STATES.md](JIRA-STATES.md) is the map of
which one moves a card when.

### 5. Merge to the default branch before expecting `create` to fire

GitHub runs `create`-triggered workflows from the **default branch's** copy of
the file. Until `jira_issue_transition_on_branch.yml` is merged there, pushing
a new branch does nothing — testing it on a feature branch will look broken
when it isn't. The two `pull_request` workflows don't have this problem.

### 6. Check it end to end

Push a branch named `feature/<KEY>-test` for a real issue sitting in
`<STATUS_TODO>`, and watch the run under the Actions tab. Its log names the
status it read and either the transition it made or why it stood down —
enough to tell "wrong status name" from "wrong secret" from "already
advanced" without adding debugging.

## Interaction with the skills

Both can be live at once; the guards make the overlap a no-op rather than a
conflict. What's worth understanding is *which* of them usually gets there
first, because it isn't uniform:

- **The parent / top-level branch** is pushed by `jira-task-assigner` while
  the issue is still at its creation default, so the branch workflow moves it
  to `<STATUS_IN_PROGRESS>`. On the **multistep** track this matters more than
  it looks: no skill ever transitions the parent issue — the executor works on
  sub-tasks and the reviewer's 5b reject deliberately doesn't move it — so
  these workflows are the only thing keeping a multistep parent's status
  current. Its `<STATUS_IN_REVIEW>` likewise comes from the PR-open workflow
  firing on the aggregate PR the reviewer creates in 5a.
- **Sub-task branches** are not pushed by the assigner. `jira-task-executor`
  pushes them at step 9, long after it set `<STATUS_IN_PROGRESS>` at step 3 —
  so the branch workflow finds the issue already moved and stands down. Normal,
  not a misconfiguration.
- **On PR open**, executor step 11 and the PR-open workflow both target
  `<STATUS_IN_REVIEW>`; whichever is second finds it already there and skips.
- **On approval**, `jira-task-reviewer` step 7 may set `<STATUS_DONE>` with
  your confirmation. The merge workflow later finds it already `Done` and
  skips. Decline that prompt and the merge workflow is what closes the card.

The full picture of who moves what, including the human and Jira-automation
rows, is in [JIRA-STATES.md](JIRA-STATES.md).

## Things that will bite you

- **Fork PRs get no secrets.** These use `pull_request`, so a PR from a fork
  runs without `secrets.*` and the API call fails on empty credentials. For
  an internal-branch workflow — which is what the skills produce — this never
  comes up. Don't reach for `pull_request_target` to "fix" it: that runs with
  a writable token in the base repo's context, and combining it with untrusted
  fork code is the classic way to leak your Jira token.
- **A branch created only locally fires nothing.** The `create` event needs
  the branch pushed. The assigner's worktrees are local until something pushes
  them.
- **Squash/rebase merges still count.** `pull_request.closed` with
  `merged == true` covers all three merge strategies. Closing a PR *without*
  merging correctly does nothing.
- **The job-level `if` is a cost guard, not just logic.** Filtering to
  `feature/*` / `hotfix/*` at the job level means a `release/*` PR skips
  without allocating a runner, rather than spinning one up to `exit 0`.
- **Consider `permissions: {}`.** None of the three touches repo contents, so
  an empty permissions block drops the default `GITHUB_TOKEN` grants and
  leaves them with only the outbound Jira calls they actually need.

## Related

- [JIRA-STATES.md](JIRA-STATES.md) — who moves a card where, all actors
- [CI.md](CI.md) — every workflow in this repo, including the release path
- [INSTALLING-GITHUB-FOR-JIRA.md](INSTALLING-GITHUB-FOR-JIRA.md) — the app
  alternative to these workflows
- [JIRA-ACLI.md](JIRA-ACLI.md) — the token/scope trap, from the CLI side
