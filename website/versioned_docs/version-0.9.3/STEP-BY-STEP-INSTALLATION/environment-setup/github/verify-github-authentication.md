---
slug: /step-by-step-installation/verify-github-authentication
sidebar_position: 4
sidebar_label: Verify GitHub authentication
---

# Verify GitHub authentication

Log `gh` in with the PAT:

```bash
echo "$GITHUB_PAT_TOKEN" | gh auth login --with-token && gh auth status
```

The PAT is used for the whole run, so all three skills act as the same GitHub
identity — unlike Jira, there is no per-role split.
