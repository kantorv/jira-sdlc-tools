The installer uses **two environment files**:

- `.jst/jira-sdlc-tools.env` — team-shared, secret-free configuration containing
  the project key, base/production branch names, and four Jira status names.
  This file is intended to be committed.
- `.jst/jira-sdlc-tools.local.env` — local credentials and paths containing
  `WORKTREES_DIR`, `JIRA_ACCOUNT_URL`, the three Jira role credentials, and the
  GitHub PAT. This file must stay local and is protected by `.jst/.gitignore`.

Your local settings should look like this:

```text
WORKTREES_DIR=/path/to/worktrees/PROJ-worktrees

JIRA_ACCOUNT_URL=your-jira-site.atlassian.net

# Required — one Jira account per role, so the board shows who did what.
# All six values, no default pair behind them; point all three at the same
# Atlassian account if you'd rather not split them.
JIRA_ASSIGNER_EMAIL=assigner@example.com
JIRA_ASSIGNER_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX
JIRA_EXECUTOR_EMAIL=executor@example.com
JIRA_EXECUTOR_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX
JIRA_REVIEWER_EMAIL=reviewer@example.com
JIRA_REVIEWER_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX

GITHUB_PAT_TOKEN="XXXXXXXXXXXXX"
```

Each `JIRA_<ROLE>_TOKEN` is the token **value**, not a path to a file holding
it. Every variable above is described in
[plugins/jira-sdlc/skills/\_shared/project-config.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md).

> ⚠️ **This plugin is designed to run in a shared environment** — the same
> checkout where a coding assistant operates *and* where you yourself still
> run `git` commands by hand. That's why `git` auth is left shared between
> you and the agent rather than split out: a separate agent identity would
> otherwise fight your own commits/pushes for the same repo state. If your
> setup doesn't need that — the agent is the only thing ever touching
> `git` here — it can authenticate with its own PAT instead, the same way
> `gh` already does. That setup isn't documented yet.

The pages below walk through creating and filling the scaffold.
