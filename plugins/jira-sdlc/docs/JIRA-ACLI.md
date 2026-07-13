# JIRA-ACLI.md — detailed companion to the acli call-site reference

Detailed reference for the **official Atlassian CLI (`acli`)**: rationale,
examples, discovery procedures, verification narratives, and every
command no skill invokes. This is the **on-demand companion** to the
lean runtime reference at
[`../skills/_shared/jira-acli-reference.md`](../skills/_shared/jira-acli-reference.md),
which holds only the command surface the three skills
(`jira-task-assigner`, `jira-task-executor`, `jira-task-reviewer`) and
`_shared/scripts` actually call, plus the failure-mode gotchas. The lean
file is read in full on every agent run; **this file is read only when
you need the "why", the discovery procedure, or a command a skill never
invokes** — never required mid-run.

This file **mirrors the lean file's §0–§12 numbering**: each section here
holds the supplementary material for that same number in the lean file,
and the lean file links to the matching section here per-section (not
one link at the top). Sections whose content is entirely in the lean file
because a skill invokes it directly — §7 (Git workflow / branch
convention) and §12 (PR-base resolver) — carry no supplementary material
and so have no entry here.

Project-specific values resolve from `jira-sdlc-tools.env` (team-shared)
and `jira-sdlc-tools.local.env` (machine-specific) in the project root —
see the lean reference's intro for the full token list. `acli` version
confirmed against: `1.3.22-stable`.

**Sections:** [0. Auth](#0-auth) ·
[1. Issue types](#1-issue-type-hierarchy) ·
[2. Creating issues](#2-creating-issues) ·
[3. Reading / listing](#3-reading--listing-issues) ·
[4. Editing / transitioning / assigning](#4-editing--transitioning--assigning) ·
[5. Linking](#5-linking-issues) ·
[6. Comments / worklogs](#6-comments--worklogs) ·
[8. Destructive commands](#8-destructive--risky-commands--use-with-care) ·
[9. Other useful commands](#9-other-useful-commands) ·
[10. Helper scripts](#10-helper-scripts) ·
[11. Cross-reference to jira-cli](#11-cross-reference-to-jira-cli)

(No §7 or §12 here — see the note above.)

---

## 0. Auth

`acli` keeps credentials in its own store — authenticate once, then every
subsequent `acli jira ...` works without a token prefix. This section is
the full "why" behind the gotchas the lean file states as rules.

### Why `auth logout` must come before a re-login

A second `auth login` does **not** overwrite an existing stored
credential — acli preserves the old one, so a stale or revoked token
silently survives the re-login. Worse, the failure is disguised:
`acli jira auth status` keeps reporting `✓ Authenticated` from its cache
while every real call fails with
`unauthorized: use 'acli [product] auth login' to authenticate`. So
whenever you change the token, log out before logging back in:

```bash
acli jira auth logout   # discard the previous credential so the new one takes effect
```

### `--token` reads stdin — path or value, both work

`--token` takes no value, reads from standard input. `<JIRA_TOKEN>`
(resolved from `jira-sdlc-tools.local.env`) may be either a path to a
token file OR the raw API token value itself — both work, and acli can't
tell the difference since it only reads stdin. Use the form that matches
how the variable is set on your machine:

```bash
# Rotating or switching tokens? Run `acli jira auth logout` first (see above).

# path form — when JIRA_TOKEN is a file path:
acli jira auth login \
  --site "<JIRA_ACCOUNT_URL>" \
  --email "<JIRA_ACCOUNT_EMAIL>" \
  --token < <JIRA_TOKEN>

# value form — when JIRA_TOKEN holds the raw token:
printf '%s' "<JIRA_TOKEN>" | acli jira auth login \
  --site "<JIRA_ACCOUNT_URL>" \
  --email "<JIRA_ACCOUNT_EMAIL>" \
  --token
```

`<JIRA_ACCOUNT_URL>`, `<JIRA_ACCOUNT_EMAIL>`, and `<JIRA_TOKEN>` are
resolved from `jira-sdlc-tools.local.env` (machine-specific) in the
project root.

### Verify with a real call, not the cached status

`auth status` reads from cache and can report `✓ Authenticated` on a
dead credential (per the warning above), so it is necessary but not
sufficient. The real proof is a call that actually hits the API:

```bash
acli jira auth status                 # necessary but NOT sufficient — cached
acli jira project list --paginate --json | grep -w "<PROJECT-KEY>"   # the real proof
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

### Confirming the issue type names for *your* project

**Issue type names are project-specific — confirm against your real
project before relying on them.** The names in the lean file are
confirmed for this toolkit's reference project; a different Jira project
may name them differently. Two reliable ways to discover the exact names
for *your* project:

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

The lean file covers the top-level and sub-task create commands, the
`--description-file` / plain-text-or-ADF-not-markdown gotcha, and the
`jira-cli` parent-drop gotcha. This section holds the rest: bulk create,
the full `create` flag reference, the "split into parallel sub-tasks"
workflow narrative, and key-capture detail.

### Plain-text / ADF / markdown — the verified evidence

The lean file states the rule ("plain text or ADF, not markdown"); the
evidence below is verification that backs it. A markdown body is stored
verbatim as one plain-text paragraph, so `##`, `-`, and `1.` show up
literally instead of rendering as headings/lists (verified: a
`## Summary` description landed as a single `doc → paragraph → text`
node with the `##` intact). For structured formatting, supply an ADF
document (the shape `acli jira workitem create --generate-json` prints);
for plain prose, plain text is fine.

### Other useful create flags (confirmed via `acli jira workitem create --help`)

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

The lean file covers `view`, the key-positional gotcha, the
default-`--json`-omits-`subtasks`/`parent`/`comment` gotcha, and the two
canonical `--fields` fetch lists. This section holds listing (`search`,
never invoked by a skill), the `search` flag reference, the `--fields
'*all'` payload caution, and the type/parent check.

### There is no `list` subcommand — listing is `search`

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

### The `--fields '*all'` payload caution

On comment-heavy issues `--fields '*all'` is almost entirely `comment`
bytes — the canonical lists in the lean file are the narrow,
purpose-fitted replacement. (Helper scripts narrow further to just the
fields they parse — `acli-list-subtasks.py` requests only
`subtasks,issuetype`; see §10.)

### Checking an issue's type and parent

```bash
acli jira workitem view <KEY> --json
# fields.issuetype.name    — e.g. "Task", "Story", "Bug", "Subtask"
# fields.parent.key        — present only when <KEY> is itself a sub-task
```

---

## 4. Editing / transitioning / assigning

No §4 command is invoked by a skill — status transitions are owned by
the repo's `jira_issue_transition_*.yml` GitHub Actions workflows (the
lean file's §4 has the trigger → transition table), and `edit` /
`assign` below are for human/manual use. The `transition` syntax is kept
here for the same manual use:

```bash
acli jira workitem transition --key <KEY> --status "<STATUS_IN_PROGRESS>" --yes
```

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

### Assign

```bash
acli jira workitem assign --key <KEY> --assignee @me --yes
acli jira workitem assign --key <KEY> --assignee "teammate@example.com" --yes
acli jira workitem assign --key <KEY> --remove-assignee --yes
```

---

## 5. Linking issues

No skill invokes link commands.

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

The lean file covers `comment create` (`--body` / `--body-file`, the
`--body-file -` / stdin gotcha, plain-text-or-ADF rule), the
machine-recoverable comment markers, and `comment list`. This section
holds comment `update` / `delete` / `visibility`, worklog, and the
other `comment create` flags.

### Other useful `comment create` flags

`-e/--edit-last` (replace your last comment instead of adding a new one —
handy for updating a status note in place), `--jql` (comment on many
issues), `--json`.

### Update / delete / visibility comments

```bash
acli jira workitem comment update --key <KEY> --body "..."   # see --help for the comment-id flag
acli jira workitem comment delete --help                       # needs the comment id
acli jira workitem comment visibility                         # get allowed visibility roles
```

### Worklog

```bash
acli jira workitem worklog add --key <KEY> --time-spent "1h 30m" --comment "note"
```

---

## 8. Destructive / risky commands — use with care

The lean file covers single `delete` (+ the never-auto-run agent rule)
and the `--yes` surface. This section holds bulk delete by JQL and the
`jira-cli` interactivity contrast (the full cross-reference is in §11).

### Bulk delete by JQL

```bash
acli jira workitem delete --jql "project = <PROJECT-KEY> AND status = \"To Do\"" --yes --ignore-errors
```

### `jira-cli` interactivity contrast

Unlike `jira-cli` (whose `delete` can't be run non-interactively),
`acli delete` **does** accept `--yes` to skip the prompt — so it *can*
run unattended. That makes the guardrails more important, not less — see
the lean file's agent rule (never auto-run `delete`).

---

## 9. Other useful commands

The lean file covers `project list --paginate --json` (with the
pagination-required gotcha). This section holds the rest — none invoked
by a skill.

```bash
acli jira project list --recent               # up to 20 recently viewed (--recent also satisfies the pagination group)
acli jira board list                          # boards (use --help for subcommands)
acli jira sprint list                         # sprints (use --help for subcommands)
acli jira auth status                         # confirm who you're authenticated as (see §0)
acli jira field --help                        # inspect custom fields
acli jira filter --help                       # saved filters
```

---

## 10. Helper scripts

The `scripts/` directory next to the lean reference
(`skills/_shared/scripts/`) bundles two reusable patterns used while
seeding issues from a review. These are **human-run helpers, not
invoked by any skill.**

- [`scripts/acli-create-parent-and-subtasks.sh`](../skills/_shared/scripts/acli-create-parent-and-subtasks.sh)
  — create a parent work item plus N sub-tasks from a directory of body
  files, driven by a `manifest.tsv`. This is the "turn a review into
  tracked sub-tasks" helper: write one `.md` per finding, list them in
  the manifest, run the script.
- [`scripts/acli-list-subtasks.py`](../skills/_shared/scripts/acli-list-subtasks.py)
  — given a parent key, print every sub-task's key + summary by parsing
  `acli jira workitem view <PARENT> --json --fields 'subtasks,issuetype'`
  (the only fields it parses — narrower than the §3 canonical lists; the
  default `--json` omits `subtasks`, which is easy to miss — see §3).

Both read `<PROJECT-KEY>` from `jira-sdlc-tools.env` (team-shared) in
the project root (override with `--project` or the `PROJECT_KEY` env
var). Run them from the project root.

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

## 11. Cross-reference to jira-cli

This reference uses the **official Atlassian CLI (`acli`)** rather than
`jira-cli` (the ankitpokhrel binary) because of a handful of
project-specific failures in `jira-cli` that `acli` gets right. The
differences that drove the choice:

### Parent on sub-task create — `jira-cli` silently drops it

`jira-cli` **silently drops the parent on sub-task create in this
project** — `-P <PARENT-KEY>` is accepted by the flag parser but never
sent in the POST body, so Jira returns `400 Issue type is a sub-task but
parent issue key or id not specified`. `acli`'s `--parent` works
correctly for the same operation. This is the primary reason the acli
reference exists: the assigner/executor create sub-tasks with `--parent`,
and `acli` is the CLI that actually sends it. (Stated as a runnable
gotcha in the lean file's §2.)

### `delete` interactivity — `acli` can run unattended

`jira-cli`'s `delete` can't be run non-interactively; `acli delete`
accepts `--yes` to skip the prompt, so it *can* run unattended. That
extra power is why the lean file's §8 carries the "never auto-run
`delete`" agent rule.

### `Subtask` spelling — no hyphen, in both CLIs' allowed-types list

The issue type is `Subtask` (no hyphen) for this project — confirmed via
the `acli` validation error
(`Allowed issue types for project are: Subtask, Epic, Task, Story, Feature, Bug`).
Passing `Sub-task` (with a hyphen) is rejected: the create returns
`Please provide valid issue type`. The same spelling gotcha applies
whichever CLI you use; the lean file's §1 table reflects it.

### `--yes` surface — different per command

`--yes` is **not** universal across `acli` — `workitem create` and
`comment create` reject it (already non-interactive); `edit` /
`transition` / `assign` / `delete` / `link create` / `create-bulk`
accept it. See the lean file's §8 for the full accept/reject list.
(`jira-cli`'s `--yes`/non-interactive surface differs again — don't
assume parity between the two CLIs; check each command's `--help`.)
