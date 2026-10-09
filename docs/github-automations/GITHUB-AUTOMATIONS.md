---
slug: /applications
sidebar_position: 1
sidebar_label: Overview
---

# GitHub Automations — how the plugin gets consumed, and every workflow this repo ships

> **Scope:** this document has two jobs. §1 explains the two ways the
> `jira-sdlc` plugin can be installed. §2 onward is a guide to the **demo
> GitHub Actions workflows** shipped under
> [`docs/github-automations/example-workflows/`](https://github.com/kantorv/jira-sdlc-tools/tree/main/docs/github-automations/example-workflows)
> — worked examples of running the three skills in CI, meant to be
> read next to the workflow files and copied into other repos. They are
> **not** this repo's own development procedure (human-driven, see
> [SDLC.md](../process/SDLC.md)).

______________________________________________________________________

## Where things live

This section (formerly "Applications") groups every GitHub Actions workflow
this repo ships — not just the CI demos of the three skills, but also the
smaller automations that keep a Jira issue's status in sync with its GitHub
branch/PR/merge. It's organized by how a workflow gets invoked, not by which
skill it happens to run:

| Subfolder | What's in it |
| -- | -- |
| [Jira state manipulation](jira-state-manipulation/jira-state-manipulation.md) | The two housekeeping workflows that transition a Jira issue's status automatically — on branch push, on PR open, and on merge. No skill, no LLM call. |
| [ChatOps](chatops/chatops.md) | Workflows triggered by a PR/issue **comment** — `/review`, `/make-task`, `/make-bug`. |
| [Manual review (workflow dispatch)](manual-dispatch/manual-dispatch.md) | Workflows triggered by hand from the Actions tab, no comment involved. |
| [Autopilot mode (issue → PR)](autopilot/autopilot.md) | The full assigner → executor → reviewer chain, comment-triggered, ending in an open reviewed PR. |

The rest of this document (§1 onward) is the same reference it always was —
plugin installation modes, the demo-workflow catalogue, and the gating
convention every one of these workflows follows.

______________________________________________________________________

## 1. Summary — two ways to use the plugin

| Mode | How it works | When to use |
| -- | -- | -- |
| **Claude Code marketplace plugin** | Add the marketplace, then `/plugin install jira-sdlc@<marketplace-name>` via the `/plugin` command. The three skills become available as `/jira-sdlc:jira-task-assigner`, `/jira-sdlc:jira-task-executor`, `/jira-sdlc:jira-task-reviewer`. | Default path — skills stay versioned with the marketplace release, upgrade with a reinstall. |
| **Loose skillset** | Copy `plugins/jira-sdlc/skills/` into a project's own skills folder (e.g. `.claude/skills/`). Invoke unprefixed — `/jira-task-assigner`, etc. | When you want to fork/edit the skills directly, or the target environment doesn't support the marketplace mechanism. Note the local-dev-loop caveat in [CLAUDE.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/CLAUDE.md): a marketplace install is a cached snapshot, so edits to a clone don't show up there until reinstalled — this is why active skill development should point `--plugin-dir` at a working copy instead. |

Both modes read the same configuration: `.jst/jira-sdlc-tools.env` (team-shared)
and `.jst/jira-sdlc-tools.local.env` (machine-specific, gitignored) in the
target project's root. See the plugin
[README.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/README.md#installation)
and
[project-config.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md) for what each
`<TOKEN>` resolves to.

______________________________________________________________________

## 2. Usage applications

### 2a. Classic — interactive, on your own machine

You run the skills manually, one at a time, from a terminal alongside your
coding assistant. Taking the simplest case — a **single-step** task, where the
assigner decides the work is cohesive enough to stay one issue:

**1. Plan it** — creates the Jira issue, its branch, and its worktree:

```
/jira-sdlc:jira-task-assigner "Add CSV export to the reports page"
```

**2. Implement it** — `cd` into the worktree the assigner created and start
your assistant there:

```
cd <WORKTREES_DIR>/worktree-<KEY> && claude
> /jira-sdlc:jira-task-executor
```

No key argument — it's derived from that worktree's own branch
(`feature/<KEY>-<slug>`). The executor implements, tests, commits, pushes, and
opens a PR into `<DEFAULT_BASE_BRANCH>`.

**3. Review it** — from the *same* worktree, once that PR is open:

```
> /jira-sdlc:jira-task-reviewer
```

Also no key argument. On a single-step issue there are no sub-tasks to
iterate, so the reviewer reviews that one PR into the base branch directly and
posts its verdict to GitHub and Jira. It never merges — that stays a human act.

A **multistep** task is the same three skills, just fanned out: the assigner
creates a parent issue plus a sub-task per parallelizable piece, each with its
own branch and worktree, you run one executor per sub-task worktree, and the
reviewer then runs from the *parent* worktree to sweep the whole set. See the
[README's usage walkthrough](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/README.md) for that version worked through
end to end.

Either way you answer the assigner's clarifying questions, and approve or fix
the reviewer's findings before merging — full interactive turn at every step.

### 2b. CI usage — GitHub Actions demos

This repo ships several demo workflows under
`docs/github-automations/example-workflows/` showing how to run the skills
headlessly in CI. Each is self-contained and meant to be copy-pasted into
another repo's `.github/workflows/` — they don't run in this one, except
`demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml`, which this repo also keeps
a copy of in its own `.github/workflows/` ([CI.md](../process/CI.md)).

| Workflow file | Trigger | What it does |
| -- | -- | -- |
| [`demo-claude-reviewer.yml`](example-workflows/demo-claude-reviewer.yml) | Comment `/review` on a PR | **Reviewer only**, against an already-open PR — a standalone review gate. Deep dive: [ci-review-pr-demo.md](chatops/review/ci-review-pr-demo.md). |
| [`demo-claude-issue-to-task.yml`](example-workflows/demo-claude-issue-to-task.yml) | Comment `/make-task` on an issue | **Assigner only** — turns the commented GitHub issue into a Jira Task + branch + worktree on the runner. Stops there (nothing persists past the job on a hosted runner). Deep dive: [ci-issue-to-task-demo.md](chatops/issue-to-task/ci-issue-to-task-demo.md). |
| [`demo-claude-issue-to-bug.yml`](example-workflows/demo-claude-issue-to-bug.yml) | Comment `/make-bug` on an issue | **Assigner only** — the byte-identical `/make-bug` twin of the row above; same run, producing a Jira Bug instead of a Task. Deep dive: [ci-issue-to-task-demo.md](chatops/issue-to-task/ci-issue-to-task-demo.md). |
| [`demo-claude-feature-flow.yml`](example-workflows/demo-claude-feature-flow.yml) | Comment `/make-feature` on an issue | **Full feature flow**: assigner → executor → reviewer, chained, one job per skill. Branch `feature/<KEY>-<slug>` off `<DEFAULT_BASE_BRANCH>`; PR targets `<DEFAULT_BASE_BRANCH>`. Deep dive: [ci-feature-flow-demo.md](autopilot/ci-feature-flow-demo.md). |
| [`demo-claude-hotfix-flow.yml`](example-workflows/demo-claude-hotfix-flow.yml) | Comment `/make-hotfix` on an issue | **Full hotfix flow**, same three-job chain and gating. Branch `hotfix/<KEY>-<slug>` off `origin/<PRODUCTION_BRANCH>`; PR targets `<PRODUCTION_BRANCH>`. Deep dive: [ci-hotfix-flow-demo.md](autopilot/ci-hotfix-flow-demo.md). |
| [`demo-fcc-nvidia-nim-feature-flow.yml`](example-workflows/demo-fcc-nvidia-nim-feature-flow.yml) | Comment `/fcc-make-feature` on an issue | Same three-job feature flow, but on **Free Claude Code + NVIDIA NIM** as the model backend instead of the Claude Code CLI — shows how to swap the LLM provider. Deliberately a different trigger word than `/make-feature` so the two workflows don't both fire off one comment. |
| [`demo-fcc-nvidia-nim-reviewer.yml`](example-workflows/demo-fcc-nvidia-nim-reviewer.yml) | Comment `/fcc-review` on a PR | Reviewer-only, FCC + NVIDIA NIM backend — the provider-swap counterpart to `demo-claude-reviewer.yml`. |
| [`demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml`](example-workflows/demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml) | Manual `workflow_dispatch` (model picker) | Reviewer-only, FCC + NVIDIA NIM — the dispatch twin of `demo-fcc-nvidia-nim-reviewer.yml`: same reviewer run with no comment trigger, and the NIM model picked from the dispatch dropdown instead of pinned. |

#### Common patterns across the CI demos

- **One job per skill**, each a fresh runner VM, each under its own Jira
  identity (assigner/executor/reviewer email + token).
- **No shared disk** — `WORKTREES_DIR` is rebuilt per job under
  `$RUNNER_TEMP/worktrees`. Jobs 2/3 reconstruct a *linked* worktree from the
  branch job 1 pushed; the executor and reviewer skills hard-stop unless
  they're running in a linked worktree on a `feature/*` or `hotfix/*` branch.
- **No environment, no approval pause** — no demo declares `environment:`.
  Who may trigger a run is decided by a cheap precheck (the OWNER comment
  guard, or write access for `workflow_dispatch`), and after that the jobs run
  start to finish. See §3.1.
- **Secrets are repository secrets** named exactly as the
  `.jst/jira-sdlc-tools.local.env` keys they become — this is what lets a job's
  bootstrap step be a single loop over a `KEYS` list instead of a hand-mapped
  one. See §3.2.
- **No `GH_TOKEN`/`GITHUB_TOKEN` exported into skill steps** — statuscheck
  logs `gh` in from `GITHUB_PAT_TOKEN` read out of the env file; exporting
  either token variable into the environment makes `gh auth login` refuse,
  since it insists the variable be cleared first.
- **Headless, no questions** — skills run with `-p --dangerously-skip-permissions`. A run where the assigner would normally
  ask a clarifying question produces no branch and fails loud (the guard
  checks for exactly one new branch).
- **Self-review** — the reviewer posts its verdict as a PR **comment**
  (`APPROVED — …` / `CHANGES REQUESTED — …`, never `gh pr review --approve`)
  because the same `gh` identity opened the PR and GitHub blocks
  self-approval.
- **Reporting back to the issue** — each job comments its transcript on the
  triggering issue (collapsed `<details>`, tail capped to stay under
  GitHub's comment size limit).

### 2c. The same demos, by scenario

The table in §2b lists one row per *file*. This one lists one row per
**scenario** — the flow being demonstrated — with the workflows that
implement it. Several scenarios ship more than once: same skills, same job
shape, different model backend behind them. Pick the row for the flow you
want, then the implementation whose backend you have credentials for.

| Scenario | What the flow does | Trigger | Implementations |
| -- | -- | -- | -- |
| [**Feature flow**](autopilot/ci-feature-flow-demo.md) | Full three-skill chain: assigner → executor → reviewer. GitHub issue becomes a Jira issue + `feature/<KEY>-<slug>` branch off `<DEFAULT_BASE_BRANCH>`, gets implemented, and ends as an open reviewed PR into `<DEFAULT_BASE_BRANCH>`. Nothing is merged. | **comment** — bare or with prose | • [`demo-claude-feature-flow.yml`](example-workflows/demo-claude-feature-flow.yml) — Claude Code CLI · `/make-feature`<br>• [`demo-fcc-nvidia-nim-feature-flow.yml`](example-workflows/demo-fcc-nvidia-nim-feature-flow.yml) — Free Claude Code + NVIDIA NIM · `/fcc-make-feature` |
| [**Hotfix flow**](autopilot/ci-hotfix-flow-demo.md) | The same three-skill chain on the emergency path: `hotfix/<KEY>-<slug>` cut off `origin/<PRODUCTION_BRANCH>`, PR targets `<PRODUCTION_BRANCH>`, and the assigner is forced single-step (no sub-tasks). | **comment** — bare or with prose | • [`demo-claude-hotfix-flow.yml`](example-workflows/demo-claude-hotfix-flow.yml) — Claude Code CLI · `/make-hotfix` |
| [**Review a PR**](chatops/review/ci-review-pr-demo.md) | Reviewer skill alone, against an already-open PR. Rebuilds a linked worktree for the PR branch, reviews the diff, and posts the verdict to GitHub (as a comment) and Jira. Merges nothing. | **comment** — bare or with prose, **or** manual `workflow_dispatch` | • [`demo-claude-reviewer.yml`](example-workflows/demo-claude-reviewer.yml) — Claude Code CLI · `/review`<br>• [`demo-fcc-nvidia-nim-reviewer.yml`](example-workflows/demo-fcc-nvidia-nim-reviewer.yml) — Free Claude Code + NVIDIA NIM · `/fcc-review`<br>• [`demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml`](example-workflows/demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml) — Free Claude Code + NVIDIA NIM · `workflow_dispatch` (model-pickable, no comment) |
| [**Issue to task / bug**](chatops/issue-to-task/ci-issue-to-task-demo.md) | Assigner alone. A commented GitHub issue becomes a Jira Task (`/make-task`) or Bug (`/make-bug`) with its branch and worktree, and the run stops there — no implementation, no PR. | **comment** — bare or with prose | • [`demo-claude-issue-to-task.yml`](example-workflows/demo-claude-issue-to-task.yml) — Claude Code CLI · `/make-task`<br>• [`demo-claude-issue-to-bug.yml`](example-workflows/demo-claude-issue-to-bug.yml) — Claude Code CLI · `/make-bug` |

Three things the matrix makes visible:

- **Backend coverage is uneven, deliberately.** The feature flow and the PR
  review exist on more than one backend because those are the two flows worth
  proving portable; the hotfix and issue-to-\* demos ship Claude-only. A missing
  cell is an un-built demo, not an unsupported combination — the skills
  themselves don't know which model is driving them.

- **The trigger word encodes the backend, not the flow.** `/make-feature` and
  `/fcc-make-feature` run the *same* scenario on different models. They're
  deliberately different words so that one comment doesn't start both
  workflows at once on a repo where both are installed.

- **The trigger comment can carry prose, and the prose steers the run.** Every
  comment-triggered demo above accepts its command bare *or* followed by a
  space or a newline and free-form text:

  ```
  /make-feature split this into sub-tasks per service, and skip the docs
  ```

  The workflow strips the command token and hands the remainder to the skill —
  appended to the assigner's prompt as a labelled `EXTRA DIRECTION FOR THIS RUN` section (the GitHub issue stays the task description), or passed to the
  reviewer as its skill argument, which `jira-task-reviewer` reads as free-form
  notes about the run. A bare command behaves exactly as it always has.

  What this does *not* loosen is the gate: the author check (OWNER) and
  the issue-vs-PR check are untouched and still live in the job-level `if:`,
  the prose is never gating input, and the command still has to be the first
  token followed by a separator — `/reviewer-anything` and a mid-sentence
  mention both stay inert.

______________________________________________________________________

## 3. Gating assistant workflows

Every workflow that executes a coding assistant is gated on **who can trigger
it**, and nothing else. A cheap, secret-free precheck job decides that before
any assistant job starts. None of them declares an `environment:`, so there is
no `production` environment to create and no approval pause: once the
precheck passes, the jobs run start to finish on repository secrets. (Earlier
revisions declared `environment: production` on every assistant job to scope
secrets and optionally pause for a Required-reviewers approval. JST-319
dropped it.)

### 3.1 The author gate — a cheap precheck before any assistant job

Every workflow reachable by someone other than the repository owner carries an
author gate on a precheck job (`check_pr_exists`, `check_branch`, or the
job-level `if:` of a single-job demo). That job stays **secret-free**
deliberately, so a bad trigger is rejected before a runner holding
credentials starts and before a model token is spent. The predicate depends on
the trigger:

- **`issue_comment`** — `github.event.comment.author_association == 'OWNER'`.
  `MEMBER` is **not** accepted — a single merged PR earns `MEMBER` association,
  which is too loose for a trigger that runs an LLM with write permissions.
  With no approval pause behind it, this guard is the **only** boundary, so
  never loosen it.
- **`workflow_dispatch`** — usually **no author gate at all**: only users with
  write access can dispatch a workflow, so the trigger is already restricted.
  An owner-only `github.triggering_actor == github.repository_owner` check also
  never matches on an **org-owned** repo, where `repository_owner` is the org,
  not a person. `demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml` carries
  none. `demo-kimi-openrouter-reviewer.yml` still uses that check, and it only
  works in a user-owned repo. If you do keep one, prefer `triggering_actor`
  over `actor` so a non-owner cannot re-run an owner's earlier dispatch.

### 3.2 Repository secrets

All credentials live as **repository secrets** (Settings → Secrets and
variables → Actions). Each job checks its whole set up front and fails loud,
naming every missing one, rather than letting the CLI die halfway through.
The trade-off of dropping the environment: a repository secret is readable by
every workflow in the repo, on any branch someone with write access pushes,
where an environment secret was readable only by jobs that declared it.

| Secret | Used by | Notes |
| -- | -- | -- |
| `JIRA_ACCOUNT_URL` | every job | e.g. `<your-site>.atlassian.net`, no scheme. |
| `JIRA_ASSIGNER_EMAIL` / `JIRA_ASSIGNER_TOKEN` | assigner job | Assigner's own Jira identity. |
| `JIRA_EXECUTOR_EMAIL` / `JIRA_EXECUTOR_TOKEN` | executor job (+ `_EMAIL` also read by the assigner job, as the assignment target, not a credential) | Executor's own Jira identity. |
| `JIRA_REVIEWER_EMAIL` / `JIRA_REVIEWER_TOKEN` | reviewer job | Reviewer's own Jira identity. |
| `CLAUDE_CODE_OAUTH_TOKEN` | every job on the Claude-Code-backed demos | Read by the `claude` CLI from the environment — never written into the env file. Not used by the FCC + NVIDIA NIM demos, which authenticate to NIM instead (see below). |
| `NVIDIA_NIM_API_KEY` | `demo-fcc-nvidia-nim-feature-flow.yml`, `demo-fcc-nvidia-nim-reviewer.yml`, `demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml` | The FCC + NIM demos' equivalent of `CLAUDE_CODE_OAUTH_TOKEN` — model backend credential instead of the Claude Code CLI's. |

`GITHUB_PAT_TOKEN` is not a secret to create here: every workflow always
populates it from the runner's built-in `secrets.GITHUB_TOKEN`, which can
push, open a PR, and comment given each job's `permissions:` block. It stays
an env-file key (see "Common patterns across the CI demos" above) because
the skills' `statuscheck` reads it from
`.jst/jira-sdlc-tools.local.env` to log `gh` in — a real PAT is only needed
there, for local/dev use. One limitation of the built-in token carries over
unchanged in CI: PRs it opens don't trigger other workflows.

### 3.3 Setting secrets via GitHub CLI

```bash
gh secret set JIRA_ACCOUNT_URL      --repo <OWNER>/<REPO> --body "<your-site>.atlassian.net"
gh secret set JIRA_ASSIGNER_EMAIL   --repo <OWNER>/<REPO> --body "<assigner-identity-email>"
gh secret set JIRA_ASSIGNER_TOKEN   --repo <OWNER>/<REPO> --body "<assigner-api-token>"
gh secret set JIRA_EXECUTOR_EMAIL   --repo <OWNER>/<REPO> --body "<executor-identity-email>"
gh secret set JIRA_EXECUTOR_TOKEN   --repo <OWNER>/<REPO> --body "<executor-api-token>"
gh secret set JIRA_REVIEWER_EMAIL   --repo <OWNER>/<REPO> --body "<reviewer-identity-email>"
gh secret set JIRA_REVIEWER_TOKEN   --repo <OWNER>/<REPO> --body "<reviewer-api-token>"
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <OWNER>/<REPO> --body "<claude-code-oauth-token>"
# Only for the FCC + NVIDIA NIM demos, in place of CLAUDE_CODE_OAUTH_TOKEN
gh secret set NVIDIA_NIM_API_KEY    --repo <OWNER>/<REPO> --body "<nvidia-nim-api-key>"
```

Secrets already stored on a `production` environment from an earlier setup are
**not** visible to these jobs any more. Re-create them at the repository level
with the commands above.

### 3.4 Copy-pasteable gate snippet

For an `issue_comment`-triggered workflow:

```yaml
jobs:
  check_comment:
    name: guard — comment gate
    runs-on: ubuntu-latest
    # Secret-free precheck: decides who may trigger the run
    outputs:
      should_run: ${{ steps.guard.outputs.should_run }}
    steps:
      - id: guard
        if: >-
          contains(github.event.comment.body, '/make-feature') &&
          (github.event.comment.author_association == 'OWNER') &&
          (github.event.issue.pull_request == null)
        run: echo "should_run=true" >> $GITHUB_OUTPUT

  assign:
    name: assigner
    needs: check_comment
    if: needs.check_comment.outputs.should_run == 'true'
    runs-on: ubuntu-latest
    steps:
      # ... skill steps
```

A `workflow_dispatch` workflow needs no author guard (§3.1). Its precheck
validates the dispatch instead — see the `check_branch` job in
[`demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml`](example-workflows/demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml).

______________________________________________________________________

## 4. Quick reference — which demo to start from

| Goal | Start with |
| -- | -- |
| See a full feature flow in CI | `demo-claude-feature-flow.yml` + [ci-feature-flow-demo.md](autopilot/ci-feature-flow-demo.md) |
| See a hotfix flow targeting production | `demo-claude-hotfix-flow.yml` + [ci-hotfix-flow-demo.md](autopilot/ci-hotfix-flow-demo.md) |
| Just want automated PR review on a comment | `demo-claude-reviewer.yml` |
| Turn a commented issue into a Jira Task (or Bug) with the assigner alone | `demo-claude-issue-to-task.yml` / `demo-claude-issue-to-bug.yml` + [ci-issue-to-task-demo.md](chatops/issue-to-task/ci-issue-to-task-demo.md) |
| Try a different LLM backend on the feature flow | `demo-fcc-nvidia-nim-feature-flow.yml` |
| Try a different LLM backend on review only | `demo-fcc-nvidia-nim-reviewer.yml` |
| Review a PR on FCC + NIM with the model picked at dispatch time | `demo-fcc-nvidia-nim-reviewer-workflow-dispatch.yml` |

______________________________________________________________________

## 5. What these demos are not

- **Not a replacement for this repo's own SDLC** — work here is human-driven
  end to end ([SDLC.md](../process/SDLC.md)).
- **Not production incident response** — the hotfix demo exercises the
  *branch semantics* of a hotfix, not an actual incident process.
- **Not a durable pipeline on hosted runners** — worktrees don't persist
  across jobs; each job explicitly rebuilds what it needs from the pushed
  branch.
- **Not a composite action** — bootstrap steps are deliberately duplicated
  across workflow files so each one stays copy-pasteable into another repo
  without pulling in a shared helper file.

______________________________________________________________________

## 6. Related docs

| Document | Covers |
| -- | -- |
| [ci-feature-flow-demo.md](autopilot/ci-feature-flow-demo.md) | Deep dive on `demo-claude-feature-flow.yml` |
| [ci-hotfix-flow-demo.md](autopilot/ci-hotfix-flow-demo.md) | Deep dive on `demo-claude-hotfix-flow.yml` |
| [ci-review-pr-demo.md](chatops/review/ci-review-pr-demo.md) | Deep dive on the review-a-PR scenario and its implementations |
| [ci-issue-to-task-demo.md](chatops/issue-to-task/ci-issue-to-task-demo.md) | Deep dive on `demo-claude-issue-to-task.yml` and its `/make-bug` twin `demo-claude-issue-to-bug.yml` |
| [SDLC.md](../process/SDLC.md) | This repo's actual release/hotfix procedure |
| [CI.md](../process/CI.md) | Workflow-by-workflow CI reference |
| [project-config.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md) | Every `<TOKEN>` resolved from `.jst/jira-sdlc-tools.env` |
