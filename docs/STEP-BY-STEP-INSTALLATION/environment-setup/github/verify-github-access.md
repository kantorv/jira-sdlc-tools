---
slug: /step-by-step-installation/verify-github-access
sidebar_position: 7
sidebar_label: Verify GitHub access
---

# Verify GitHub access

The final GitHub verification has two distinct parts: `gh_auth` proves that the
PAT authenticates, while `gh_repo_access` proves that the authenticated identity
can access the actual repository. A token that authenticates is not sufficient
on its own. Both run through `gh.sh`, which passes the PAT to that one `gh`
command; `gh` is never logged in. To probe the repository by hand from the
project root, the same way:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/gh.sh" api repos/<OWNER>/<REPO> --jq .full_name
```

The statuscheck also checks repository access. A fine-grained PAT must be scoped
to the repository you are actually configuring; `Contents` and `Pull requests`
must both be read/write.
