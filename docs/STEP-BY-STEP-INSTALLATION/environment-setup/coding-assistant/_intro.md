## Claude Code

### Remote — from the marketplace (recommended)

#### from console

```bash
claude plugin marketplace add kantorv/jira-sdlc-tools
claude plugin install jira-sdlc@jira-sdlc-tools
```

#### from within claude code

```text
/plugin marketplace add kantorv/jira-sdlc-tools
/plugin install jira-sdlc@jira-sdlc-tools
```

### Local — clone, then load with `--plugin-dir`

```bash
git clone https://github.com/kantorv/jira-sdlc-tools.git
claude --plugin-dir <PATH-TO>/jira-sdlc-tools/plugins/jira-sdlc
```

See full doc: [Claude Code (extended)](claude-code.md)

## Non Claude Code assistants

This plugin can also be installed as a loose skill set with various coding
assistants other than Claude Code,
[Codex](non-claude-clients/CODEX.md)
[Antigravity](non-claude-clients/ANTIGRAVITY.md),
[Cursor](non-claude-clients/CURSOR.md),
[Kimi Code](non-claude-clients/KIMI-CODE.md), and more. See the
[Platform Compatibility Matrix](#platform-compatibility-matrix) for the full
list and integration status per platform.

## Platform Compatibility Matrix

The skills target the Claude skills spec, so `jira-sdlc` also works —
natively or through the [Agent Skills](https://agentskills.io)
adaptation — in a growing set of other AI coding assistants: Cursor, Kilo
Code, Codex, Antigravity, OpenCode, Grok Build, Pi,
and Kimi Code. See [**Platform Compatibility Matrix**](https://github.com/kantorv/jira-sdlc-tools/blob/main/INTEGRATIONS.md) for the
platform-by-platform table — each one's spec, wiring, integration status,
and a link to its detailed doc.

| Platform | Specification | How it loads | Integration status | Compatibility | Documentation |
| -- | -- | -- | -- | -- | -- |
| [Claude Code](claude-code.md) | Native Claude skills | plugin marketplace · `.claude/skills/` drop-in copy · `--plugin-dir` | First-class (reference) | ✅ | [`CLAUDECODE.md`](claude-code.md) |
| [Cursor](non-claude-clients/CURSOR.md) | Native Claude skills | shares the `~/.claude/` tree with Claude Code | Verified — Linux/macOS | ✅ | [`CURSOR.md`](non-claude-clients/CURSOR.md) |
| [Kilo Code](non-claude-clients/KILO.md) | Native Claude skills | `kilo.jsonc` skills path | Working | ✅ | [`KILO.md`](non-claude-clients/KILO.md) |
| [Codex (CLI)](non-claude-clients/CODEX.md) | Agent Skills | `.codex/skills/` copy + per-skill `agents/openai.yml` | Working — sandbox & timing caveats, testing needed | ⚠️ | [`CODEX.md`](non-claude-clients/CODEX.md) |
| [Antigravity](non-claude-clients/ANTIGRAVITY.md) | Agent Skills | `.agent/skills/` discovery (live-tested) + per-skill `agents/openai.yml` | Verified — Antigravity IDE 1.23.2 & agy 1.0.8 work; other releases untested | ✅ | [`ANTIGRAVITY.md`](non-claude-clients/ANTIGRAVITY.md) |
| [OpenCode](non-claude-clients/OPENCODE.md) | Native Claude skills | `.opencode/skills/` discovery + `opencode.json` override | Verified | ✅ | [`OPENCODE.md`](non-claude-clients/OPENCODE.md) |
| [Grok Build (xAI)](non-claude-clients/GROK.md) | Native Claude skills | reads Claude Code skills, plugins, and hooks zero-config | Draft — flag honour unverified; not run in this environment | ❔ | [`GROK.md`](non-claude-clients/GROK.md) |
| [Pi (pi.dev)](non-claude-clients/PI.md) | Native Claude skills | `settings.json` skills path | Caution — does not respect skill arguments | ⚠️ | [`PI.md`](non-claude-clients/PI.md) |
| [Kimi Code](non-claude-clients/KIMI-CODE.md) | Native Claude skills | `extra_skill_dirs` in `config.toml` | Working — verified in this run | ✅ | [`KIMI-CODE.md`](non-claude-clients/KIMI-CODE.md) |

**Compatibility:** ✅ works — verified in a live session · ⚠️ caution — works
with caveats, not run end-to-end here · ❌ not compatible · ❔ not tested — not
yet exercised in this environment. See [Platform Compatibility Matrix](https://github.com/kantorv/jira-sdlc-tools/blob/main/INTEGRATIONS.md) for the
full status legend.
