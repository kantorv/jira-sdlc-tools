---
slug: /step-by-step-installation/software-authentication
sidebar_position: 2
sidebar_label: Software authentication
---

# Software authentication

`git` uses your machine's existing global credentials. `gh` authenticates
with a GitHub PAT (`GITHUB_PAT_TOKEN`) and `jira.sh` with a per-role Jira
API token (`JIRA_EXECUTOR_TOKEN` / `JIRA_ASSIGNER_TOKEN` /
`JIRA_REVIEWER_TOKEN`). The credentials are stored in
`.jst/jira-sdlc-tools.local.env`.
