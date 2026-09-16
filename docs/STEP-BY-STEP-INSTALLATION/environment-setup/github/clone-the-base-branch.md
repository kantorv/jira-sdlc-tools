---
slug: /step-by-step-installation/clone-the-base-branch
sidebar_position: 7
sidebar_label: Clone the base branch
---

# Clone the base branch

**`jira-task-assigner` runs from a long-lived branch, not an issue branch.**
Normally the clone you work in should sit on `development`:

```bash
git clone -b development git@github.com:<OWNER>/<REPO>.git myapp
cd myapp
```

The worktrees directory is a **sibling** of that clone, and must already
exist — the assigner refuses to create it:

```bash
mkdir -p ../myapp-worktrees
cd ../myapp-worktrees && pwd   # the absolute path to paste below
```

Then point `WORKTREES_DIR` at it in `.jst/jira-sdlc-tools.local.env`, **as an
absolute path**:

```text
WORKTREES_DIR=/home/you/src/myapp-worktrees
```

A relative value resolves against a different base from inside a worktree than
from this clone, so the healthcheck FAILs on one. The directory must exist before
the assigner runs; the assigner does not create it for you.
