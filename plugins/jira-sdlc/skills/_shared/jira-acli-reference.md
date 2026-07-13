# acli-reference.md (Official Atlassian CLI `acli`) — lean call-site reference

Reference for Claude Code when creating/managing Jira issues via the
**official Atlassian CLI (`acli`)**. This is the **lean, runtime
reference**: the exact command surface the three skills
(`jira-task-assigner`, `jira-task-executor`, `jira-task-reviewer`) and
`_shared/scripts` actually invoke, plus only the gotchas that make a
command fail if unknown. Rationale, examples, discovery procedures, and
every command no skill invokes live in the detailed companion
[`../../docs/JIRA-ACLI.md`](../../docs/JIRA-ACLI.md), linked
**per-section** below (not one link at the top). An agent can complete
any assigner/executor/reviewer run from this lean file alone — the
detailed companion is read on demand, never required mid-run.

Auth is set up with an API token (Cloud). Project-specific values come
from two files in the project root:

**`jira-sdlc-tools.env` (team-shared, committed)**
- `<PROJECT-KEY>`
- `<DEFAULT_BASE_BRANCH>`
- `<PRODUCTION_BRANCH>`
- `<STATUS_TODO>`
- `<STATUS_IN_PROGRESS>`
- `<STATUS_IN_REVIEW>`
- `<STATUS_DONE>`

**`jira-sdlc-tools.local.env` (machine-specific, gitignored)**
- `<WORKTREES_DIR>`
- `<JIRA_ACCOUNT_URL>`
- `<JIRA_ACCOUNT_EMAIL>`
- `<JIRA_TOKEN>`

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

⚠️ **Rotating or switching tokens? `acli jira auth logout` FIRST.** A second
`auth login` does **not** overwrite an existing stored credential — acli
preserves the old one, so a stale or revoked token silently survives the
re-login. Worse, the failure is disguised: `acli jira auth status` keeps
reporting `✓ Authenticated` from its cache while every real call fails
with `unauthorized: use 'acli [product] auth login' to authenticate`. So
whenever you change the token, log out before logging back in:

```bash
acli jira auth logout   # discard the previous credential so the new one takes effect
```

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

Verify — with a **real call**, not just `auth status` (which reads from
cache and can report `✓ Authenticated` on a dead credential, per the
warning above):

```bash
acli jira auth status                 # necessary but NOT sufficient — cached
acli jira project list --paginate --json | grep -w "<PROJECT-KEY>"   # the real proof
```

→ Detailed: [`../../docs/JIRA-ACLI.md` §0](../../docs/JIRA-ACLI.md#0-auth)
for the full token-rotation narrative and the "disguised failure"
walkthrough.

---

## 1. Issue type hierarchy

Two-level hierarchy with no grouping above the top level:

```
Task / Story / Bug        (top-level, no parent)
 └── Subtask              (linked to its parent via --parent)
```

⚠️ **Issue type names are project-specific** — confirm against your real
project before relying on them (the two discovery procedures — trigger the
validation error, or inspect an existing issue's `fields.issuetype.name` —
are in [`../../docs/JIRA-ACLI.md` §1](../../docs/JIRA-ACLI.md#1-issue-type-hierarchy)).
For this toolkit's reference project:

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
the text to a file and load it with `--description-file`.

⚠️ `--description` / `--description-file` accept **plain text or
Atlassian Document Format (ADF)** (`--help`) — **not markdown**. A
markdown body is stored verbatim as one plain-text paragraph, so `##`,
`-`, and `1.` show up literally instead of rendering as headings/lists.
For structured formatting, supply an ADF document (the shape `acli jira
workitem create --generate-json` prints); for plain prose, plain text is
fine.

```bash
acli jira workitem create \
  --project "<PROJECT-KEY>" \
  --type "Task" \
  --summary "..." \
  --description-file /tmp/issue-body.txt
```

Capture the created issue's key with `--json` (`key` is a top-level
field) or grep it out of the text output (embedded in the returned browse
URL).

### ⚠️ Known gotcha — why you might reach for `acli` here

`jira-cli` (the ankitpokhrel binary) **silently drops the parent on
sub-task create in this project** — `-P <PARENT-KEY>` is accepted by the
flag parser but never sent in the POST body, so Jira returns `400 Issue
type is a sub-task but parent issue key or id not specified`. `acli`'s
`--parent` works correctly for the same operation, which is why this
reference exists. If you see that 400 from `jira-cli`, switch to the
`acli` command above rather than debugging the flag.

→ Detailed: [`../../docs/JIRA-ACLI.md` §2](../../docs/JIRA-ACLI.md#2-creating-issues)
for bulk create (`--from-json` / `--from-csv`), the full `create` flag
reference, the "split a task into parallel Sub-tasks" workflow narrative,
and the key-extraction one-liners.

---

## 3. Reading / listing issues

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
`key,issuetype,summary,status,assignee,description` — it **omits
`subtasks`, `parent`, and `comment`**. Name any field you need explicitly
with `--fields` (the default `--fields '*all'` pulls ~50 top-level
fields). This toolkit uses two canonical issue-fetch field lists — the
**single source of truth**: the skills cite them by name rather than
re-listing them.

| canonical list | `--fields` value | used by |
|---|---|---|
| **fetch-with-comments** | `summary,description,issuetype,status,parent,subtasks,comment` | `jira-task-executor` step 1 — it scans `fields.comment.comments` for the assigner's assignment report + `Task memory` notes (step 4) |
| **review-fetch** | `summary,description,issuetype,status,parent,subtasks` | `jira-task-reviewer` — it doesn't read comments, and `comment` dominates the payload on comment-heavy issues, so omitting it shrinks the parent + every per-sub-task fetch |

Naming `subtasks` explicitly returns it as an array of
`{"key": "...", "fields": {"summary": …, …}}`, so both
`fields.subtasks[].key` and the nested `.fields.summary` are available
without `*all`. `parent` and `comment` appear only when the issue actually
has them (a leaf has no `parent`; a non-parent's `subtasks` is `[]`), so
naming them is safe on any issue.

```bash
# executor fetch (with comments):
acli jira workitem view <KEY> --json --fields 'summary,description,issuetype,status,parent,subtasks,comment'
# reviewer fetch (no comments):
acli jira workitem view <KEY> --json --fields 'summary,description,issuetype,status,parent,subtasks'
```

→ Detailed: [`../../docs/JIRA-ACLI.md` §3](../../docs/JIRA-ACLI.md#3-reading--listing-issues)
for `workitem search --jql` (listing — never invoked by a skill), the
`search` flag reference, the `--fields '*all'` payload caution, and the
"checking an issue's type and parent" procedure.

---

## 4. Editing / transitioning / assigning

### Transition (invoked by the skills)

Status names are project-specific — use the `<STATUS_*>` tokens from
`jira-sdlc-tools.env`.

```bash
acli jira workitem transition --key <KEY> --status "<STATUS_IN_PROGRESS>" --yes
acli jira workitem transition --key <KEY> --status "<STATUS_IN_REVIEW>" --yes
```

→ Detailed: [`../../docs/JIRA-ACLI.md` §4](../../docs/JIRA-ACLI.md#4-editing--transitioning--assigning)
for `workitem edit` and `workitem assign` (neither is invoked by a skill)
plus bulk-edit-by-JQL.

---

## 5. Linking issues

No skill invokes link commands — see the detailed
[`../../docs/JIRA-ACLI.md` §5](../../docs/JIRA-ACLI.md#5-linking-issues)
for `link type` / `link create` / `link list` and the bulk forms.

---

## 6. Comments & worklogs

### Add a comment

```bash
# Short, inline:
acli jira workitem comment create --key <KEY> --body "Single-line comment"

# Long / multi-line — write to a file, load it:
acli jira workitem comment create --key <KEY> --body-file /tmp/comment.txt
```

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

(`--body` / `--body-file` accept **plain text or ADF**, same rule as
`--description*` (§2) — `--help` says so for both. Whether a comment body
renders as markdown depends on a site-level setting acli can't report, so
don't assume either way; use plain text or ADF deliberately.)

### Machine-recoverable comment markers

Some comments are written with a fixed leading marker so a later session
(or a human) can grep them back out of an issue. Mirror the exact prefix
when posting, and match on it when reading:

- `PR target branch: <branch>.` — the PR base for the issue's branch,
  posted by `jira-task-assigner` (or manually, on the no-assigner
  bootstrap path — §7) and consumed by the §12 PR-base resolver.
- `Task memory (jira-task-executor)` — a durable per-task **memory** note
  the executor leaves for future sessions (findings, gotchas, design
  decisions + rationale, recovery context). List them with
  `acli jira workitem comment list --key <KEY> --json` and grep the marker.
  They are deliberately distinct from the executor's single end-of-run
  report and from the `PR target branch:` line above, so grepping the
  marker returns only memory notes.

### List a work item's comments (invoked)
```bash
acli jira workitem comment list --key <KEY> --json
```

→ Detailed: [`../../docs/JIRA-ACLI.md` §6](../../docs/JIRA-ACLI.md#6-comments--worklogs)
for comment `update` / `delete` / `visibility`, worklog add, and the
other `comment create` flags (`-e/--edit-last`, `--jql`, `--json`).

---

## 7. Git workflow — branch convention

Decision rule: every change goes on its own branch, `feature/<KEY>-<slug>` or
`hotfix/<KEY>-<slug>` — no "small enough to commit straight to the
working branch" shortcut. **The prefix follows the base branch, not the
issue type** (SDLC.md §2): `feature/` = branched from
`<DEFAULT_BASE_BRANCH>` (`development`), covering all planned work —
features *and* bug fixes alike; `hotfix/` = an emergency fix branched
from `<PRODUCTION_BRANCH>`. `jira-task-assigner` pre-creates the branch
and worktree for every leaf issue, and since it only ever branches from
`development`, every branch it creates is a `feature/` branch — a
`hotfix/` branch is only ever produced by the no-assigner bootstrap below
when it branches from `<PRODUCTION_BRANCH>`.

GitHub-for-Jira links a branch to an issue purely by finding the issue
key inside the branch name — no API call required.

```
git checkout -b feature/<ISSUE-KEY>-<slugified-summary>
git push -u origin feature/<ISSUE-KEY>-<slugified-summary>
```

Slugify the title: lowercase, spaces → hyphens, strip punctuation.
`"Fix null pointer on login!"` → `fix-null-pointer-on-login`.

### No-assigner bootstrap (issue with no branch/worktree yet)

`jira-task-executor` never creates the issue branch — it derives the
issue key *from* the branch it's standing on, so there is no state where
it runs and the branch is missing. When an issue was created without
`jira-task-assigner` (e.g. an ad-hoc `Bug`), provision it manually
**before** invoking the executor:

1. Pick the prefix from the **base branch you're branching from** per the
   rule above: `<PRODUCTION_BRANCH>` (an emergency production fix) →
   `hotfix/`; any other base, such as `<DEFAULT_BASE_BRANCH>`
   (`development`) → `feature/`.
2. From the intended base branch — checked out and up to date with
   origin; this is what the PR will target:
   ```bash
   BASE=$(git branch --show-current)
   git worktree add <WORKTREES_DIR>/worktree-<KEY> -b <prefix>/<KEY>-<slug> "$BASE"
   git config branch."<prefix>/<KEY>-<slug>".parentbranch "$BASE"
   ```
3. Post the durable PR-base fallback the assigner normally posts
   (single-line form — §6 for comment mechanics):
   ```bash
   acli jira workitem comment create --key <KEY> --body "PR target branch: $BASE."
   ```
4. `cd` into the new worktree and run the executor.

---

## 8. Destructive / risky commands — use with care

```bash
acli jira workitem delete --key <KEY> --yes
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

→ Detailed: [`../../docs/JIRA-ACLI.md` §8](../../docs/JIRA-ACLI.md#8-destructive--risky-commands--use-with-care)
for bulk delete by JQL and the `jira-cli` interactivity contrast.

---

## 9. Other useful commands

```bash
acli jira project list --paginate --json      # a pagination flag is REQUIRED (--paginate / --limit N / --recent);
                                              # bare `project list --json` errors:
                                              # "at least one of the flags in the group [recent limit paginate] is required"
```

`acli jira auth status` confirms who you're authenticated as (see §0).

→ Detailed: [`../../docs/JIRA-ACLI.md` §9](../../docs/JIRA-ACLI.md#9-other-useful-commands)
for `project list --recent`, `board`, `sprint`, `field`, and `filter`
(none invoked by a skill).

---

## 10. Helper scripts

The `scripts/` directory next to this file bundles two human-run helpers
(not invoked by any skill) —
[`../../docs/JIRA-ACLI.md` §10](../../docs/JIRA-ACLI.md#10-helper-scripts)
documents `acli-create-parent-and-subtasks.sh` (seed a parent + sub-tasks
from a `manifest.tsv`) and `acli-list-subtasks.py` (list a parent's
sub-tasks by parsing `view <PARENT> --json --fields 'subtasks,issuetype'`).

---

## 11. Cross-reference to jira-cli

This section points to the detailed docs: the full comparison of `acli`
vs `jira-cli` (the ankitpokhrel binary) — when to use which, where they
diverge on flags, and the project-specific spelling/behaviour differences
(including the `Subtask`-no-hyphen note referenced in §1, and the
parent-drop failure in §2) — lives in
[`../../docs/JIRA-ACLI.md` §11](../../docs/JIRA-ACLI.md#11-cross-reference-to-jira-cli).

---

## 12. PR-base resolver (git-config → Jira comment → parent-branch search → env default)

Every leaf issue's PR needs a base branch. The assigner records it in two
places — one local (`git config branch.<branch>.parentbranch`), one
durable (a `"PR target branch: …"` Jira comment that survives a fresh
clone). This resolver checks both before attempting a parent-branch search,
then falling back to the env default; run it verbatim whenever a skill asks
for a PR base:

```bash
CUR=$(git branch --show-current)
PR_BASE=$(git config branch."$CUR".parentbranch 2>/dev/null)
[ -z "$PR_BASE" ] && PR_BASE=$(acli jira workitem comment list --key <KEY> --json \
  | grep -oE 'PR target branch: [^" ]+' | head -1 \
  | sed -e 's/PR target branch: //' -e 's/\.$//')
# Parent-branch recovery for sub-tasks: if still empty AND issue has a parent,
# search for the parent's feature branch before falling back to DEFAULT_BASE_BRANCH
if [ -z "$PR_BASE" ] && [ -n "$PARENT_KEY" ]; then
  MATCHES=$(git branch -a --list "*feature/$PARENT_KEY-*" "*hotfix/$PARENT_KEY-*" 2>/dev/null | wc -l)
  if [ "$MATCHES" -eq 1 ]; then
    PR_BASE=$(git branch -a --list "*feature/$PARENT_KEY-*" "*hotfix/$PARENT_KEY-*" 2>/dev/null | sed -E 's#^[* ]+##; s#^remotes/origin/##' | head -1)
  elif [ "$MATCHES" -gt 1 ]; then
    echo "Ambiguous: found $MATCHES branches matching parent key $PARENT_KEY. Cannot determine PR base automatically."
    exit 1
  fi
fi
[ -z "$PR_BASE" ] && PR_BASE="<DEFAULT_BASE_BRANCH>"   # last resort — the skill flags this
echo "$PR_BASE"
```

Sources, in order:
1. `git config branch.<current>.parentbranch` — set by the assigner when
   the branch was created; local to this clone.
2. The issue's `"PR target branch: …"` Jira comment — the durable
   fallback the assigner posts (or the no-assigner bootstrap does, §7);
   survives a fresh clone or different machine.
3. **Parent-branch search** (sub-tasks only) — when the leaf issue has a
   parent (`PARENT_KEY` is an environment variable holding the parent's key),
   search for `feature/<PARENT_KEY>-*` or `hotfix/<PARENT_KEY>-*` branches.
   - Exactly one match → use it as `PR_BASE`.
   - Zero or multiple matches (ambiguous) → stop and ask the user for the
     correct base branch. Do NOT fall back to `DEFAULT_BASE_BRANCH`.
4. `<DEFAULT_BASE_BRANCH>` from `jira-sdlc-tools.env` in the project
   root — used only when all sources above are empty, and the skill
   should call that out explicitly in its report.
