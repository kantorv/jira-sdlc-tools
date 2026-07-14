# Kilo Code Integration (Native Claude Skills Spec)

Uses the native Claude skills specification.

## Prerequisites

- `acli` (Atlassian CLI) authenticated — see [jira-sdlc-tools.env template](jira-sdlc-tools.env)
- `gh` (GitHub CLI) authenticated
- `jira-sdlc-tools.env` and `jira-sdlc-tools.local.env` — see jira-sdlc-tools.env reference

## Install / Wire-up Steps

Kilo Code loads Claude-spec skills natively by pointing at a skills path in `kilo.jsonc` at your project root:

1. Create `kilo.jsonc` at your project root:
   ```json
   {
     "$schema": "https://app.kilo.ai/config.json",
     "skills": {
       "paths": ["</PATH>/plugins/jira-sdlc/skills"]
     }
   }
   ```
2. Replace `</PATH>` with the absolute path where this plugin lives on your machine:
   - Installed via marketplace: `~/.claude/plugins/jira-sdlc/skills`
   - Local clone: the absolute path to `plugins/jira-sdlc/skills`
3. Kilo automatically loads skills from the configured paths.

## Invocating the Three Skills

Call each skill using the slash-command format:

- `/jira-sdlc:jira-task-assigner` — break down a task into Jira issues with branches
- `/jira-sdlc:jira-task-executor` — implement an issue from its worktree
- `/jira-sdlc:jira-task-reviewer` — review sub-task PRs from the parent worktree

## Platform-Specific Caveats

- `disable-model-invocation: true` is honoured by Kilo Code. Skills with this setting cannot be invoked by mentioning them in chat messages; they must be explicitly called via slash-command.