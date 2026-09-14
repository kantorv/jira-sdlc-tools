---
slug: /step-by-step-installation/commit-the-setup
sidebar_position: 1
sidebar_label: Commit the setup
---

# Commit the setup

A green healthcheck doesn't mean the config is in git. The whole `.jst/` folder
is still untracked — `jira-sdlc-tools.env` (team-shared and meant to be
committed) and the `.gitignore` beside it.

The first worktree `jira-task-assigner` cuts is born without `.jst/` at all, so
the first executor run fails statuscheck's `env_config` row there. Copy the
folder **whole** when you populate that worktree: the `.gitignore` inside it is
what keeps `jira-sdlc-tools.local.env` and its four credentials out of the
commit, and staging `.jst/` explicitly beats `git add -A` either way.

Commit it by hand, or — recommended — make it this project's first task, so the
fix doubles as an end-to-end smoke test of all three skills.

The installer skill provides this ready-to-paste first-task prompt:

```text
/jira-sdlc:jira-task-assigner "JIRA-SDLC-TOOLS setup — a retroactive first
task, and this repo's first run of these skills. The plugin's config is
written but uncommitted: the whole .jst/ folder, holding jira-sdlc-tools.env
and a .gitignore covering jira-sdlc-tools.local.env. Create the issue, branch
and worktree as usual, then copy .jst/ into that worktree — the executor's job
is only to commit and push it, and the reviewer's is to confirm the settings
work. Copy the folder whole: the .gitignore inside it is what keeps
.jst/jira-sdlc-tools.local.env, which holds the live credentials, out of the
commit. Stage .jst/ explicitly rather than with 'git add -A'. Treat this run
as the smoke test that all three skills interact correctly."
```
