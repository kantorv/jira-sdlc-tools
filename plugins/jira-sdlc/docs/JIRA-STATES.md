# Jira states — who moves a card, and when

The four `<STATUS_*>` tokens in `jira-sdlc-tools.env` are **anchor
states**: names mapped onto whichever real statuses your board uses for
those roles. This document says which moves the skills make themselves,
which they ask about, and which belong to you.

## Who can move a card where — at a glance

✅ does it · ⚠️ only with your confirmation · ❌ never

| Who | `<STATUS_TODO>` | `<STATUS_IN_PROGRESS>` | `<STATUS_IN_REVIEW>` | `<STATUS_DONE>` |
|---|---|---|---|---|
| **You** | ✅ anytime — usually just the creation default | ✅ anytime | ✅ anytime | ✅ anytime — `acli … transition`, or drag the card |
| **[`jira-task-assigner`](../skills/jira-task-assigner/SKILL.md)** | ❌ it creates the issue and lets your workflow's creation default stand | ❌ | ❌ | ❌ transitions nothing at all — issues, branches and worktrees only |
| **[`jira-task-executor`](../skills/jira-task-executor/SKILL.md)** | ❌ | ✅ step 3, when it picks the issue up | ✅ step 11, right after it opens the PR | ❌ step 11 explicitly leaves Done to the merge, whoever does it |
| **[`jira-task-reviewer`](../skills/jira-task-reviewer/SKILL.md)** | ❌ | ✅ step 3d, on a CHANGES REQUESTED verdict — sub-task or single-step only, never the multistep parent on a 5b reject | ❌ it only *reads* this status, to pick which sub-tasks to review | ⚠️ step 7 asks once at the end of a run, for approved issues only, and moves nothing you don't confirm |
| **[GitHub Actions](STATE-TRANSITIONS-WITH-GITHUB-ACTIONS.md)** [^ci] | ❌ none ships | ✅ `jira_issue_transition_on_branch.yml` — on `create` of a `feature/*`/`hotfix/*` branch, and only from `<STATUS_TODO>` | ✅ `jira_issue_transition_on_pr_open.yml` — on PR opened/reopened, skipped if already In Review or Done | ✅ `jira_issue_transition_on_merge.yml` — on PR closed-as-merged, skipped if already Done |
| **[Jira Automation](INSTALLING-GITHUB-FOR-JIRA.md)** (incl. GitHub for Jira) | ✅ possible (a rule on issue create), rarely needed | ✅ possible — e.g. the dev-panel *branch created* trigger | ✅ possible — e.g. the *pull request created* trigger | ✅ the common one — *pull request merged*, or *all sub-tasks Done → close the parent* |

[^ci]: These three workflows are **this repo's own CI** (`.github/workflows/`),
not files the plugin installs — a marketplace install copies only
`plugins/jira-sdlc/`. Copy them into your project to get these rows; setup,
secrets and guards are in
[STATE-TRANSITIONS-WITH-GITHUB-ACTIONS.md](STATE-TRANSITIONS-WITH-GITHUB-ACTIONS.md).

Read the three skill rows down a column and you get that state's whole
skill-side story — `<STATUS_IN_REVIEW>`, for instance, is written by the
executor and only read by the reviewer, which is why suppressing step 11
makes work invisible to review rather than merely mislabelled.

The skills and the workflows overlap on In Progress and In Review by design,
and running both is safe: each workflow re-reads the issue's current status
and skips when the move would be a no-op or a regression, so whichever gets
there first wins and the other stands down.

## The three transitions a skill makes

| # | Skill | When | Transition |
|---|---|---|---|
| 1 | `jira-task-executor` | it picks the issue up (step 3) | → `<STATUS_IN_PROGRESS>` |
| 2 | `jira-task-executor` | it has just opened the PR (step 11) | → `<STATUS_IN_REVIEW>` |
| 3 | `jira-task-reviewer` | verdict is CHANGES REQUESTED on a sub-task or single-step PR (step 3d) | → `<STATUS_IN_PROGRESS>` |

Transition 2 is load-bearing beyond reporting: on the multistep track
`jira-task-reviewer` reviews only sub-tasks sitting in
`<STATUS_IN_REVIEW>`. Suppress it without arranging another way to set that
status and the work becomes invisible to review.

Transition 3 is what makes a reject resumable: the fix is an executor
re-run, and the executor picks work up from `<STATUS_IN_PROGRESS>`, so the
reject hands the issue back to the skill that will act on it.

**A rejected aggregate parent PR (reviewer step 5b) is deliberately not
symmetric with it** — it gets its verdict comment and no transition.
Nothing calls the executor on `<PARENT-BRANCH>`; integration findings are
fixed there by hand, so moving the parent to `<STATUS_IN_PROGRESS>` would
gate nothing and would only misreport who is holding the work. The parent
stays where it is — normally `<STATUS_IN_REVIEW>` — until it reaches
`<STATUS_DONE>`.

## The one transition a skill asks about

**`<STATUS_DONE>`, at the end of a review run.** When `jira-task-reviewer`
approved anything, its last step (step 7, after the run report is posted)
names every approved issue and asks whether to move them to
`<STATUS_DONE>` — and transitions only what you say yes to. Decline, or run
it non-interactively, and nothing moves.

It asks rather than decides because an approval is not a merge. The
reviewer never merges, so every PR it just approved is still open, and on
boards where Done means merged, closing the card now would jump ahead of
whatever closes it for real. Boards that close at approval want exactly the
opposite. Nothing in the repo says which kind yours is. Mid-loop the
question doesn't arise at all: step 3d records the verdict and explicitly
leaves status alone.

Say no and the card is closed by one of the other three rows in the table:
you by hand, a merge workflow like this repo's
`jira_issue_transition_on_merge.yml` ([CI.md](CI.md)), or a Jira rule —
either the GitHub-for-Jira app's merge automation
([INSTALLING-GITHUB-FOR-JIRA.md](INSTALLING-GITHUB-FOR-JIRA.md)) or your own,
e.g. *all sub-tasks Done → move the Story to Done*
([JIRA-KANBAN-BOARD.md](JIRA-KANBAN-BOARD.md)). With none of them wired up and
the question declined, cards simply stay in `<STATUS_IN_REVIEW>` after their
PRs merge — expected, not a bug.

## What no skill does

- **Nothing sets `<STATUS_DONE>` unprompted.** The reviewer's step-7
  question is the only skill-side path, and it needs your yes.
- **Nothing sets `<STATUS_TODO>`.** New issues land in whatever status your
  workflow makes the creation default; the token exists so the rest of the
  config can name that state.
- **`jira-task-assigner` transitions nothing.** It creates issues,
  branches, and worktrees, and leaves status alone.
- **Nothing moves a card through intermediate states** your board may have
  between these anchors. That's the anchor-mapping contract: the skills
  touch the anchors, everything between them is yours.
