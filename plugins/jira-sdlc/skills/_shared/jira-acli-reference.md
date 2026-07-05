**Done!** I've created `acli-reference.md` modeled closely after the original `jira-cli-reference.md`, but updated for the **official Atlassian CLI (`acli`)**.

Here's the content:

---

```markdown
# acli-reference.md (Official Atlassian CLI)

Reference for agents when creating/managing Jira issues via **Atlassian CLI (`acli`)**.

Auth should be set up with an API token (Granular scopes recommended).  
Project-specific values (`<PROJECT-KEY>`, `<STATUS_TODO>`, `<STATUS_IN_PROGRESS>`, `<STATUS_IN_REVIEW>`, `<STATUS_DONE>`) come from `jira-tools-plugin.env` in the project root.

**Sections:** [0. Auth](#0-auth) · [1. Issue types](#1-issue-type-hierarchy) · [2. Creating issues](#2-creating-issues) · [3. Reading/listing](#3-reading--listing-issues) · [4. Editing/transitioning](#4-editing--transitioning) · [5. Linking](#5-linking-issues) · [6. Comments/worklogs](#6-comments--worklogs) · [7. Git workflow](#7-git-workflow--branch-vs-direct-commit) · [8. Destructive commands](#8-destructive--risky-commands) · [9. Other useful commands](#9-other-useful-commands)

---

## 0. Auth

**Recommended:** Granular API token with at least these scopes:
- `write:issue:jira`
- `write:comment:jira`
- `read:issue:jira`
- `write:worklog:jira`
- `read:project:jira`
- `read:me` (and others like board/sprint as needed)

### Authenticate (one-time or in scripts)

```bash
# Pipe token (best for automation)
echo "YOUR_API_TOKEN" | acli jira auth login --site "your-site.atlassian.net" --email "your-email@example.com" --token

# Or from file
acli jira auth login --site "your-site.atlassian.net" --email "your-email@example.com" --token /path/to/token.txt
```

**Verify:**
```bash
acli jira workitem list --limit 1
# or
acli jira auth status
```

For repeated use in scripts, you can run the auth command before other commands or rely on stored credentials.

**Non-interactive style:** ACLI commands are generally non-interactive when all flags are provided. Use `--from-json` for complex payloads.

---

## 1. Issue type hierarchy

(Confirmed for this project — adjust per your `jira-tools-plugin.env`)

```
Task / Story / Bug        (top-level)
 └── Sub-task              (linked via --parent)
```

| Role     | Exact type name |
|----------|-----------------|
| Task     | `Task`          |
| Story    | `Story`         |
| Bug      | `Bug`           |
| Sub-task | `Sub-task`      |

Default project key: `<PROJECT-KEY>`.

---

## 2. Creating issues

**Top-level issue:**
```bash
acli jira workitem create \
  --project "<PROJECT-KEY>" \
  --type "Task" \
  --summary "Your summary" \
  --description "Your description (or use --description-file)" 
```

**Sub-task:**
```bash
acli jira workitem create \
  --project "<PROJECT-KEY>" \
  --type "Sub-task" \
  --summary "Sub-task summary" \
  --parent "<PARENT-KEY>"
```

**Better for long descriptions:**
```bash
cat > /tmp/desc.md <<'EOF'
**Markdown** supported. Long description here.
EOF

acli jira workitem create --project "<PROJECT-KEY>" --type "Task" --summary "..." --description-file /tmp/desc.md
```

Useful flags: `--assignee @me`, `--priority High`, `--label backend`, `--component XYZ`.

---

## 3. Reading / listing issues

```bash
acli jira workitem list --jql "project = <PROJECT-KEY> AND assignee = currentUser()" --limit 20

acli jira workitem get --key <ISSUE-KEY>          # detailed view
acli jira workitem get --key <ISSUE-KEY> --output json   # for parsing
```

Check type / parent:
```bash
acli jira workitem get --key <KEY> --output json
```

---

## 4. Editing / transitioning

```bash
# Edit
acli jira workitem edit --key <KEY> --summary "New summary" --description "Updated..."

# Assign
acli jira workitem edit --key <KEY> --assignee @me

# Transition — use <STATUS_TODO> / <STATUS_IN_PROGRESS> /
# <STATUS_IN_REVIEW> / <STATUS_DONE> from jira-tools-plugin.env
acli jira workitem transition --key <KEY> --status "<STATUS_IN_PROGRESS>"
```

---

## 5. Linking issues

```bash
acli jira workitem link --key <KEY1> --to <KEY2> --link-type "Blocks"
# Check available link types with: acli jira ... (or Jira UI)
```

---

## 6. Comments & Worklogs

### Comments

```bash
# Simple
acli jira workitem comment create --key <KEY> --body "Simple comment"

# Multi-line / Markdown (recommended)
cat <<'EOF' | acli jira workitem comment create --key <KEY> --body-file -
**Bold** text and `code`.
More lines...
EOF
```

### Worklogs

```bash
acli jira workitem worklog add --key <KEY> --time-spent "1h 30m" --comment "Work done"
```

---

## 7. Git workflow — Branch vs Direct Commit

(Same as before — Smart Commits and branch naming conventions still apply.)

**Direct commit example:**
```bash
git commit -m "<KEY> #done fixed pagination bug"
```

**Branch naming:**
```bash
git checkout -b feature/<KEY>-short-description
# or hotfix/ for bugs
```

---

## 8. Destructive commands

```bash
acli jira workitem delete --key <KEY>
```

Use with caution. Confirm with user before running.

---

## 9. Other useful commands

```bash
acli jira project list
acli jira board list
acli jira sprint list --current
acli open <KEY>          # open in browser (if supported)
```

---

**Notes:**
- Always prefer `--description-file` / `--body-file` for long content.
- Use `--output json` for machine-readable output.
- ACLI excels at bulk operations: `acli jira workitem edit --jql "..." ...`
- For full command reference: `acli jira --help` or official docs.

This reference is optimized for agent use (non-interactive, script-friendly).
```
