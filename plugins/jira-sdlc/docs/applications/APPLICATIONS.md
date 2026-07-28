# Applications — how the plugin gets consumed, and the CI demos

> **Scope:** this document has two jobs. §1 explains the two ways the
> `jira-sdlc` plugin can be installed. §2 onward is a guide to the **demo
> GitHub Actions workflows** shipped under
> [`.github/workflows/`](../../../../.github/workflows/) at the marketplace
> repo root — worked examples of running the three skills in CI, meant to be
> read next to the workflow files and copied into other repos. They are
> **not** this repo's own development procedure (human-driven, see
> [SDLC.md](../SDLC.md)).

---

## 1. Summary — two ways to use the plugin

| Mode | How it works | When to use |
|------|--------------|-------------|
| **Claude Code marketplace plugin** | Add the marketplace, then `/plugin install jira-sdlc@<marketplace-name>` via the `/plugin` command. The three skills become available as `/jira-sdlc:jira-task-assigner`, `/jira-sdlc:jira-task-executor`, `/jira-sdlc:jira-task-reviewer`. | Default path — skills stay versioned with the marketplace release, upgrade with a reinstall. |
| **Loose skillset** | Copy `plugins/jira-sdlc/skills/` into a project's own skills folder (e.g. `.claude/skills/`). Invoke unprefixed — `/jira-task-assigner`, etc. | When you want to fork/edit the skills directly, or the target environment doesn't support the marketplace mechanism. Note the local-dev-loop caveat in [CLAUDE.md](../../../../CLAUDE.md): a marketplace install is a cached snapshot, so edits to a clone don't show up there until reinstalled — this is why active skill development should point `--plugin-dir` at a working copy instead. |

Both modes read the same configuration: `.jst/jira-sdlc-tools.env` (team-shared)
and `.jst/jira-sdlc-tools.local.env` (machine-specific, gitignored) in the
target project's root. See [INSTALLATION.md](../INSTALLATION.md) and
[project-config.md](../../skills/_shared/project-config.md) for what each
`<TOKEN>` resolves to.

---

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
[README's usage walkthrough](../../README.md) for that version worked through
end to end.

Either way you answer the assigner's clarifying questions, and approve or fix
the reviewer's findings before merging — full interactive turn at every step.

### 2b. CI usage — GitHub Actions demos

This repo ships several demo workflows under `.github/workflows/` showing how
to run the skills headlessly in CI. Each is self-contained and meant to be
copy-pasted into another repo.

| Workflow file | Trigger | What it does |
|---|---|---|
| [`demo-claude-reviewer.yml`](../../../../.github/workflows/demo-claude-reviewer.yml) | Comment `/review` on a PR | **Reviewer only**, against an already-open PR — a standalone review gate. Deep dive: [ci-review-pr-demo.md](./ci-review-pr-demo.md). |
| [`demo-claude-issue-to-task.yml`](../../../../.github/workflows/demo-claude-issue-to-task.yml) | `issues: opened` | **Assigner only** — turns a newly opened GitHub issue into a Jira task + branch + worktree on the runner. Stops there (nothing persists past the job on a hosted runner). Deep dive: [ci-issue-to-task-demo.md](./ci-issue-to-task-demo.md). |
| [`demo-claude-feature-flow.yml`](../../../../.github/workflows/demo-claude-feature-flow.yml) | Comment `/make-feature` on an issue | **Full feature flow**: assigner → executor → reviewer, chained, one manual-approval gate per skill. Branch `feature/<KEY>-<slug>` off `<DEFAULT_BASE_BRANCH>`; PR targets `<DEFAULT_BASE_BRANCH>`. Deep dive: [ci-feature-flow-demo.md](./ci-feature-flow-demo.md). |
| [`demo-claude-hotfix-flow.yml`](../../../../.github/workflows/demo-claude-hotfix-flow.yml) | Comment `/make-hotfix` on an issue | **Full hotfix flow**, same three-job chain and gating. Branch `hotfix/<KEY>-<slug>` off `origin/<PRODUCTION_BRANCH>`; PR targets `<PRODUCTION_BRANCH>`. Deep dive: [ci-hotfix-flow-demo.md](./ci-hotfix-flow-demo.md). |
| [`demo-fcc-nvidia-nim-feature-flow.yml`](../../../../.github/workflows/demo-fcc-nvidia-nim-feature-flow.yml) | Comment `/fcc-make-feature` on an issue | Same three-job feature flow, but on **Free Claude Code + NVIDIA NIM** as the model backend instead of the Claude Code CLI — shows how to swap the LLM provider. Deliberately a different trigger word than `/make-feature` so the two workflows don't both fire off one comment. |
| [`demo-fcc-nvidia-nim-reviewer.yml`](../../../../.github/workflows/demo-fcc-nvidia-nim-reviewer.yml) | Comment `/fcc-review` on a PR | Reviewer-only, FCC + NVIDIA NIM backend — the provider-swap counterpart to `demo-claude-reviewer.yml`. |
| [`demo-kimi-openrouter-reviewer.yml`](../../../../.github/workflows/demo-kimi-openrouter-reviewer.yml) | Manual `workflow_dispatch` | **Smoke test** — despite the filename, it invokes no skill: it installs Kimi Code, points `extra_skill_dirs` at this plugin, and runs one hand-written review prompt over `gh pr diff`, posting the result to the PR. No worktree, no Jira write, no environment gate. Deep dive: [ci-smoke-test-demo.md](./ci-smoke-test-demo.md). |

#### Common patterns across the CI demos

- **One job per skill**, each a fresh runner VM, each under its own Jira
  identity (assigner/executor/reviewer email + token).
- **No shared disk** — `WORKTREES_DIR` is rebuilt per job under
  `$RUNNER_TEMP/worktrees`. Jobs 2/3 reconstruct a *linked* worktree from the
  branch job 1 pushed; the executor and reviewer skills hard-stop unless
  they're running in a linked worktree on a `feature/*` or `hotfix/*` branch.
- **Environment-gated approvals** — every demo except the smoke test declares
  `environment: production` on its skill jobs. That always scopes their
  secrets, and additionally makes GitHub pause for a human before each job
  *if* the environment has Required reviewers enabled. See §3.
- **Secrets are environment secrets on `production`**, named exactly as the
  `.jst/jira-sdlc-tools.local.env` keys they become — this is what lets a
  job's bootstrap step be a single loop over a `KEYS` list instead of a
  hand-mapped one.
- **No `GH_TOKEN`/`GITHUB_TOKEN` exported into skill steps** — statuscheck
  logs `gh` in from `GITHUB_PAT_TOKEN` read out of the env file; exporting
  either token variable into the environment makes `gh auth login` refuse,
  since it insists the variable be cleared first.
- **Headless, no questions** — skills run with `-p
  --dangerously-skip-permissions`. A run where the assigner would normally
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

| Scenario | What the flow does | Trigger | Approval | Implementations |
|---|---|---|---|---|
| [**Feature flow**](./ci-feature-flow-demo.md) | Full three-skill chain: assigner → executor → reviewer. GitHub issue becomes a Jira issue + `feature/<KEY>-<slug>` branch off `<DEFAULT_BASE_BRANCH>`, gets implemented, and ends as an open reviewed PR into `<DEFAULT_BASE_BRANCH>`. Nothing is merged. | **comment** — bare or with prose | **Up to 3** — `environment: production` on every job (assigner, executor, reviewer) | • [`demo-claude-feature-flow.yml`](../../../../.github/workflows/demo-claude-feature-flow.yml) — Claude Code CLI · `/make-feature`<br>• [`demo-fcc-nvidia-nim-feature-flow.yml`](../../../../.github/workflows/demo-fcc-nvidia-nim-feature-flow.yml) — Free Claude Code + NVIDIA NIM · `/fcc-make-feature` |
| [**Hotfix flow**](./ci-hotfix-flow-demo.md) | The same three-skill chain on the emergency path: `hotfix/<KEY>-<slug>` cut off `origin/<PRODUCTION_BRANCH>`, PR targets `<PRODUCTION_BRANCH>`, and the assigner is forced single-step (no sub-tasks). | **comment** — bare or with prose | **Up to 3** — `environment: production` on every job (assigner, executor, reviewer) | • [`demo-claude-hotfix-flow.yml`](../../../../.github/workflows/demo-claude-hotfix-flow.yml) — Claude Code CLI · `/make-hotfix` |
| [**Review a PR**](./ci-review-pr-demo.md) | Reviewer skill alone, against an already-open PR. Rebuilds a linked worktree for the PR branch, reviews the diff, and posts the verdict to GitHub (as a comment) and Jira. Merges nothing. | **comment** — bare or with prose | **Up to 1** — `environment: production` on the reviewer job; the gating job runs before it, ungated | • [`demo-claude-reviewer.yml`](../../../../.github/workflows/demo-claude-reviewer.yml) — Claude Code CLI · `/review`<br>• [`demo-fcc-nvidia-nim-reviewer.yml`](../../../../.github/workflows/demo-fcc-nvidia-nim-reviewer.yml) — Free Claude Code + NVIDIA NIM · `/fcc-review` |
| [**Issue to task**](./ci-issue-to-task-demo.md) | Assigner alone. A newly opened GitHub issue becomes a Jira task with its branch and worktree, and the run stops there — no implementation, no PR. | **auto** | **Up to 1** — `environment: production` on the assigner job. ⚠️ **Effectively mandatory here**: this is the only demo with no author check, so the approval is the sole guard between any opened issue and an unattended run. | • [`demo-claude-issue-to-task.yml`](../../../../.github/workflows/demo-claude-issue-to-task.yml) — Claude Code CLI · `issues: opened` |
| [**Smoke test**](./ci-smoke-test-demo.md) | **No skill is invoked.** Installs a coding assistant on the runner, points its config at this plugin's `skills/`, and drives one plain inference to prove the backend is wired up — the plumbing check you run *before* trusting a new client or model with a real flow. Answers "does this assistant install, authenticate, find the skills, and return a completion in CI?", nothing more. | **manual** | **None** — declares no `environment`, so it never pauses and reads no environment secrets | • [`demo-kimi-openrouter-reviewer.yml`](../../../../.github/workflows/demo-kimi-openrouter-reviewer.yml) — Kimi Code + OpenRouter · `workflow_dispatch` — installs Kimi, writes a `config.toml` whose `extra_skill_dirs` points at the plugin, then runs one hand-written review prompt over `gh pr diff` and posts the result to the PR |

**"Up to" is doing real work in that column.** `environment: production` in a
workflow file does two separable things, and only one of them is automatic:

- **Always** — it scopes which secrets the job can read. A job without it sees
  empty strings for every environment secret and fails its own up-front check.
- **Only if you ask for it** — it pauses for a human. The pause comes from the
  **Required reviewers** protection rule on the environment itself
  ([§3.1](#31-create-the-environment)), not from the workflow file. Leave that
  box unchecked and every one of these runs start to finish with no approval
  prompt at all, still correctly scoped to the environment's secrets.

So the counts above are the number of jobs that *would* pause — one gate per
gated job — once Required reviewers is enabled. Toggling that one checkbox is
what turns these demos from unattended to fully gated, with no workflow edit.

Four more things the matrix makes visible:

- **The smoke test is the odd one out, and that's the point.** The first four
  rows all invoke skills; the last deliberately doesn't. It's the rung below
  them — when a run fails on a new backend, the smoke test tells you whether
  the assistant is even installed and answering before you go looking for a
  bug in the skills. Run it first on any client you haven't used here before.
- **Backend coverage is uneven, deliberately.** The feature flow and the PR
  review exist on more than one backend because those are the two flows worth
  proving portable; hotfix and issue-to-task ship Claude-only. A missing cell
  is an un-built demo, not an unsupported combination — the skills themselves
  don't know which model is driving them.
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
  appended to the assigner's prompt as a labelled `EXTRA DIRECTION FOR THIS
  RUN` section (the GitHub issue stays the task description), or passed to the
  reviewer as its skill argument, which `jira-task-reviewer` reads as free-form
  notes about the run. A bare command behaves exactly as it always has.

  What this does *not* loosen is the gate: the author check (OWNER/MEMBER) and
  the issue-vs-PR check are untouched and still live in the job-level `if:`,
  the prose is never gating input, and the command still has to be the first
  token followed by a separator — `/reviewer-anything` and a mid-sentence
  mention both stay inert.

---

## 3. Production environment settings

Every demo except the smoke test binds its skill jobs to a GitHub
**Environment** named `production`. That binding is what scopes their secrets,
and — once you add the Required reviewers rule — what implements one manual
approval per skill run.

### 3.1 Create the environment

1. Repo **Settings → Environments → New environment**.
2. Name it **`production`** — this exact name is hardcoded in the workflows.
3. *(Optional, but the point of the demos)* Check **Required reviewers** and
   add the approver(s). **This is the step the approval gates come from — with
   it unchecked the workflows still run, just unattended.** Steps 1–2 alone
   only give the jobs access to the environment's secrets.
4. Click **Save protection rules**.

### 3.2 What each gate buys you

Assuming Required reviewers is enabled:

| Job | Pauses before | What you can inspect at that point |
|---|---|---|
| **Assigner** | Job starts | Nothing yet created — first chance to decide the issue is even worth turning into work. |
| **Executor** | Job starts | Jira issue exists, `feature/*`/`hotfix/*` branch is pushed — inspect before any code gets written. |
| **Reviewer** | Job starts | Implementation is pushed, PR is open — eyeball the diff before spending review tokens on it. |

One `production` environment reused by every job is enough — the rule fires
per job, so it still yields one checkpoint per skill.

### 3.3 Environment secrets

All credentials live as **environment secrets on `production`**, not
repo-level secrets — a job that forgets `environment: production` reads
empty strings and fails its own up-front secret check rather than silently
running with the wrong identity.

| Secret | Used by | Notes |
|---|---|---|
| `JIRA_ACCOUNT_URL` | every job | e.g. `<your-site>.atlassian.net`, no scheme. |
| `JIRA_ASSIGNER_EMAIL` / `JIRA_ASSIGNER_TOKEN` | assigner job | Assigner's own Jira identity. |
| `JIRA_EXECUTOR_EMAIL` / `JIRA_EXECUTOR_TOKEN` | executor job (+ `_EMAIL` also read by the assigner job, as the assignment target, not a credential) | Executor's own Jira identity. |
| `JIRA_REVIEWER_EMAIL` / `JIRA_REVIEWER_TOKEN` | reviewer job | Reviewer's own Jira identity. |
| `CLAUDE_CODE_OAUTH_TOKEN` | every job on the Claude-Code-backed demos | Read by the `claude` CLI from the environment — never written into the env file. Not used by the FCC + NVIDIA NIM demos, which authenticate to NIM instead (see below). |
| `NVIDIA_NIM_API_KEY` | `demo-fcc-nvidia-nim-feature-flow.yml`, `demo-fcc-nvidia-nim-reviewer.yml` | The FCC + NIM demos' equivalent of `CLAUDE_CODE_OAUTH_TOKEN` — model backend credential instead of the Claude Code CLI's. |

`GITHUB_PAT_TOKEN` is not a secret to create here: every workflow always
populates it from the runner's built-in `secrets.GITHUB_TOKEN`, which can
push, open a PR, and comment given each job's `permissions:` block. It stays
an env-file key (see "Common patterns across the CI demos" above) because
the skills' `statuscheck` reads it from
`.jst/jira-sdlc-tools.local.env` to log `gh` in — a real PAT is only needed
there, for local/dev use. One limitation of the built-in token carries over
unchanged in CI: PRs it opens don't trigger other workflows.

### 3.4 Setting secrets via GitHub CLI

```bash
gh secret set JIRA_ACCOUNT_URL      --repo <OWNER>/<REPO> --body "<your-site>.atlassian.net" --env production
gh secret set JIRA_ASSIGNER_EMAIL   --repo <OWNER>/<REPO> --body "<assigner-identity-email>"  --env production
gh secret set JIRA_ASSIGNER_TOKEN   --repo <OWNER>/<REPO> --body "<assigner-api-token>"        --env production
gh secret set JIRA_EXECUTOR_EMAIL   --repo <OWNER>/<REPO> --body "<executor-identity-email>"  --env production
gh secret set JIRA_EXECUTOR_TOKEN   --repo <OWNER>/<REPO> --body "<executor-api-token>"        --env production
gh secret set JIRA_REVIEWER_EMAIL   --repo <OWNER>/<REPO> --body "<reviewer-identity-email>"  --env production
gh secret set JIRA_REVIEWER_TOKEN   --repo <OWNER>/<REPO> --body "<reviewer-api-token>"        --env production
gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <OWNER>/<REPO> --body "<claude-code-oauth-token>" --env production
# Only for the FCC + NVIDIA NIM demos, in place of CLAUDE_CODE_OAUTH_TOKEN
gh secret set NVIDIA_NIM_API_KEY    --repo <OWNER>/<REPO> --body "<nvidia-nim-api-key>"         --env production
```

`--env production` scopes each secret to that environment, so it's only
readable from jobs that declare `environment: production`.

---

## 4. Quick reference — which demo to start from

| Goal | Start with |
|---|---|
| See a full feature flow in CI with approval gates | `demo-claude-feature-flow.yml` + [ci-feature-flow-demo.md](./ci-feature-flow-demo.md) |
| See a hotfix flow targeting production | `demo-claude-hotfix-flow.yml` + [ci-hotfix-flow-demo.md](./ci-hotfix-flow-demo.md) |
| Just want automated PR review on a comment | `demo-claude-reviewer.yml` |
| Auto-create a Jira task when someone opens a GitHub issue | `demo-claude-issue-to-task.yml` |
| Try a different LLM backend on the feature flow | `demo-fcc-nvidia-nim-feature-flow.yml` |
| Try a different LLM backend on review only | `demo-fcc-nvidia-nim-reviewer.yml` |
| Just confirm a new client installs, finds the skills, and can infer at all | `demo-kimi-openrouter-reviewer.yml` (the smoke-test scenario) |

---

## 5. What these demos are not

- **Not a replacement for this repo's own SDLC** — work here is human-driven
  end to end ([SDLC.md](../SDLC.md)).
- **Not production incident response** — the hotfix demo exercises the
  *branch semantics* of a hotfix, not an actual incident process.
- **Not a durable pipeline on hosted runners** — worktrees don't persist
  across jobs; each job explicitly rebuilds what it needs from the pushed
  branch.
- **Not a composite action** — bootstrap steps are deliberately duplicated
  across workflow files so each one stays copy-pasteable into another repo
  without pulling in a shared helper file.

---

## 6. Related docs

| Document | Covers |
|---|---|
| [ci-feature-flow-demo.md](./ci-feature-flow-demo.md) | Deep dive on `demo-claude-feature-flow.yml` |
| [ci-hotfix-flow-demo.md](./ci-hotfix-flow-demo.md) | Deep dive on `demo-claude-hotfix-flow.yml` |
| [ci-review-pr-demo.md](./ci-review-pr-demo.md) | Deep dive on the review-a-PR scenario and its two implementations |
| [ci-issue-to-task-demo.md](./ci-issue-to-task-demo.md) | Deep dive on `demo-claude-issue-to-task.yml` |
| [ci-smoke-test-demo.md](./ci-smoke-test-demo.md) | The no-skill backend check — `demo-kimi-openrouter-reviewer.yml` |
| [SDLC.md](../SDLC.md) | This repo's actual release/hotfix procedure |
| [CI.md](../CI.md) | Workflow-by-workflow CI reference |
| [INSTALLATION.md](../INSTALLATION.md) | Installing the plugin / loose skills |
| [project-config.md](../../skills/_shared/project-config.md) | Every `<TOKEN>` resolved from `.jst/jira-sdlc-tools.env` |
