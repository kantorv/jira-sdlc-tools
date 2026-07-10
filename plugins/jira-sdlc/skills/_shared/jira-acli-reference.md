# acli-reference.md (Official Atlassian CLI `acli`)

Reference for Claude Code when creating/managing Jira issues via the
**official Atlassian CLI (`acli`)**.

Auth is set up with an API token (Cloud). Project-specific values come
from two files in the project root:

**`jira-sdlc-tools.env` (team-shared, committed)**
- `<PROJECT-KEY>`
- `<DEFAULT_BASE_BRANCH>`
- `<STATUS_TODO>`
- `<STATUS_IN_PROGRESS>`
- `<STATUS_IN_REVIEW>`
- `<STATUS_DONE>`
- `<SEMVER_LABELS>`

**`jira-sdlc-tools.local.env` (machine-specific, gitignored)**
- `<WORKTREES_DIR>`
- `<JIRA_ACCOUNT_URL>`
- `<JIRA_ACCOUNT_EMAIL>`
- `<JIRA_TOKEN_PATH>`

Resolve tokens from the appropriate file. `acli` stores its own credentials after
`auth login`, so unlike `jira-cli` you do **not** prefix every command
with a token env var.

`acli` version this was confirmed against: `1.3.22-stable`
(check with `acli --version` — the **`--version` flag**; the `acli version`
*subcommand* errors with "unknown command").

**Sections:** [0. Auth](#0-auth) ·
[1. Issue types](#1-issue-type-hierarchy) ·
[2. Creating issues](#2-creating-issues) ·
[3. Reading / listing](#3-reading--listing-issues) ·
[4. Editing / transitioning / assigning](#4-editing--transitioning--assigning) ·
[5. Linking](#5-linking-issues) ·
[6. Comments / worklogs](#6-comments--worklogs) ·
[7. Git workflow](#7-git-workflow--branch-convention) ·
[8. Destructive commands](#8-destructive--risky-commands--use-with-care) ·
[9. Other useful commands](#9-other-useful-commands) ·
[10. Helper scripts](#10-helper-scripts) ·
[11. Cross-reference to jira-cli](#11-cross-reference-to-jira-cli) ·
[12. PR-base resolver](#12-pr-base-resolver-git-config--jira-comment--env-default)

---

## 0. Auth

`acli` keeps credentials in its own store — authenticate once, then every
subsequent `acli jira ...` works without a token prefix.

One-time login (token piped via stdin — `--token` takes no value, reads from
standard input):

```bash
acli jira auth login \
  --site "<JIRA_ACCOUNT_URL>" \
  --email "<JIRA_ACCOUNT_EMAIL>" \
  --token < <JIRA_TOKEN_PATH>
```

`<JIRA_ACCOUNT_URL>`, `<JIRA_ACCOUNT_EMAIL>`, and `<JIRA_TOKEN_PATH>`
are resolved from `jira-sdlc-tools.local.env` (machine-specific) in the project root.

Verify:

```bash
acli jira auth status
# ✓ Authenticated
#   Site: <JIRA_ACCOUNT_URL>
#   Email: <JIRA_ACCOUNT_EMAIL>
#   Authentication Type: api_token
```

---

## 1. Issue type hierarchy

Two-level hierarchy with no grouping above the top level:

```
Task / Story / Bug        (top-level, no parent)
 └── Subtask              (linked to its parent via --parent)
```

**Issue type names are project-specific — confirm against your real
project before relying on them.** The names below are confirmed for
this toolkit's reference project; a different Jira project may name them
differently. Two reliable ways to discover the exact names for *your*
project:

1. Trigger the validation error — pass a deliberately-wrong type and
   `acli` lists every allowed type in the message:
   ```bash
   acli jira workitem create --project "<PROJECT-KEY>" --type "xInvalidx" --summary "probe"
   # ✗ Error: Please provide valid issue type. Allowed issue types for project are: Subtask, Epic, Task, Story, Feature, Bug
   ```
2. Inspect an existing issue: `acli jira workitem view <any-key> --json`
   → `fields.issuetype.name`.

For this project:

| Role     | Exact type name |
|----------|-----------------|
| Task     | `Task`          |
| Story    | `Story`         |
| Bug      | `Bug`           |
| Sub-task | `Subtask`       |   ← **no hyphen** for this project (see §11)

⚠️ Note the **`Subtask`** spelling (no hyphen).  

Default project key: `<PROJECT-KEY>` (from `jira-sdlc-tools.env`).

---

## 2. Creating issues

### Top-level issue

```bash
acli jira workitem create \
  --project "<PROJECT-KEY>" \
  --type "Task" \
  --summary "Your summary" \
  --description "Your description"
```

### Sub-task (linked to a parent)

```bash
acli jira workitem create \
  --project "<PROJECT-KEY>" \
  --type "Subtask" \
  --parent "<PARENT-KEY>" \
  --summary "Sub-task summary"
```

### Long descriptions — use a file, not inline

Inline `--description` works for a sentence or two. For real bodies, write
the text to a file and load it with `--description-file`. Note that
`--description` / `--description-file` accept **plain text or Atlassian
Document Format (ADF)** (`--help`) — **not markdown**. A markdown body is
stored verbatim as one plain-text paragraph, so `##`, `-`, and `1.` show up
literally instead of rendering as headings/lists (verified: a `## Summary`
description landed as a single `doc → paragraph → text` node with the `##`
intact). For structured formatting, supply an ADF document (the shape
`acli jira workitem create --generate-json` prints); for plain prose, plain
text is fine.

```bash
acli jira workitem create \
  --project "<PROJECT-KEY>" \
  --type "Task" \
  --summary "..." \
  --description-file /tmp/issue-body.txt
```

Other useful create flags (all confirmed via `acli jira workitem create --help`):

```
-a, --assignee string    Assignee email or account ID; '@me' for self, 'default' for project default
-l, --label strings      Labels, comma-separated (--label backend,urgent)
    --parent string      Parent work item ID (the parent key)
-t, --type string        Issue type: Epic, Story, Task, Bug, Subtask, … (project-specific)
    --json               Output the created issue as JSON (see key below)
    --from-json string   Read the full definition from a JSON file (--generate-json shows the shape)
```

### Capturing the created issue's key

Default (text) output:
```
✓ Work item PROJ-33 created: https://your-site.atlassian.net/browse/PROJ-33
```
The key is embedded in that URL. Extract it in a script:
```bash
KEY=$(echo "$out" | grep -oE '[A-Z]+-[0-9]+' | head -1)
```
Or use `--json` and parse the returned object (`key` is a top-level
field in the JSON output).

### Splitting a task into parallel Sub-tasks (the actual workflow)

1. Create the parent first, capture its key.
2. For each genuinely independent piece, create a `Subtask` with
   `--parent "<PARENT-KEY>"`.
3. Don't create Sub-tasks for purely sequential steps — only for
   parallelizable work (see `jira-task-assigner` for the scoping rule).
4. The parent `Task`/`Story`/`Bug` is the top of the hierarchy — there's
   no grouping above it.

### ⚠️ Known gotcha — why you might reach for `acli` here

`jira-cli` (the ankitpokhrel binary) **silently drops the parent on
sub-task create in this project** — `-P <PARENT-KEY>` is accepted by the
flag parser but never sent in the POST body, so Jira returns `400 Issue
type is a sub-task but parent issue key or id not specified`. `acli`'s
`--parent` works correctly for the same operation, which is why this
reference exists. If you see that 400 from `jira-cli`, switch to the
`acli` command in §2 rather than debugging the flag.

### Bulk create

```bash
acli jira workitem create-bulk --from-json /tmp/issues.json --yes --ignore-errors
# inspect the expected JSON shape first:
acli jira workitem create-bulk --generate-json
```
CSV is also supported (`--from-csv`); columns are summary, projectKey,
issueType, description, label, parentIssueId, assignee.

---

## 3. Reading / listing issues

There is **no `list` subcommand** on `acli jira workitem` — listing is
`search`:

```bash
# Recent issues in the project
acli jira workitem search --jql "project = <PROJECT-KEY> ORDER BY created DESC" --limit 20

# Assigned to me
acli jira workitem search --jql "project = <PROJECT-KEY> AND assignee = currentUser()"

# By status
acli jira workitem search --jql "project = <PROJECT-KEY> AND status = \"<STATUS_IN_REVIEW>\""

# Machine-readable
acli jira workitem search --jql "project = <PROJECT-KEY>" --json
acli jira workitem search --jql "project = <PROJECT-KEY>" --csv

# Fetch everything (pagination):
acli jira workitem search --jql "project = <PROJECT-KEY>" --paginate
```

`search` flags: `-j/--jql`, `-l/--limit`, `--paginate` (ignores `--limit`,
fetches all), `-f/--fields` (default `issuetype,key,assignee,priority,status,summary`),
`--count` (just a count), `--json`, `--csv`, `-w/--web`.

### View a single issue

```bash
acli jira workitem view <KEY>                 # readable text (incl. description)
acli jira workitem view <KEY> --json          # machine-readable
acli jira workitem view <KEY> --web           # open in browser
```

⚠️ The key is **positional** on `view` (`view PROJ-32`), but **`--key`**
on `comment`/`edit`/`transition`/`assign`/`delete`. acli is inconsistent
here — check each command's `--help` before scripting.

⚠️ The default `view --json` returns only
`key,issuetype,summary,status,assignee,description` — **`subtasks` is
not included**. To get sub-tasks (or any non-default field), request all
fields:

```bash
acli jira workitem view <PARENT-KEY> --json --fields '*all'
# then parse fields.subtasks — an array of {"key": "...", "fields": {...}}
```

### Checking an issue's type and parent

```bash
acli jira workitem view <KEY> --json
# fields.issuetype.name    — e.g. "Task", "Story", "Bug", "Subtask"
# fields.parent.key        — present only when <KEY> is itself a sub-task
```

---

## 4. Editing / transitioning / assigning

### Edit

```bash
acli jira workitem edit --key <KEY> --summary "New summary" --yes
acli jira workitem edit --key <KEY> --description "Updated body"
acli jira workitem edit --key <KEY> --description-file /tmp/new-body --yes   # plain text/ADF, not markdown (§2)
```
Bulk edit by JQL:
```bash
acli jira workitem edit --jql "project = <PROJECT-KEY> AND status = \"To Do\"" --assignee @me --yes --ignore-errors
```

### Transition

Status names are project-specific — use the `<STATUS_*>` tokens from
`jira-sdlc-tools.env`.

```bash
acli jira workitem transition --key <KEY> --status "<STATUS_IN_PROGRESS>" --yes
acli jira workitem transition --key <KEY> --status "<STATUS_IN_REVIEW>" --yes
```

### Assign

```bash
acli jira workitem assign --key <KEY> --assignee @me --yes
acli jira workitem assign --key <KEY> --assignee "teammate@example.com" --yes
acli jira workitem assign --key <KEY> --remove-assignee --yes
```

---

## 5. Linking issues

```bash
# Discover available link type names first:
acli jira workitem link type --json

# Create a link (outward --out, inward --in, type is the outward description):
acli jira workitem link create \
  --out <KEY-1> --in <KEY-2> --type "Blocks" --yes

# List a work item's links:
acli jira workitem link list <KEY>
```
Bulk: `--from-json` or `--from-csv` (columns: outward, inward, type).

---

## 6. Comments & worklogs

### Add a comment

```bash
# Short, inline:
acli jira workitem comment create --key <KEY> --body "Single-line comment"

# Long / multi-line — write to a file, load it:
acli jira workitem comment create --key <KEY> --body-file /tmp/comment.txt
```

`--body` / `--body-file` accept **plain text or ADF**, same rule as
`--description*` (§2) — `--help` says so for both. Whether a comment body
renders as markdown depends on a site-level setting acli can't report, so
don't assume either way; use plain text or ADF deliberately.

⚠️ `--body-file -` (stdin) does **not** work — it errors with
`failed to read comment body from file`. Always point `--body-file` at a
real file. If you have the text in a shell variable, write it to a temp
file first, or pass it inline with `--body`:
```bash
cat > /tmp/c.txt <<'EOF'
Multi-line comment body in plain text (or ADF — see §2).
Backticks (`like this`) are literal in a quoted heredoc ('EOF'),
so they're safe from shell command substitution here.
EOF
acli jira workitem comment create --key <KEY> --body-file /tmp/c.txt
```

Other useful `comment create` flags: `-e/--edit-last` (replace your last
comment instead of adding a new one — handy for updating a status note
in place), `--jql` (comment on many issues), `--json`.

### List / update / delete comments

```bash
acli jira workitem comment list --key <KEY> --json
acli jira workitem comment update --key <KEY> --body "..."   # see --help for the comment-id flag
acli jira workitem comment delete --help                       # needs the comment id
acli jira workitem comment visibility                         # get allowed visibility roles
```

### Worklog

```bash
acli jira workitem worklog add --key <KEY> --time-spent "1h 30m" --comment "note"
```

---

## 7. Git workflow — branch convention

Decision rule: every change goes on its own branch, `feature/<KEY>-<slug>` or
`hotfix/<KEY>-<slug>` — no "small enough to commit straight to the
working branch" shortcut. `jira-task-assigner` pre-creates the branch and
worktree for every leaf issue; pick the prefix from the **top-level
parent's** type (Task/Story → `feature/`, Bug → `hotfix/`).

GitHub-for-Jira links a branch to an issue purely by finding the issue
key inside the branch name — no API call required.

```
git checkout -b feature/<ISSUE-KEY>-<slugified-summary>
git push -u origin feature/<ISSUE-KEY>-<slugified-summary>
```

Slugify the title: lowercase, spaces → hyphens, strip punctuation.
`"Fix null pointer on login!"` → `fix-null-pointer-on-login`.

---

## 8. Destructive / risky commands — use with care

```bash
acli jira workitem delete --key <KEY> --yes
acli jira workitem delete --jql "project = <PROJECT-KEY> AND status = \"To Do\"" --yes --ignore-errors
```

⚠️ Unlike `jira-cli` (whose `delete` can't be run non-interactively),
`acli delete` **does** accept `--yes` to skip the prompt — so it *can*
run unattended. That makes the guardrails more important, not less:

Agent rule — never run `delete` unless the user has explicitly asked
for that exact issue to be deleted **in this message**. For any
throwaway/smoke-test issues created while diagnosing a skill, surface
the ready-to-paste delete command in the final report rather than
deleting automatically, even though they were created in the same
session:

```bash
acli jira workitem delete --key <KEY> --yes
```

`create`, `edit`, `transition`, `comment`, `link`, `assign` are
reversible / low-risk and fine to run once the values are confirmed.

### `--yes` — which write commands accept it (verified against `1.3.22`)

`--yes` is **not** universal — checked each command's `--help`.

**Accept `--yes`** (prompt without it; skip with `-y` / `--yes`):
- `workitem edit`
- `workitem transition`
- `workitem assign`
- `workitem delete`
- `workitem link create`
- `workitem create-bulk`

**Reject `--yes`** (`✗ Error: unknown flag: --yes` — the command is already
non-interactive, so don't add `--yes`):
- `workitem create`
- `workitem comment create`

Net: don't blanket-add `--yes` — it errors on `workitem create` and
`comment create`. (Both rejecters were probed; accepters were read from
`--help`.)

---

## 9. Other useful commands

```bash
acli jira project list --paginate --json      # a pagination flag is REQUIRED (--paginate / --limit N / --recent);
                                              # bare `project list --json` errors:
                                              # "at least one of the flags in the group [recent limit paginate] is required"
acli jira project list --recent               # up to 20 recently viewed (--recent also satisfies the group)
acli jira board list                          # boards (use --help for subcommands)
acli jira sprint list                         # sprints (use --help for subcommands)
acli jira auth status                         # confirm who you're authenticated as
acli jira field --help                        # inspect custom fields
acli jira filter --help                       # saved filters
```

---

## 10. Helper scripts

The `scripts/` directory next to this file bundles the two reusable
patterns used while seeding issues from a review:

- [`scripts/acli-create-parent-and-subtasks.sh`](scripts/acli-create-parent-and-subtasks.sh)
  — create a parent work item plus N sub-tasks from a directory of body
  files, driven by a `manifest.tsv`. This is the "turn a review into
  tracked sub-tasks" helper: write one `.md` per finding, list them in
  the manifest, run the script.
- [`scripts/acli-list-subtasks.py`](scripts/acli-list-subtasks.py)
  — given a parent key, print every sub-task's key + summary by parsing
  `acli jira workitem view <PARENT> --json --fields '*all'` (the
  default JSON omits `subtasks`, which is easy to miss — see §3).

Both read `<PROJECT-KEY>` from `jira-sdlc-tools.env` (team-shared) in the project
root (override with `--project` or the `PROJECT_KEY` env var). Run them from the
project root.

```bash
# Seed a review as a parent + sub-tasks:
mkdir -p /tmp/review/sub
echo "C1 summary" > /tmp/review/parent-summary.txt
printf 'c1\tC1: fix branch-context duplication\n' > /tmp/review/sub/manifest.tsv
echo "## Problem\n..." > /tmp/review/sub/c1.md
# (add one manifest row + one .md per finding)
acli-create-parent-and-subtasks.sh \
  --parent-summary "$(cat /tmp/review/parent-summary.txt)" \
  --parent-body /tmp/review/parent.md \
  --subtasks-dir /tmp/review/sub \
  --parent-type Story

# List what landed under the parent:
acli-list-subtasks.py --parent <PARENT-KEY>
```

---

## 12. PR-base resolver (git-config → Jira comment → env default)

Every leaf issue's PR needs a base branch. The assigner records it in two
places — one local (`git config branch.<branch>.parentbranch`), one
durable (a `"PR target branch: …"` Jira comment that survives a fresh
clone). This resolver checks both before falling back to the env default;
run it verbatim whenever a skill asks for a PR base:

```bash
CUR=$(git branch --show-current)
PR_BASE=$(git config branch."$CUR".parentbranch 2>/dev/null)
[ -z "$PR_BASE" ] && PR_BASE=$(acli jira workitem comment list --key <KEY> --json \
  | grep -oE 'PR target branch: [^ .]+' | head -1 | sed 's/PR target branch: //')
[ -z "$PR_BASE" ] && PR_BASE="<DEFAULT_BASE_BRANCH>"   # last resort — the skill flags this
echo "$PR_BASE"
```

Sources, in order:
1. `git config branch.<current>.parentbranch` — set by the assigner when
   the branch was created; local to this clone.
2. The issue's `"PR target branch: …"` Jira comment — the durable
   fallback the assigner (or executor, on the rare no-assigner path)
   posts; survives a fresh clone or different machine.
3. `<DEFAULT_BASE_BRANCH>` from `jira-sdlc-tools.env` in the project
   root — used only when both sources above are empty, and the skill
   should call that out explicitly in its report.
