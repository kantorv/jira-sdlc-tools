---
slug: /step-by-step-installation/verify-jira-authentication
sidebar_position: 5
sidebar_label: Verify Jira authentication
---

# Verify Jira authentication

There is no login step. The client sends your email and token as Basic auth on
each request. `_edge/tenant_info` gives you the cloud id; `/myself` proves the
token:

```bash
CLOUD_ID=$(curl -fsSL "https://$JIRA_ACCOUNT_URL/_edge/tenant_info" | jq -r .cloudId)
curl -sS -u "$JIRA_EXECUTOR_EMAIL:$JIRA_EXECUTOR_TOKEN" -H "Accept: application/json" \
  "https://api.atlassian.com/ex/jira/$CLOUD_ID/rest/api/3/myself" | jq -r .emailAddress
```

Getting your own email back means the pair works. The statuscheck will verify
each role separately later.
