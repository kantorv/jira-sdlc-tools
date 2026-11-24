---
slug: /step-by-step-installation/gh-auth-login
sidebar_position: 2
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
you approve. It's independent of the skills: they pass the PAT to each `gh`
command they run, which takes precedence over any stored login, so this
session is neither used nor touched by them, and there's nothing to switch
back before the next run.
