There are two independent ways you authenticate with GitHub, and this setup
needs both:

- **[`git` itself](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/git-authentication)** — for commits, pushes, and creating branches. Either:
  - a [credentials manager](git/credentials-manager.md), or
  - an [SSH key](git/ssh-key.md)
- **[`gh` (the GitHub CLI)](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/gh-authentication)** — for creating and updating pull requests. Either:
  - a [PAT](gh/pat.md) — scoped to pull-request read/write, which the skills
    pass to every `gh` command they run (required), and optionally
  - [`gh auth login`](gh/gh-auth-login.md) — your own broader, admin-scoped
    session, for manual debugging (e.g. inspecting GitHub Actions runs). The
    skills never use it and never change it

The pages below are the detailed reference for each.
