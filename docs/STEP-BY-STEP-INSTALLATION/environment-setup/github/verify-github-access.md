---
slug: /step-by-step-installation/verify-github-access
sidebar_position: 5
sidebar_label: Verify GitHub access
---

# Verify GitHub access

The final GitHub verification has two distinct parts: `gh_auth` proves that the
PAT can log `gh` in, while `gh_repo_access` proves that the authenticated identity
can access the actual repository. A successful login alone is not sufficient.

```bash
echo "$GITHUB_PAT_TOKEN" | gh auth login --with-token && gh auth status
```

The statuscheck also checks repository access. A fine-grained PAT must be scoped
to the repository you are actually configuring; `Contents` and `Pull requests`
must both be read/write.
