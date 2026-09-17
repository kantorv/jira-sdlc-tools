---
slug: /github-automations/autopilot
sidebar_position: 1
sidebar_label: Overview
---

# Autopilot mode (issue → PR)

The full three-skill chain — assigner → executor → reviewer — run headlessly
in CI as separate jobs, one per skill, each on its own Jira identity. A
GitHub issue goes in; an open, reviewed PR comes out. Nothing merges
automatically — that stays a human act on both the Jira and GitHub sides.

| Workflow file | Trigger | Branch / PR target | Deep dive |
| -- | -- | -- | -- |
| [`demo-claude-feature-flow.yml`](https://github.com/kantorv/jira-sdlc-tools/blob/main/.github/workflows/demo-claude-feature-flow.yml) | Comment `/make-feature` on an issue | `feature/<KEY>-<slug>` off `<DEFAULT_BASE_BRANCH>`; PR into `<DEFAULT_BASE_BRANCH>` | [ci-feature-flow-demo.md](ci-feature-flow-demo.md) |
| [`demo-fcc-nvidia-nim-feature-flow.yml`](https://github.com/kantorv/jira-sdlc-tools/blob/main/.github/workflows/demo-fcc-nvidia-nim-feature-flow.yml) | Comment `/fcc-make-feature` on an issue | Same as above | Same skills, same job shape as `demo-claude-feature-flow.yml` — the only difference is the model backend (Free Claude Code + NVIDIA NIM instead of the Claude Code CLI). See [ci-feature-flow-demo.md](ci-feature-flow-demo.md). |
| [`demo-claude-hotfix-flow.yml`](https://github.com/kantorv/jira-sdlc-tools/blob/main/.github/workflows/demo-claude-hotfix-flow.yml) | Comment `/make-hotfix` on an issue | `hotfix/<KEY>-<slug>` off `origin/<PRODUCTION_BRANCH>`; PR into `<PRODUCTION_BRANCH>` | [ci-hotfix-flow-demo.md](ci-hotfix-flow-demo.md) |

Every job in this category declares `environment: production` — up to 3
approval pauses per run if the environment's **Required reviewers** rule is
enabled (see
[GITHUB-AUTOMATIONS.md §3](../GITHUB-AUTOMATIONS.md#3-the-two-gate-convention-for-assistant-workflows)
for the full two-gate convention shared by every workflow that runs a coding
assistant).
