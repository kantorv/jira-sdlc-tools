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

## Detection logic

Transcripts split by provenance, because a session's project folder is
named after that session's cwd:

- **WORKTREE (certain, take ALL)** — the executor and reviewer run
  inside `<WORKTREES_DIR>/worktree-<KEY>`; every session filed under that
  project folder belongs to this issue. The folder persists in
  `~/.claude/projects` even after the worktree itself is deleted.
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

Both ports take the two `~/.claude/projects` transcript folders — the
main checkout's and the issue worktree's — **from the caller**, via the
mandatory `CONVERSATIONS_MAINREPO_PATH` and `CONVERSATIONS_WORKTREE_PATH`
environment variables (each already the resolved encoded folder path, not
a repo/worktree root). The script validates both up front and **exits 1**
with a clear stderr message if either is unset or not an existing
directory — there is no "no worktree, that's fine" path anymore, so an
issue with no worktree folder is the caller's call, not the script's. The
script no longer infers these from `git worktree list` / a cwd→folder-name
encoding: resolving them (reproducing Claude Code's folder naming — cwd
with path separators replaced by `-`; POSIX cwds contain only `/` and `.`
to replace, Windows cwds also need `:` and `\`, e.g. `C:\Users\u\proj` →
`C--Users-u-proj`) is now the caller's job.

The script is read-only unless `--attach` is passed, in which case it
hands the computed path list straight to the sibling uploader
`scripts/posix/jira_attach.sh` — which itself ships as a contract pair,
so the `.ps1` port calls its own `scripts/win/jira_attach.ps1` twin
natively (no bash). Exit 1 only on a usage/environment error.

## Script dispatch

Callers decide POSIX vs. Windows from their own runtime before invoking
either port — never by trying to infer it from a script's output:

```bash
bash  posix/sync_conversations.sh <ISSUE-KEY> [--attach] [--dry-run]
pwsh  win/sync_conversations.ps1   <ISSUE-KEY> [--attach] [--dry-run]
```

(paths above are relative to this file's own directory,
`conversation-debugger/scripts/`)

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
