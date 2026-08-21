---
slug: /preparing-environment
sidebar_position: 2
sidebar_label: 1. Preparing environment
---

# Section 1. Preparing environment

1. **Install the required tools** — `git` and `gh`. There is nothing to
   install for Jira: the skills drive it over the REST API through their own
   client, `jira.sh` / `jira.ps1`, which ships with the plugin. On Linux and
   macOS that client needs `curl` and `jq` on your `PATH`; the Windows
   PowerShell port uses built-in cmdlets and needs neither.
2. **Have a git repository and a Jira account with a board created.**
   [GitHub for Jira](../setup/INSTALLING-GITHUB-FOR-JIRA.md) is a great, recommended
   integration — but it is **not** required.
3. **Generate your tokens:** a **granular** `GITHUB_PAT`, and a **classic**
   Jira API token for each of the three roles — assigner, executor, reviewer
   (see the note in [SECURITY.md](../process/SECURITY.md) on why the Jira tokens must be
   classic).
4. **Define your main repository and worktrees dir in the settings** — an
   absolute path, never a relative one:
   ```
   WORKTREES_DIR=/home/you/src/myapp-worktrees
   ```

## Verify your tokens

**Jira** — there is no login step. The client sends your email and token as
Basic auth on each request, so "verifying" is just making one authenticated
call. `_edge/tenant_info` is unauthenticated and gives you the cloud id;
`/myself` is the part that proves the token:

```bash
CLOUD_ID=$(curl -fsSL "https://$JIRA_ACCOUNT_URL/_edge/tenant_info" | jq -r .cloudId)
curl -sS -u "$JIRA_EXECUTOR_EMAIL:$JIRA_EXECUTOR_TOKEN" -H "Accept: application/json" \
  "https://api.atlassian.com/ex/jira/$CLOUD_ID/rest/api/3/myself" | jq -r .emailAddress
```

Getting your own email back means the pair works. The [Section 4
healthcheck](RUN-THE-HEALTHCHECK.md) makes the same call, so you can also just
skip ahead to it.

**GitHub** — log `gh` in with your PAT:

```bash
echo "$GITHUB_PAT_TOKEN" | gh auth login --with-token && gh auth status
```

## Your settings should look like this

```
WORKTREES_DIR=/path/to/worktrees/PROJ-worktrees

JIRA_ACCOUNT_URL=your-jira-site.atlassian.net

# Required — one Jira account per role, so the board shows who did what.
# All six values, no default pair behind them; point all three at the same
# Atlassian account if you'd rather not split them.
JIRA_ASSIGNER_EMAIL=assigner@example.com
JIRA_ASSIGNER_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX
JIRA_EXECUTOR_EMAIL=executor@example.com
JIRA_EXECUTOR_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX
JIRA_REVIEWER_EMAIL=reviewer@example.com
JIRA_REVIEWER_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX

GITHUB_PAT_TOKEN="XXXXXXXXXXXXX"
```

Each `JIRA_<ROLE>_TOKEN` is the token **value**, not a path to a file holding
it. Every variable above is described in
[plugins/jira-sdlc/skills/\_shared/project-config.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md).

Next: [Section 2. GitHub repository preparation](GITHUB-REPOSITORY-PREPARATION.md).
