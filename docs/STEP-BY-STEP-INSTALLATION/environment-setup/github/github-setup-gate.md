---
slug: /step-by-step-installation/github-setup-gate
sidebar_position: 8
sidebar_label: GitHub setup gate
---

# GitHub setup gate

Run the gate again after GitHub setup. At this point the GitHub-related rows
(`gh_auth`, `gh_repo_access`, `git_repo`, `base_branch`/`production_branch`,
`branch_pair`, and `worktrees_dir`) should be resolved. Jira rows are still
expected to be unresolved until the Jira section.

```bash
STATUSCHECK_RERUN='rerun /jira-sdlc:jst-install' \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role executor
```
