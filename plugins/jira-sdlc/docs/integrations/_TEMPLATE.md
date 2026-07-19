# <PLATFORM> Integration (<SPEC — Native Claude skills | Agent Skills>)

> Copy this file to `<PLATFORM>.md` (match the filename convention in this
> directory: uppercase, no spaces — e.g. `CURSOR.md`, `KILO.md`,
> `NVIDIA-NIM.md`), fill it in, then add a row to the summary table in the
> root [`INTEGRATIONS.md`](../../../../INTEGRATIONS.md). Delete this
> blockquote and every `<!-- guidance -->` note before merging. Keep all
> five section headings below in order — every per-platform doc in this
> directory uses them, and the summary table assumes a reader can find each
> one in the same place.

<!-- SECTION 1 — which spec this platform uses, in one line, as the very
     first line of the body (this is the doc's headline classification).
     For native: name the config file or skills path the platform reads
     (e.g. "`kilo.jsonc` skills path", "shares the `~/.claude/` tree"). For
     Agent Skills: name the skills root the platform copies into and
     whether you also ship a per-skill `agents/openai.yml`. -->

## Prerequisites

<!-- Standard prereqs shared with every integration: `acli` (Atlassian CLI)
     authenticated, `gh` (GitHub CLI) authenticated, and the two
     project-root env files. LINK to
     [`../../skills/_shared/project-config.md`](../../skills/_shared/project-config.md)
     for the one-time `acli jira auth login` and the env-file descriptions —
     do not restate their contents. Then call out anything platform-
     specific: a runtime, a subscription, a model proxy, a sandbox policy. -->

## Install / Wire-up Steps

<!-- The concrete copy-paste recipe: how the three skill folders (and
     `_shared`) get onto the platform's skills path, which config file to
     edit, and any per-skill adaptation file to create. Keep the three skill
     folders and `_shared` as siblings — the `SKILL.md` files reach
     `_shared` by relative path, so moving or renaming it breaks them, and
     never double-nest into `<root>/jira-sdlc/skills/…`. The manual-copy
     trees (`.agent/`, `.codex/`) are gitignored — never commit them. -->

## Invoking the Three Skills

<!-- How the user runs the three skills on this platform. If the slash
     command matches Claude Code's `/jira-sdlc:jira-task-assigner`,
     `/jira-sdlc:jira-task-executor`, `/jira-sdlc:jira-task-reviewer`, say
     so and list the three. If the platform surfaces them differently (a
     bare `/<skill-name>`, a chat attach, a config-registered command),
     show that and note the difference from Claude Code. -->

## Platform-Specific Caveats and Known Gaps

<!-- What is verified, what is unverified, and where the integration drifts
     from Claude Code's behaviour. Pay particular attention to
     `disable-model-invocation: true`: does this platform honour it
     natively (read the frontmatter and gate auto-invocation), need an
     adaptation file like `agents/openai.yml` to reproduce it, or ignore it
     entirely (forcing a workaround)? Tag claims **Verified** /
     **Unverified** inline — the status column in the root summary table is
     derived from these notes, so a reader can tell what was run live vs.
     reasoned from docs. -->
