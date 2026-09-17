---
slug: /step-by-step-installation/credentials-manager
sidebar_position: 1
sidebar_label: Credentials manager
---

# Credentials manager

If you clone over HTTPS, a credentials manager stores your GitHub credentials
after the first `git push`/`pull`, so `git` itself doesn't prompt on every
command:

- **Git Credential Manager** (cross-platform, bundled with Git for Windows,
  installable separately on Linux/macOS) —
  `git config --global credential.helper manager`
- **macOS** — the Keychain helper is on by default
  (`git config --global credential.helper osxkeychain`)
- **Linux** — `git config --global credential.helper libsecret` (or `cache`
  for a time-limited in-memory fallback if no secret service is available)

This authenticates `git` as yourself — it's separate from the per-role Jira
credentials and from the PAT `gh` uses for pull requests.
