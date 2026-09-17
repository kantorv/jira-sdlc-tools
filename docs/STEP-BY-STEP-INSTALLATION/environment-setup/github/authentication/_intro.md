There are two independent ways you authenticate with GitHub, and this setup
needs both:

- **`git` itself** — for commits, pushes, and creating branches. Either:
  - a [credentials manager](credentials-manager.md), or
  - an [SSH key](ssh-key.md)
- **`gh` (the GitHub CLI)** — for creating and updating pull requests. Either:
  - a [PAT](pat.md) — scoped to pull-request read/write, the default the
    skills authenticate with, or
  - [`gh auth login`](gh-auth-login.md) — a broader, admin-scoped session,
    only needed for manual debugging (e.g. inspecting GitHub Actions runs)

The pages below are the detailed reference for each.
