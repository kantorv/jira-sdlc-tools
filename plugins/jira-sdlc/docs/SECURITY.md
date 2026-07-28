# Security

> **Stub — TBD.** [STEP-BY-STEP.md](STEP-BY-STEP.md) links here for the note
> on Jira token types. Until this page is written, token guidance lives in
> [../skills/_shared/jira-api-reference.md](../skills/_shared/jira-api-reference.md)
> §5 and
> [github/GH-PAT-SESSION-LOGIN.md](github/GH-PAT-SESSION-LOGIN.md).

## What belongs here

- **Which Jira token to use, and why.** A classic (unscoped) token is the
  simplest and always works. A **scoped** token needs the three *coarse*
  scopes `read:jira-user` + `read:jira-work` + `write:jira-work`; the
  granular per-resource ones (`read:issue:jira` and friends) look right and
  fail with `401 "scope does not match"`, because a single `GET /issue`
  requires a whole bundle of them at once. Full detail in
  [../skills/_shared/jira-api-reference.md](../skills/_shared/jira-api-reference.md)
  §5. Resolve the wording against [STEP-BY-STEP.md](STEP-BY-STEP.md) and the
  root README's Tokens table, which currently describe this differently.
- **GitHub PAT scope** — fine-grained, Contents + Pull requests read/write.
- **Where secrets live:** `.jst/jira-sdlc-tools.local.env` is the untracked,
  per-machine file; `.jst/jira-sdlc-tools.env` is committed and must hold no
  credentials. See
  [../skills/_shared/project-config.md](../skills/_shared/project-config.md).
- **What the skills do with your credentials** — the actions listed in the
  root README's Caution section, and what stays manual (plugin
  [README.md](../README.md#safety-model) → Safety model).
- Reporting a vulnerability in this repo.
