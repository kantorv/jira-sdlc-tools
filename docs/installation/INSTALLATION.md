---
slug: /installation
sidebar_position: 1
sidebar_label: Installation
---

# Installation

## How it works

This is the short, ordered version — four sections, each a page of its own,
run in order.

Would rather be walked through it? `/jira-sdlc:jst-install`
([`SKILL.md`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jst-install/SKILL.md)) follows these same four
sections, in this order, and verifies each one with the Section 4 healthcheck
before moving to the next.

1. [Section 1. Preparing environment](PREPARING-ENVIRONMENT.md)
2. [Section 2. GitHub repository preparation](GITHUB-REPOSITORY-PREPARATION.md)
3. [Section 3. Jira board preparation](JIRA-BOARD-PREPARATION.md)
4. [Section 4. Run the healthcheck](RUN-THE-HEALTHCHECK.md)

## What belongs here

Carried over from the `INSTALLATION.md` stub this page replaces. The four
sections above are the ordered walkthrough; the long form still to be written
is:

- The three loading routes in full — see
  [integrations/CLAUDECODE.md](../integrations/CLAUDECODE.md) for the Claude Code
  ones, and [Integrations](https://kantorv.github.io/jira-sdlc-tools/docs/integrations)
  for every other platform.
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
  [github/GH-PAT-SESSION-LOGIN.md](../github/GH-PAT-SESSION-LOGIN.md).
- The healthcheck, and how to read a failing row.
