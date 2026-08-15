---
slug: /jira-state-movements
sidebar_position: 12
---

# Jira state movements — how a card's status gets moved

A card moves through four anchor statuses — `<STATUS_TODO>`,
`<STATUS_IN_PROGRESS>`, `<STATUS_IN_REVIEW>`, `<STATUS_DONE>` — and four
mechanisms can move it: the three skills, this repo's GitHub Actions
workflows, a Jira automation app (GitHub for Jira or your own rules), and
direct REST calls. This hub is the overview of *which mechanism does what*;
each one has its own detailed doc, cited in the sections below.

The four `<STATUS_*>` are configurable tokens you map onto your board's real
status names in `.jst/jira-sdlc-tools.env`.

## Who can move a card where — at a glance

✅ does it · ⚠️ only with your confirmation · ❌ never

| Who | `<STATUS_TODO>` | `<STATUS_IN_PROGRESS>` | `<STATUS_IN_REVIEW>` | `<STATUS_DONE>` |
| -- | -- | -- | -- | -- |
| **You** | ✅ anytime — usually just the creation default | ✅ anytime | ✅ anytime | ✅ anytime — `jira.sh issue transition <KEY> --to …`, or drag the card |
| **[`jira-task-assigner`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jira-task-assigner/SKILL.md)** | ❌ it creates the issue and lets your workflow's creation default stand | ❌ | ❌ | ❌ transitions nothing at all — issues, branches and worktrees only |
| **[`jira-task-executor`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jira-task-executor/SKILL.md)** | ❌ | ✅ step 3, when it picks the issue up | ✅ step 11, right after it opens the PR | ❌ step 11 explicitly leaves Done to the merge, whoever does it |
| **[`jira-task-reviewer`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jira-task-reviewer/SKILL.md)** | ❌ | ✅ step 3d, on a CHANGES REQUESTED verdict — sub-task or single-step only, never the multistep parent on a 5b reject | ❌ it only *reads* this status, to pick which sub-tasks to review | ⚠️ step 7 asks once at the end of a run, for approved issues only, and moves nothing you don't confirm |
| **[GitHub Actions](STATE-TRANSITIONS-WITH-GITHUB-ACTIONS.md)** | ❌ none ships | ✅ `jira_issue_transition_on_branch.yml` — on `create` of a `feature/*`/`hotfix/*` branch, and only from `<STATUS_TODO>` | ✅ `jira_issue_transition_on_pr_open.yml` — on PR opened/reopened, skipped if already In Review or Done | ✅ `jira_issue_transition_on_merge.yml` — on PR closed-as-merged, skipped if already Done |
| **[Jira Automation](INSTALLING-GITHUB-FOR-JIRA.md)** (incl. GitHub for Jira) | ✅ possible (a rule on issue create), rarely needed | ✅ possible — e.g. the dev-panel *branch created* trigger | ✅ possible — e.g. the *pull request created* trigger | ✅ the common one — *pull request merged*, or *all sub-tasks Done → close the parent* |

The **GitHub Actions** row is **this repo's own CI** (`.github/workflows/`),
not files the plugin installs — a marketplace install copies only
`plugins/jira-sdlc/`. Copy the three workflows into your project to get that
row.

Read the three skill rows down a column for that state's whole skill-side
story; read across to compare the four mechanisms. The sections below hand
off to each mechanism's detailed doc.

## Moving inside the skills

The three skills make three transitions themselves and ask about one: the
executor to In Progress (on pickup, step 3) and In Review (right after
opening the PR, step 11); the reviewer back to In Progress on a
CHANGES-REQUESTED verdict (step 3d); and the reviewer's end-of-run question
about whether to close an approved issue (step 7). The assigner transitions
nothing — issues, branches, and worktrees only. Full detail — which step,
what each state means, what no skill does — is in
**[JIRA-STATES.md](JIRA-STATES.md)**.

## Moving with GitHub Actions

Three workflows move an issue from git events with no skill running —
`jira_issue_transition_on_branch.yml` (branch `create` → In Progress, only
from `<STATUS_TODO>`), `jira_issue_transition_on_pr_open.yml` (PR opened →
In Review), and `jira_issue_transition_on_merge.yml` (PR merged → Done). Each
re-reads the issue first and stands down rather than regressing it, so
they're safe to run alongside the skills. Copying them in, the secrets, the
status-name literals, and the guards are documented in
**[Driving Jira state from GitHub Actions](STATE-TRANSITIONS-WITH-GITHUB-ACTIONS.md)**.

## GitHub for Jira

The GitHub for Jira app links your branches and PRs to issues and can drive
automations — including the common *pull request merged → move to
`<STATUS_DONE>`* and *all sub-tasks Done → close the parent* rules — with the
least setup of any mechanism. It's recommended, not required: the skills
work without it; what you lose is the automatic linking. Connection and
automation-rule setup is in
**[Installing GitHub for Jira](INSTALLING-GITHUB-FOR-JIRA.md)**.

## API

`jira.sh` (POSIX) / `jira.ps1` (Windows) is this plugin's own bundled Jira
REST client — what every skill and workflow above calls under the hood. It
authenticates **per request as a role** (`--role executor|assigner|reviewer`,
no login step), and a transition is one call:
`jira.sh --role <role> issue transition <KEY> --to "<STATUS>"`, which
resolves the status *name* to the transition *id* for you. Full detail — the
command surface, auth, ADF/comment mechanics, and the git/branch
conventions — is in **[JIRA-REST.md](JIRA-REST.md)** (the detailed companion)
and the lean runtime reference
**[`jira-api-reference.md`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/jira-api-reference.md)**.

## External tools (not used)

`acli` and `jira-cli` are Jira CLI alternatives this project deliberately
does **not** use to move state. The toolkit's earlier `acli` usage was
replaced by the bundled `jira.sh` REST client above; `jira-cli` has
project-specific failures `jira.sh` gets right — notably that it silently
drops the parent on sub-task create. The full reasoning is in
**[rest-client-design.md](rest-client-design.md)** (why `jira.sh` exists in
place of `acli`) and **[JIRA-REST.md](JIRA-REST.md) §11** (the `jira-cli`
cross-reference).
