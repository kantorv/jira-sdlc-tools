# `sync_conversations` — logic and execution nuances

`sync_conversations` finds the Claude Code conversation transcripts
(`.jsonl` under `~/.claude/projects`) that belong to a given Jira issue,
prints them grouped, and ends with a machine-readable `=== attachment
paths ===` list. It ships twice — `posix/sync_conversations.sh` (bash +
embedded python3) and `win/sync_conversations.ps1` (PowerShell 5.1+,
native reimplementation, no bash/python3 needed on the read-only path) —
same arguments, same stdout shape, same exit codes. This doc covers the
detection logic once (so it isn't duplicated across two script headers)
and the execution nuances that only show up when you actually run the
port on real machines.

## Arguments

Both ports take the identical argument set — one positional, four flags:

| Argument | Required | Description |
| --- | --- | --- |
| `<ISSUE-KEY>` | yes | The Jira issue key, e.g. `JST-93`. Positional — matched against `[A-Za-z]*-[0-9]*`; anything else (missing, malformed, bare `-`) prints usage to stderr and exits 1. |
| `--title "<summary>"` | no | Overrides the issue's Jira summary used for signal 2 of the main-checkout pin (see Detection logic below). Self-fetched via `acli jira workitem view <KEY>` when omitted and `acli` is available, so callers normally don't pass it — it exists to keep the detector runnable offline or against a Jira instance `acli` can't reach. |
| `--created "<iso8601>"` | no | Overrides the issue's Jira `created` instant used for signal 3 (the decisive tie-breaker). Same self-fetch/offline rationale as `--title`. Accepts both the transcript `…Z` form and Jira's `…+0300` offset form. |
| `--attach` | no | Switches the script from read-only detection to actually uploading: hands the computed attachment-path list to the sibling `jira_attach` script (bash: `posix/jira_attach.sh`; Windows: `win/jira_attach.ps1`). Without it, the script only prints the grouped listing and the `=== attachment paths ===` block — nothing is written, transitioned, or uploaded. |
| `--dry-run` | no | Only meaningful combined with `--attach` — passed straight through to `jira_attach`, which previews the upload without performing it. Ignored (has no effect) when `--attach` is absent. |

`--title`/`--created` each accept either a glued `=` form or a
space-separated form on the bash port (`--title=foo` or `--title foo`);
the `.ps1` port also parses both, but under `pwsh -File` the glued form
gets mis-split at the value's colon, so pass these two as separate
space-separated tokens on Windows (see Execution nuances below).

Beyond the CLI arguments, both ports read two machine-config values —
`CONVERSATIONS_MAINREPO_PATH` and `CONVERSATIONS_WORKTREES_PREFIX` — from
`jira-sdlc-tools.local.env` to locate the two transcript folders (see
**Configuration** below). These are not script arguments and are never
passed on the command line.

## Detection logic

Transcripts split by provenance, because a session's project folder is
named after that session's cwd:

- **WORKTREE (certain, take ALL)** — the executor and reviewer run
  inside `<WORKTREES_DIR>/worktree-<KEY>`; every session filed under that
  project folder belongs to this issue. The folder persists in
  `~/.claude/projects` even after the worktree itself is deleted. Each
  worktree row is annotated with a `↳ skill(s):` line naming which of the
  three jira-sdlc skills (`jira-task-assigner` / `jira-task-executor` /
  `jira-task-reviewer`) that session invoked, in first-seen order —
  detected from the same structured `<command-name>` tag used to pin the
  main-checkout session. It tells you which transcript to hand back to
  `conversation-debugger`; a session that invoked none gets no such line.
- **MAIN checkout (take exactly ONE — the session that created the
  issue)** — the assigner runs here, interleaved with unrelated
  sessions. Out of "any session that ever mentioned `<KEY>`," the single
  creating session is pinned by layering three signals, strongest last:
  1. it invoked `/jira-sdlc:jira-task-assigner` (a structured
     `<command-name>` tag — immune to the key merely being discussed in
     prose elsewhere in the transcript)
  2. the issue's Jira **title** appears in it (the assigner was invoked
     with that title)
  3. the issue's Jira `created` instant falls inside the session's
     first..last message-timestamp window — the decisive tie-breaker,
     since only the session that was live at creation time could have
     created the issue

  `--title`/`--created` (self-fetched via `acli` when omitted) drive
  signals 2 and 3. Without them the script still runs but can only list
  candidates, not pick one.

Both ports resolve the two `~/.claude/projects` transcript folders from
**config**, not from git / a cwd-encoding step. Two
`jira-sdlc-tools(.local).env` values pin them:
`CONVERSATIONS_MAINREPO_PATH` is the main checkout's folder (used as-is),
and `CONVERSATIONS_WORKTREES_PREFIX` is the prefix shared by every
worktree's folder — this issue's is `<prefix>worktree-<KEY>`. Each holds
the resolved encoded folder path (Claude Code names a folder after the
session's cwd with every path separator replaced by `-`, e.g.
`C:\Users\u\proj` → `C--Users-u-proj`), and you set them once per machine.
The script reads them from the env files (not the process environment, so
the agent can't widen the scope by exporting a variable) and **exits 1**
with a clear stderr message if `CONVERSATIONS_MAINREPO_PATH` isn't an
existing directory, if `CONVERSATIONS_WORKTREES_PREFIX` is unset, or if
the resolved `<prefix>worktree-<KEY>` doesn't exist (the issue never had a
worktree — nothing to sync). Pinning a prefix in config, rather than
letting the script compute arbitrary paths, is deliberate: it scopes this
read-only builtin to the configured main checkout and worktrees tree, and
nothing else under `~/.claude/projects`. Both variables are described in
[`../../_shared/project-config.md`](../../_shared/project-config.md).

The script is read-only unless `--attach` is passed, in which case it
hands the computed path list straight to the sibling uploader
`scripts/posix/jira_attach.sh` — which itself ships as a contract pair,
so the `.ps1` port calls its own `scripts/win/jira_attach.ps1` twin
natively (no bash). Exit 1 only on a usage/environment error.

## Configuration — the two transcript-folder variables

Both folders come from `jira-sdlc-tools.local.env` (machine-specific; set
once, read by the script itself — never passed on the command line). They
matter only to this builtin, so a project that doesn't run
`sync_conversations` can leave both unset.

| Variable | What it is | Example |
|---|---|---|
| `CONVERSATIONS_MAINREPO_PATH` | The main checkout's `~/.claude/projects` transcript folder, used as-is (where the assigner's issue-creating session lives). | `~/.claude/projects/-home-you-src-myapp` |
| `CONVERSATIONS_WORKTREES_PREFIX` | The prefix shared by every worktree's transcript folder; the script appends `worktree-<KEY>` to locate one issue's folder. A fixed prefix (not per-issue paths) is what scopes the builtin to your worktrees tree and nothing else under `~/.claude/projects`. | `~/.claude/projects/-home-you-src-myapp-worktrees-` |

Each holds an *encoded* folder path — Claude Code names a project folder
after the session's cwd with every path separator replaced by `-` (e.g.
`C:\Users\u\proj` → `C--Users-u-proj`), so append `worktree-<KEY>` to the
prefix and you get exactly that issue's folder name. For example
`CONVERSATIONS_WORKTREES_PREFIX=/home/you/.claude/projects/-home-you-src-JST-worktrees-`
resolves `JST-70` to
`/home/you/.claude/projects/-home-you-src-JST-worktrees-worktree-JST-70`.
**The prefix ends at the encoded worktrees *directory* (`…-JST-worktrees-`),
not at `…-worktree-`** — ending it a level deeper would double to
`…-worktree-worktree-JST-70` and never match. The script **exits 1**
if `CONVERSATIONS_MAINREPO_PATH` is not an existing directory, if
`CONVERSATIONS_WORKTREES_PREFIX` is unset, or if the resolved
`<prefix>worktree-<KEY>` folder does not exist (the issue never had a
worktree — nothing to sync). Full descriptions live in
[`../../_shared/project-config.md`](../../_shared/project-config.md).

## Script dispatch

Callers decide POSIX vs. Windows from their own runtime before invoking
either port — never by trying to infer it from a script's output:

```bash
bash  posix/sync_conversations.sh <ISSUE-KEY> [--attach] [--dry-run]
pwsh  win/sync_conversations.ps1   <ISSUE-KEY> [--attach] [--dry-run]
```

(paths above are relative to this file's own directory,
`conversation-debugger/scripts/`)

### Execution examples

POSIX (bash):

```bash
# Detect & list candidate transcripts, read-only
bash posix/sync_conversations.sh JST-93

# Detect and actually attach them to the issue
bash posix/sync_conversations.sh JST-93 --attach

# Preview what would be attached without uploading
bash posix/sync_conversations.sh JST-93 --attach --dry-run

# Offline, with manual title/created overrides (skips the acli self-fetch)
bash posix/sync_conversations.sh JST-93 --title="Fix login bug" --created="2026-07-01T12:00:00Z"
```

Windows — `pwsh` (PowerShell 7+):

```powershell
# Detect & list candidate transcripts, read-only
pwsh -File win/sync_conversations.ps1 JST-93

# Detect and actually attach them to the issue
pwsh -File win/sync_conversations.ps1 JST-93 --attach

# Preview what would be attached without uploading
pwsh -File win/sync_conversations.ps1 JST-93 --attach --dry-run

# Offline, with manual title/created overrides — space-separated tokens, NOT --created=...
# (pwsh -File splits the glued `=` form at the value's colon before the script sees it)
pwsh -File win/sync_conversations.ps1 JST-93 --title "Fix login bug" --created "2026-07-01T12:00:00Z"
```

Windows — `powershell.exe` (5.1, ships with Windows): same invocations, plus
`-ExecutionPolicy Bypass` for that one call unless the machine's policy is
already `RemoteSigned`/`Unrestricted` (see execution-policy note below):

```powershell
powershell -ExecutionPolicy Bypass -File win/sync_conversations.ps1 JST-93
powershell -ExecutionPolicy Bypass -File win/sync_conversations.ps1 JST-93 --attach
powershell -ExecutionPolicy Bypass -File win/sync_conversations.ps1 JST-93 --attach --dry-run
powershell -ExecutionPolicy Bypass -File win/sync_conversations.ps1 JST-93 --title "Fix login bug" --created "2026-07-01T12:00:00Z"
```

Every example above only reads Jira and the transcript store; nothing is
uploaded unless `--attach` is present.

## Execution nuances

**The bash original needs a real `python3`; the Windows port doesn't.**
The posix script delegates its JSON/timestamp logic to an embedded
python3 program. On a machine where `python3`/`python` resolve only to
the Windows Store app-execution-alias stub (not a real interpreter —
common on a fresh Windows box before anyone's installed Python), the
bash script fails outright with "Python was not found." This is exactly
why the `.ps1` port reimplements that logic natively instead of shelling
out to python3 itself: ISO-8601 timestamp parsing (via regex extraction,
since `ConvertFrom-Json` silently coerces date-shaped strings and drops
the timezone offset) and KB rounding (via
`[System.MidpointRounding]::ToEven`, to match Python 3's banker's
rounding rather than PowerShell's default `Math.Round` behavior).

**PowerShell 5.1 (`powershell.exe`) and 7+ (`pwsh`) both work, and
produce byte-identical output.** The port's own header claims `5.1+`
support; verified by running the identical `JST-113` invocation through
both and diffing stdout — no divergence.

**Windows PowerShell 5.1 needs its execution policy addressed before an
unsigned `.ps1` will run at all.** Under the default `Restricted` policy,
`powershell -File sync_conversations.ps1 ...` fails with `UnauthorizedAccess:
running scripts is disabled on this system` before the script itself gets
a chance to run. This is standard Windows behavior for *any* unsigned
script, not specific to this port — every script under `win/` needs the
same accommodation. Options, in order of preference: run with
`-ExecutionPolicy Bypass` for just that invocation (no lasting change to
the machine), or have the machine's own policy already set to
`RemoteSigned`/`Unrestricted`. `pwsh` (PowerShell 7+) was not observed to
require this on the same machine — its default policy differs. Skills
invoking these scripts should assume this prerequisite rather than
treating a policy error as a script bug.
