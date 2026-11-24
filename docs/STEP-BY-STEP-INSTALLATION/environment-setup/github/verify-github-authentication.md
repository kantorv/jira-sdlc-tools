---
slug: /step-by-step-installation/verify-github-authentication
sidebar_position: 4
sidebar_label: Verify GitHub authentication
---

# Verify GitHub authentication

Check that the PAT authenticates — from the project root, through the same
wrapper the skills use:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/gh.sh" api user --jq .login   # prints the PAT's account
```

On Windows, `pwsh -File <plugin-root>\skills\_shared\scripts\win\gh.ps1 api user --jq .login`.

`gh.sh` reads `GITHUB_PAT_TOKEN` from `.jst/jira-sdlc-tools.local.env` and hands it
to `gh` as `GH_TOKEN` for that one command. Nothing logs `gh` in, so your own `gh`
session is left exactly as it was. Every `gh` call in every skill carries this
PAT, so all three skills act as the same GitHub identity — unlike Jira, there is
no per-role split.
