# Installing GitHub for Jira

> **Stub — TBD.** [STEP-BY-STEP.md](STEP-BY-STEP.md) links here when it
> recommends the integration. Until this page is written, the upstream
> install guide is
> [github/github-for-jira](https://github.com/github/github-for-jira).

**Recommended, not required.** The skills work without it — what you lose is
the automatic linking that comes from having Jira see your commits, branches,
and PRs.

## What belongs here

- Installing the app from the Atlassian Marketplace and connecting the GitHub
  org to the Jira site.
- What the integration buys this plugin: branch/PR-to-issue linking (the
  skills name branches `feature/<KEY>-slug` precisely so this works), and the
  automation that moves an issue to `<STATUS_DONE>` on merge — no skill
  transitions to that status itself, per
  [../skills/_shared/project-config.md](../skills/_shared/project-config.md).
- What breaks without it, and what to do by hand instead.
- Non-GitHub forges — see the plugin [README.md](../README.md) → Known
  limitations: branch-to-issue linking relies on this integration
  specifically.
