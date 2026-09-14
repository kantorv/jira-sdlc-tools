---
slug: /step-by-step-installation/healthcheck
sidebar_position: 3
sidebar_label: Healthcheck
---

# Healthcheck

From your **main repository**, run the statuscheck script — it confirms both
logins, your settings, and the platform in one pass.

**Linux / macOS** (bash) — read it first:
[`statuscheck.sh`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/scripts/posix/statuscheck.sh)

```bash
for r in assigner executor reviewer; do
  STATUSCHECK_RERUN='rerun /jira-sdlc:jst-install' \
    bash "${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix/statuscheck.sh" --role "$r"
done
```

Run it **once per role**. Jira authentication is role-scoped, so a successful
`executor` check does not prove the `assigner` or `reviewer` credentials work.

**Windows** (PowerShell 7+ `pwsh`, or 5.1 `powershell`) — read it first:
[`statuscheck.ps1`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/scripts/win/statuscheck.ps1)

```powershell
iwr -UseBasicParsing "https://raw.githubusercontent.com/kantorv/jira-sdlc-tools/main/plugins/jira-sdlc/skills/_shared/scripts/win/statuscheck.ps1" -OutFile statuscheck.ps1
# --role is required: assigner|executor|reviewer
pwsh -File statuscheck.ps1 --role executor        # PowerShell 7+
powershell -File statuscheck.ps1 --role executor  # PowerShell 5.1
```

Repeat for `assigner`, `executor`, and `reviewer`; the `--role` argument is
required. Every row should finish as `OK` or `INFO`; install-irrelevant rows may
remain `INFO`. A relative `WORKTREES_DIR` is a real failure and must be fixed.
The statuscheck cannot prove workflow transition validity or that the configured
branch names are the branches you actually intended; the Jira smoke test covers
the former, and the branch configuration is a user decision.
