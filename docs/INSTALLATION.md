---
slug: /installation
sidebar_position: 1
---

# Installation

> **Stub — TBD.** [STEP-BY-STEP.md](STEP-BY-STEP.md) links here as the long
> form of its short, ordered walkthrough. Until this page is written, the
> installation content lives in the plugin
> [README.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/README.md#installation) and the root
> [README.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/README.md#full-setup).

## What belongs here

- The three loading routes in full — see
  [integrations/CLAUDECODE.md](integrations/CLAUDECODE.md) for the Claude Code
  ones, and [integrations/](integrations) for every other platform.
- Prerequisites and tool installation (`git`, `gh`, plus `curl` + `jq` for
  the Jira REST client), per OS.
- Both env files and every variable in them — currently described in
  [plugins/jira-sdlc/skills/\_shared/project-config.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md).
- Jira credentials and `gh` authentication. Jira needs no login step — the
  `jira.sh` / `jira.ps1` client authenticates per-request from the
  `email:token` pairs in `.jst/jira-sdlc-tools.local.env`; token types and scopes
  are in
  [plugins/jira-sdlc/skills/\_shared/jira-api-reference.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/jira-api-reference.md)
  §5. For `gh`, see
  [github/GH-PAT-SESSION-LOGIN.md](github/GH-PAT-SESSION-LOGIN.md).
- The healthcheck, and how to read a failing row.
