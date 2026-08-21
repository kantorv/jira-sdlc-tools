---
slug: /run-the-healthcheck
sidebar_position: 5
sidebar_label: 4. Run the healthcheck
---

# Section 4. Run the healthcheck

From your **main repository**, run the statuscheck script — it confirms both
logins, your settings, and the platform in one pass:

**Linux / macOS** (bash) — read it first:
[`statuscheck.sh`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/scripts/posix/statuscheck.sh)

```bash
curl -fsSL "https://raw.githubusercontent.com/kantorv/jira-sdlc-tools/main/plugins/jira-sdlc/skills/_shared/scripts/posix/statuscheck.sh" -o statuscheck.sh
bash statuscheck.sh --role executor   # --role is required: assigner|executor|reviewer
```

**Windows** (PowerShell 7+ `pwsh`, or 5.1 `powershell`) — read it first:
[`statuscheck.ps1`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/scripts/win/statuscheck.ps1)

```powershell
iwr -UseBasicParsing "https://raw.githubusercontent.com/kantorv/jira-sdlc-tools/main/plugins/jira-sdlc/skills/_shared/scripts/win/statuscheck.ps1" -OutFile statuscheck.ps1
# --role is required: assigner|executor|reviewer
pwsh -File statuscheck.ps1 --role executor        # PowerShell 7+
powershell -File statuscheck.ps1 --role executor  # PowerShell 5.1
```

## What's still uncommitted — and the first task

A green healthcheck doesn't mean the config is in git. The whole `.jst/` folder
is still untracked — `jira-sdlc-tools.env` ([Section
3.3](JIRA-BOARD-PREPARATION.md), team-shared and meant to be committed) and the
`.gitignore` beside it. Leave it and the first worktree
`jira-task-assigner` cuts is born without `.jst/` at all, so the first executor
run fails statuscheck's `env_config` row there. Copy the folder **whole** when
you populate that worktree: the `.gitignore` inside it is what keeps
`jira-sdlc-tools.local.env` and its four credentials out of the commit, and
staging `.jst/` explicitly beats `git add -A` either way.

Commit it by hand, or — recommended — make it this project's first task, so the
fix doubles as an end-to-end smoke test of all three skills.
[`/jira-sdlc:jst-install`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jst-install/SKILL.md) §4d closes with a
ready-to-paste prompt for that: the assigner creates a retroactive
**JIRA-SDLC-TOOLS setup** issue and copies `.jst/` into its worktree, the
executor commits and pushes it, and the reviewer confirms the settings work.
