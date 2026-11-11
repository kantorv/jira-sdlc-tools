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
