@AGENTS.md

## Claude Code–specific notes

**Local dev loop.** Don't iterate against a marketplace install — Claude
Code copies a plugin snapshot into its cache at install time, so edits to
this clone won't show up there until you reinstall. While actively
changing a skill, load straight from your working copy instead:
```bash
claude --plugin-dir /path/to/claude-code-plugins/plugins/jira-sdlc
```
After further edits, run `/reload-plugins` inside that session rather
than restarting. If this plugin is already installed from a marketplace
elsewhere on the same machine, `--plugin-dir` takes precedence for that
session, so you can test a change without uninstalling anything first.

**`disable-model-invocation: true` is load-bearing, not decorative.** All
three skills set it deliberately: they expect explicit invocation
(`/jira-sdlc:jira-task-executor PROJ-278`, etc.), never Claude deciding
mid-conversation that things sound like a job for `jira-task-reviewer`.
If you're refining a skill's `description` field, you're improving what
a person sees when browsing `/plugin` or reading the repo — not tuning
auto-trigger accuracy, since that mechanism is intentionally off here.

**Skill identity.** `name:` frontmatter is how each skill is invoked
(namespaced under the plugin as `/jira-sdlc:<name>`) — treat it like a
public API, not an internal label. See AGENTS.md above for what else
needs updating if you change one.
