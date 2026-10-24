---
slug: /step-by-step-installation/split-production-from-base
sidebar_position: 6
sidebar_label: Split production from base
---

# Split production from base

Gitflow needs two **distinct** long-lived branches, and a single-branch repo
isn't a supported configuration. Point `DEFAULT_BASE_BRANCH` and
`PRODUCTION_BRANCH` at different branches. First inspect what already exists:

```bash
git branch -a
git remote get-url origin
```

The names are your choice; `main` and `development` are the documented defaults.
If your repo only has `main`, create the base branch off it once:

```bash
git switch main
git switch -c development
git push -u origin development
```

Then record both in `.jst/jira-sdlc-tools.env`:

```text
DEFAULT_BASE_BRANCH=development
PRODUCTION_BRANCH=main
```

Protecting both branches is recommended: everything reaches them through a
reviewed PR, which is exactly the flow the skills produce.
