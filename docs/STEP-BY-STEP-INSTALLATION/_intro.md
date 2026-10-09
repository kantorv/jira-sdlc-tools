## How it works

This section starts with a short checklist of what you need, followed by a
detailed reference page for each item.

Would rather be walked through it? `/jira-sdlc:jst-install`
([`SKILL.md`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jst-install/SKILL.md))
follows the same setup flow and verifies each part with the healthcheck.

## Setup tree

Every entry is a link. Generated from the docs tree by
[`gen-doc-tree.py`](https://github.com/kantorv/jira-sdlc-tools/blob/main/scripts/gen-doc-tree.py) —
edit the pages, not this list.

<!-- doc-tree: STEP-BY-STEP-INSTALLATION -->

<div class="doc-tree">

[Step-by-step installation](./index.mdx)\
├── [Environment setup](./environment-setup/index.mdx)\
│   ├── [Software](./environment-setup/software.md)\
│   ├── [GitHub](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/github)\
│   │   ├── [Account and Repository](./environment-setup/github/account-and-repository.md)\
│   │   ├── [Authentication](./environment-setup/github/authentication/index.mdx)\
│   │   │   ├── [git](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/git-authentication)\
│   │   │   │   ├── [Credentials manager](./environment-setup/github/authentication/git/credentials-manager.md)\
│   │   │   │   └── [SSH key](./environment-setup/github/authentication/git/ssh-key.md)\
│   │   │   └── [gh](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/gh-authentication)\
│   │   │       ├── [PAT](./environment-setup/github/authentication/gh/pat.md)\
│   │   │       └── [gh auth login](./environment-setup/github/authentication/gh/gh-auth-login.md)\
│   │   ├── [Post install](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/github-post-install)\
│   │   │   └── [Optional: git branch in prompt](./environment-setup/github/post-install/add-git-branch-to-prompt.md)\
│   │   ├── [Verify GitHub authentication](./environment-setup/github/verify-github-authentication.md)\
│   │   ├── [Repository branching model](./environment-setup/github/repository-branching-model.md)\
│   │   ├── [Split production from base](./environment-setup/github/split-production-from-base.md)\
│   │   ├── [Verify GitHub access](./environment-setup/github/verify-github-access.md)\
│   │   ├── [Clone the base branch](./environment-setup/github/clone-the-base-branch.md)\
│   │   ├── [Verify the project repository](./environment-setup/github/verify-the-project-repository.md)\
│   │   └── [GitHub setup gate](./environment-setup/github/github-setup-gate.md)\
│   └── [Jira](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/jira)\
│       ├── [Account, project, and board](./environment-setup/jira/jira-account-project-and-board.md)\
│       ├── [Project key and four statuses](./environment-setup/jira/project-key-and-four-statuses.md)\
│       ├── [Read the project key and statuses from Jira](./environment-setup/jira/read-the-project-key-and-statuses.md)\
│       ├── [Jira users](./environment-setup/jira/jira-users.md)\
│       ├── [Jira tokens](./environment-setup/jira/jira-tokens.md)\
│       ├── [Verify Jira authentication](./environment-setup/jira/verify-jira-authentication.md)\
│       ├── [Record the Jira settings](./environment-setup/jira/record-the-jira-settings.md)\
│       ├── [Prove the Jira workflow](./environment-setup/jira/prove-the-jira-workflow.md)\
│       └── [Jira setup gate](./environment-setup/jira/jira-setup-gate.md)\
├── [Configuration](./configuration/index.mdx)\
│   ├── [Create the .jst/ scaffold](./configuration/create-the-jst-scaffold.md)\
│   └── [Fill .jst/jira-sdlc-tools.local.env](./configuration/fill-the-local-env.md)\
├── [Coding Assistant](./coding-assistant/index.mdx)\
│   ├── [Claude Code (extended)](./coding-assistant/claude-code.md)\
│   └── [Non Claude clients](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/non-claude-clients)\
│       ├── [Codex](./coding-assistant/non-claude-clients/CODEX.md)\
│       ├── [Cursor](./coding-assistant/non-claude-clients/CURSOR.md)\
│       ├── [Antigravity](./coding-assistant/non-claude-clients/ANTIGRAVITY.md)\
│       ├── [Grok](./coding-assistant/non-claude-clients/GROK.md)\
│       ├── [Kilo Code](./coding-assistant/non-claude-clients/KILO.md)\
│       ├── [Kimi Code](./coding-assistant/non-claude-clients/KIMI-CODE.md)\
│       ├── [NVIDIA NIM](./coding-assistant/non-claude-clients/NVIDIA-NIM.md)\
│       ├── [OpenCode](./coding-assistant/non-claude-clients/OPENCODE.md)\
│       └── [Pi](./coding-assistant/non-claude-clients/PI.md)\
├── [Healthcheck](./healthcheck.md)\
├── [First tasks](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/first-tasks)\
│   ├── [Commit the setup](./first-tasks/commit-the-setup.md)\
│   ├── [Add bootstrap and teardown scripts](./first-tasks/add-bootstrap-and-teardown-scripts.md)\
│   └── [Create a release cycle](./first-tasks/create-a-release-cycle.md)\
├── [Optional: parallel worktrees](./optional-parallel-worktrees.md)\
└── [Full setup checklist](./full-setup-checklist.md)

</div>
<!-- /doc-tree -->

The pages below follow this tree in the same order.
