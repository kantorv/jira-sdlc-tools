## How it works

This section starts with a short checklist of what you need, followed by a
detailed reference page for each item.

Would rather be walked through it? `/jira-sdlc:jst-install`
([`SKILL.md`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jst-install/SKILL.md))
follows the same setup flow and verifies each part with the healthcheck.

## Setup tree

```text
STEP-BY-STEP-INSTALLATION
├── Environment setup — what you need
│   ├── Software
│   ├── GitHub
│   │   ├── Account, repository, and authentication
│   │   ├── Post install
│   │   ├── Verify GitHub authentication
│   │   ├── Repository branching model
│   │   ├── Split production from base
│   │   ├── Verify GitHub access
│   │   ├── Clone the base branch
│   │   ├── Verify the project repository
│   │   └── GitHub setup gate
│   ├── Jira
│   │   ├── Account, project, and board
│   │   ├── Project key and four statuses
│   │   ├── Read the project key and statuses from Jira
│   │   ├── Jira users
│   │   ├── Jira tokens
│   │   ├── Verify Jira authentication
│   │   ├── Record the Jira settings
│   │   ├── Prove the Jira workflow
│   │   └── Jira setup gate
├── Configuration
│   ├── Create the `.jst/` scaffold
│   └── Fill `.jst/jira-sdlc-tools.local.env`
├── Coding Assistant
│   ├── Claude Code (extended)
│   └── Non Claude clients
│       └── one page per client
├── Healthcheck
├── First tasks
│   ├── Commit the setup
│   ├── Add bootstrap and teardown scripts
│   └── Create a release cycle
└── Optional: parallel worktrees
```

The pages below follow this tree in the same order.
