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
| [`demo-claude-feature-flow.yml`](../example-workflows/demo-claude-feature-flow.yml) | Comment `/make-feature` on an issue | `feature/<KEY>-<slug>` off `<DEFAULT_BASE_BRANCH>`; PR into `<DEFAULT_BASE_BRANCH>` | [ci-feature-flow-demo.md](ci-feature-flow-demo.md) |
| [`demo-fcc-nvidia-nim-feature-flow.yml`](../example-workflows/demo-fcc-nvidia-nim-feature-flow.yml) | Comment `/fcc-make-feature` on an issue | Same as above | Same skills, same job shape as `demo-claude-feature-flow.yml` — the only difference is the model backend (Free Claude Code + NVIDIA NIM instead of the Claude Code CLI). See [ci-feature-flow-demo.md](ci-feature-flow-demo.md). |
| [`demo-claude-hotfix-flow.yml`](../example-workflows/demo-claude-hotfix-flow.yml) | Comment `/make-hotfix` on an issue | `hotfix/<KEY>-<slug>` off `origin/<PRODUCTION_BRANCH>`; PR into `<PRODUCTION_BRANCH>` | [ci-hotfix-flow-demo.md](ci-hotfix-flow-demo.md) |

No job in this category declares an environment, so a run that passes the
OWNER comment guard goes start to finish with no approval pause (see
[GITHUB-AUTOMATIONS.md §3](../GITHUB-AUTOMATIONS.md#3-gating-assistant-workflows)
for the gating convention shared by every workflow that runs a coding
assistant).
