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
│   │   ├── Prerequisites
│   │   ├── Software authentication
│   │   ├── Verify the project repository
│   │   ├── Create the `.jst/` scaffold
│   │   ├── Fill `.jst/jira-sdlc-tools.local.env`
│   │   └── Software setup gate
│   ├── GitHub
│   │   ├── Account, repository, and authentication
│   │   ├── Verify GitHub authentication
│   │   ├── Repository branching model
│   │   ├── Split production from base
│   │   ├── Verify GitHub access
│   │   ├── Clone the base branch
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
│   └── Coding Assistant
│       └── Platform Compatibility Matrix
├── Configuration
├── Healthcheck
├── First tasks
│   ├── Commit the setup
│   ├── Add bootstrap and teardown scripts
│   └── Create a release cycle
└── Optional: parallel worktrees
```

The pages below follow this tree in the same order.
