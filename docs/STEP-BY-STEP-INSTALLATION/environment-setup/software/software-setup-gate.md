---
slug: /step-by-step-installation/software-setup-gate
sidebar_position: 5
sidebar_label: Software setup gate
---

# Software setup gate

After the local file is filled in, run the statuscheck gate. During this first
phase, `jst_dir`, `env_local`, `env_local_ignored`, and `platform` should be the
rows this phase establishes; later GitHub/Jira rows are expected to remain
unresolved until their sections are completed.

```bash
STATUSCHECK_RERUN='rerun /jira-sdlc:jst-install' \
  bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role executor
```

On Windows, use the bundled `statuscheck.ps1` equivalent. The installer skill
uses the same gate after each setup section.
