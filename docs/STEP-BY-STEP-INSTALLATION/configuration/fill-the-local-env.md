---
slug: /step-by-step-installation/fill-the-local-env
sidebar_position: 2
sidebar_label: Fill .jst/jira-sdlc-tools.local.env
---

# Fill `.jst/jira-sdlc-tools.local.env`

Open `.jst/jira-sdlc-tools.local.env` in your editor and fill in:

```text
WORKTREES_DIR=/absolute/path/to/worktrees/PROJ-worktrees
JIRA_ACCOUNT_URL=your-jira-site.atlassian.net

JIRA_ASSIGNER_EMAIL=assigner@example.com
JIRA_ASSIGNER_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX
JIRA_EXECUTOR_EMAIL=executor@example.com
JIRA_EXECUTOR_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX
JIRA_REVIEWER_EMAIL=reviewer@example.com
JIRA_REVIEWER_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX

GITHUB_PAT_TOKEN=XXXXXXXXXXXXX
```

`WORKTREES_DIR` must be an **absolute** path. The Jira values are the six
per-role email/token variables; the same Jira account may be used for all three
roles. Tokens are raw values, not paths to files.

Do not paste this file into logs or otherwise print it: it contains the live Jira
credentials and GitHub PAT.
