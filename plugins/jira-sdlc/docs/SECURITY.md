# Security

> **Stub — TBD.** [STEP-BY-STEP.md](STEP-BY-STEP.md) links here for the note
> on Jira token types. Until this page is written, token guidance lives in
> [JIRA-ACLI.md](JIRA-ACLI.md) and
> [github/GH-PAT-SESSION-LOGIN.md](github/GH-PAT-SESSION-LOGIN.md).

## What belongs here

- **Which Jira token to use, and why.** Granular per-issue scopes are
  rejected by `acli`; a scoped token needs the coarse `read:jira-work` +
  `write:jira-work`. Resolve the wording against
  [STEP-BY-STEP.md](STEP-BY-STEP.md) and the root README's Tokens table,
  which currently describe this differently.
- **GitHub PAT scope** — fine-grained, Contents + Pull requests read/write.
- **Where secrets live:** `jira-sdlc-tools.local.env` is the untracked,
  per-machine file; `jira-sdlc-tools.env` is committed and must hold no
  credentials. See
  [../skills/_shared/project-config.md](../skills/_shared/project-config.md).
- **What the skills do with your credentials** — the actions listed in the
  root README's Caution section, and what stays manual (plugin
  [README.md](../README.md#safety-model) → Safety model).
- Reporting a vulnerability in this repo.
