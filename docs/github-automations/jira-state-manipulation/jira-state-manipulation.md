---
slug: /github-automations/jira-state-manipulation
sidebar_position: 1
sidebar_label: Overview
---

# Jira state manipulation

> **Scope:** the two *active* workflows here keep a Jira issue's **status**
> field in sync with what actually happened to its branch on GitHub — no
> skill, no LLM call, just a REST transition. They are not part of the
> assigner/executor/reviewer lifecycle documented in the other three
> subfolders; they run unconditionally on every `feature/*`/`hotfix/*` PR,
> whether or not that issue was ever planned with `jira-sdlc`.

## The workflows

| Workflow file | Trigger | What it does |
| -- | -- | -- |
| [`jira_issue_transition_on_pr_open.yml`](https://github.com/kantorv/jira-sdlc-tools/blob/main/.github/workflows/jira_issue_transition_on_pr_open.yml) | PR opened/reopened, head branch `feature/*` or `hotfix/*` | Transitions the issue to **In Review**. No-ops if already In Review or Done — it never regresses a later status. |
| [`jira_issue_transition_on_merge.yml`](https://github.com/kantorv/jira-sdlc-tools/blob/main/.github/workflows/jira_issue_transition_on_merge.yml) | PR closed **and** merged, head branch `feature/*` or `hotfix/*` | Transitions the issue to **Done**. No-ops if already Done. |

Both extract the Jira key from the branch name
(`^(feature|hotfix)/([A-Z]+-[0-9]+)-`) — a branch that doesn't match the
pattern (e.g. `release/*`) is skipped with no error, which is also why
neither declares a job-level `if:` beyond the `startsWith` branch-prefix
check: letting the step itself no-op on a non-issue branch means one fewer
place the guard logic has to agree with its sibling.

Both authenticate the same way as the skills' own `jira.sh`: resolve the
Atlassian **cloud id** from the site's public `tenant_info` endpoint, then
call `api.atlassian.com/ex/jira/<cloud id>/rest/api/3/...` with Basic auth —
a scoped API token is rejected on the `*.atlassian.net` domain directly, only
the gateway accepts it. Because the transition **id** (not the status name)
is what the REST API accepts, each run resolves it dynamically from
`GET .../transitions` rather than hardcoding one — the same id can differ
between Jira projects with a customized workflow.

### Secrets

Both jobs read from **repo-level** secrets (no `environment:` gate — these
are unconditional housekeeping, not something a human needs to approve per
run):

| Secret | Used for |
| -- | -- |
| `JIRA_ACCOUNT_URL` | Site host, e.g. `<your-site>.atlassian.net` (a scheme is stripped if present). |
| `JIRA_ACCOUNT_EMAIL` | The identity the transition is made as. |
| `JIRA_ISSUE_TRANSITION_TOKEN` | API token for that identity — deliberately a separate secret from the assigner/executor/reviewer tokens (see [ChatOps → the two-gate convention](../GITHUB-AUTOMATIONS.md#3-the-two-gate-convention-for-assistant-workflows) for why per-role credentials matter elsewhere in this repo too). |

## The third file: `jira_issue_transition_on_branch.yml`

[`jira_issue_transition_on_branch.yml`](https://github.com/kantorv/jira-sdlc-tools/blob/main/.github/workflows/jira_issue_transition_on_branch.yml)
would advance **To Do → In Progress** on branch creation, mirroring the other
two. It ships with a hardcoded `if: false` (the real condition is left
commented out just below it) — GitHub's `create` event fires for every
branch and tag push across the whole repo with no way to filter it
server-side, so enabling this one means paying for a runner on every branch
anyone creates, issue or not, just to `exit 0` on the ones that don't match.
It's kept in the repo as the ready-to-flip template for that transition
rather than deleted, since the extraction/auth/transition logic is otherwise
identical to its two active siblings.
