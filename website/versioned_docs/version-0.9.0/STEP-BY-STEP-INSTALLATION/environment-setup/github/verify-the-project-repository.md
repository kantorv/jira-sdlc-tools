---
slug: /step-by-step-installation/verify-the-project-repository
sidebar_position: 9
sidebar_label: Verify the project repository
---

# Verify the project repository

Run these checks from the **project root of the repository where you will build
features** — not from a clone of `jira-sdlc-tools` itself:

```bash
git rev-parse --show-toplevel && git remote get-url origin
```

Both commands must succeed. This setup connects an existing GitHub repository
and an existing Jira board; it does **not** create either one.
