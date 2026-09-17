---
slug: /step-by-step-installation/gh-auth-login
sidebar_position: 4
sidebar_label: gh auth login
---

# `gh auth login`

The [PAT](pat.md) the skills use is deliberately scoped to
`Contents`/`Pull requests` — enough to run the workflow, not enough to
inspect it. For manual debugging that needs more — reading GitHub Actions
run logs, managing repository settings — log `gh` in interactively instead:

```bash
gh auth login
```

This opens a browser-based or device-code flow and grants whatever scopes
you approve, independent of the PAT session the skills use. Log back in
with the PAT (see [Verify GitHub authentication](../verify-github-authentication.md))
before running the skills again, since only one `gh` identity is active at
a time.
