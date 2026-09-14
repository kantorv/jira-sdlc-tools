---
slug: /step-by-step-installation/create-the-jst-scaffold
sidebar_position: 4
sidebar_label: Create the .jst/ scaffold
---

# Create the `.jst/` scaffold

Create the local configuration scaffold before running the healthcheck:

```bash
mkdir -p .jst
grep -qxF 'jira-sdlc-tools.local.env' .jst/.gitignore 2>/dev/null \
  || echo 'jira-sdlc-tools.local.env' >> .jst/.gitignore
[ -f .jst/jira-sdlc-tools.local.env ] \
  || cp "${CLAUDE_PLUGIN_ROOT}/skills/_shared/templates/jira-sdlc-tools.local.env.example" \
        .jst/jira-sdlc-tools.local.env
```

The ignore rule belongs in **`.jst/.gitignore`**, not the repository root
`.gitignore`. Create the ignore rule before the local file so a broad `git add -A` cannot catch credentials in the gap. An existing
`.jst/jira-sdlc-tools.local.env` is never overwritten.
