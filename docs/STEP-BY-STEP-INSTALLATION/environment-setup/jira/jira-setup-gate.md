---
slug: /step-by-step-installation/jira-setup-gate
sidebar_position: 8
sidebar_label: Jira setup gate
---

# Jira setup gate

Run the gate after the Jira configuration is recorded. `env_config`, `jira_auth`,
and `jira_project` should now be resolved.

```bash
STATUSCHECK_RERUN='rerun /jira-sdlc:jst-install' \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role executor
```
