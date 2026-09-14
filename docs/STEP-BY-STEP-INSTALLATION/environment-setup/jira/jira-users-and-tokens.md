---
slug: /step-by-step-installation/jira-users-and-tokens
sidebar_position: 4
sidebar_label: Jira users and tokens
---

# Jira users and tokens

You can use one Jira account for all three roles, or separate accounts for
`assigner`, `executor`, and `reviewer`.

Create a **classic Jira API token** for each role you use. The required
permissions/scopes are:

- `read:jira-user`
- `read:jira-work`
- `write:jira-work`

The tokens are **per-role** and are sent as per-request Basic authentication;
there is no login session to share.

See [Creating Jira tokens](../../../process/SECURITY.md#jira).
