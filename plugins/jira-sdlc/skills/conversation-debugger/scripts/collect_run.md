# `collect_run` — logic and execution nuances

`collect_run` is step 0 of the conversation-debugger skill: given a
`<skill-name>` and a Claude Code conversation transcript (`.jsonl`), it
validates the file, profiles it (turn counts, tool-call tallies, token
usage, elapsed time), recovers the Jira issue key from the one place that
skill is known to produce it, and — only once that key is trustworthy —
creates `conversations/<KEY>/` and copies the transcript in. It prints a
`KEY=VALUE` block on stdout that the skill reads to decide what to do
next. It ships twice — `posix/collect_run.sh` (bash + `jq`) and
`win/collect_run.ps1` (PowerShell 5.1+, native reimplementation, no
bash/`jq` needed) — same arguments, same `KEY=VALUE` output, same exit
codes. This doc covers the logic once (so it isn't duplicated across two
script headers) and the execution nuances that only show up when you
actually run the port on real machines.

## Arguments

Both ports take the identical positional argument set:

| Argument | Required | Description |
| --- | --- | --- |
| `<skill-name>` | yes | One of `jira-task-assigner`, `jira-task-executor`, `jira-task-reviewer`. Anything else exits 1 with a usage message — the script is the enforcement point for "only these three skills are analyzable." |
| `<conversation-path>` | yes | Path to a `.jsonl` transcript. Must exist; a missing file exits 1. |
| `[issue-key]` | no | Force the filing key instead of recovering it from the transcript (`KEY_STATUS=given`). Use this after the script reports `KEY_STATUS=unexpected`/`no-invocation` and a human has picked which issue the run belongs to. |

## Detection logic

**Is this transcript actually a run of `<skill-name>`?** The script scans
every `user` line's text content for `<command-name>…</command-name>`
tags and counts matches against `<skill-name>` — bare (`/jira-task-executor`)
or namespaced (`/jira-sdlc:jira-task-executor`), since the namespace
disappears on a loose-file install or a renamed plugin. The invocation
need not be the *first* command in the session — `/model`, `/usage`,
`/context`, `/compact` are all normal preludes — so the script looks
anywhere in the file, not just at the start. Zero matches means this
almost certainly isn't that skill's run: nothing is filed, the script
lists the commands the transcript *does* contain, and exits 2
(`KEY_STATUS=no-invocation`).

**Stub detection.** A transcript with zero `assistant` lines is a stub —
the real work happened in another session (resumed elsewhere, or a
partial sync). Nothing is filed; the script exits 2
(`KEY_STATUS=stub`) so the skill can write a short stub report instead
of trying to analyze content that isn't there.

**Where the issue key comes from is not a guess.** Each skill produces
its key at one specific, known site in its own run, and a recorded
transcript already contains that site:

| skill | when the key exists | where the script reads it |
|---|---|---|
| `jira-task-assigner` | only once the issue is created | the first `acli jira workitem create` tool result — `.key` from the `--json` form, else the first `<PROJECT-KEY>-<n>` found in its output (text/browse-URL form) |
| `jira-task-executor` / `jira-task-reviewer` | after statuscheck, derived from the worktree's branch | statuscheck's `issue_key` markdown-table row (its `branch` row as fallback) |

If that site never fires — no `workitem create` call for the assigner,
no resolved `issue_key` row for the executor/reviewer — the script
files nothing and exits 2 (`KEY_STATUS=unexpected`), naming the reason.
A mention of `<PROJECT-KEY>-<n>` found *anywhere else* in the transcript
is never used to decide the filing key: a run can cite an unrelated
issue ("do it like JST-9") far more often than it mentions its own
subject, so frequency is reported only as context (`KEY_RANKING`), never
the decision. `PROJECT-KEY` itself is read from `jira-sdlc-tools.env` /
`jira-sdlc-tools.local.env` (`PROJECT-KEY` or `PROJECT_KEY`) at the
project root — resolved via `git rev-parse --show-toplevel`, so the
script must be run from inside the project checkout.

**Run metrics are measured, not estimated.** Both ports compute the same
`SKILL_TURNS` / `TOOL_CALLS` / `TOKENS_*` / `WALL_CLOCK_S` etc. fields,
scoped to the named skill's own turns via each line's `attributionSkill`
so pre-skill chatter and other skills in the same session don't pollute
the numbers. One field is deliberately *not* skill-scoped: `TRANSCRIPT_BYTES`
is the profiled transcript's whole-file on-disk size (`wc -c` on POSIX,
`.Length` on Windows — both the file's byte count), which `collect_feature`
threads through to the feature report as each conversation's `size_bytes`.
`collect_run` is the one layer that holds the transcript path, so the size is
measured here and nowhere downstream. Two traps both ports avoid: (1) one API response is split
across several assistant lines that each repeat the *same* usage object —
summing per line overcounts, so token sums are computed after
deduplicating by `message.id`; (2) content blocks (tool calls) are *not*
duplicated across those split lines, so tool-call tallies are counted
over every line, not the deduped set.

**Output convention.** On success the script creates
`conversations/<KEY>/` at the project root (creating
`conversations/.gitignore` with `*` the first time, so transcripts —
raw session logs full of absolute paths, emails, instance URLs — never
get committed), copies the transcript in unmodified, and prints the
`KEY=VALUE` block plus the metrics fields. Both ports are otherwise
read-only: nothing is filed on any exit-2 path.

## Script dispatch

Callers decide POSIX vs. Windows from their own runtime before invoking
either port — never by trying to infer it from a script's output:

```bash
bash  posix/collect_run.sh <skill-name> <conversation-path> [issue-key]
pwsh  win/collect_run.ps1   <skill-name> <conversation-path> [issue-key]
```

(paths above are relative to this file's own directory,
`conversation-debugger/scripts/`)

### Execution examples

POSIX (bash):

```bash
# Recover the key, profile the run, file it under conversations/<KEY>/
bash posix/collect_run.sh jira-task-executor ~/.claude/projects/-home-you-src-myapp/abc123.jsonl

# Force the filing key (after a KEY_STATUS=unexpected/no-invocation stop)
bash posix/collect_run.sh jira-task-executor ~/.claude/projects/-home-you-src-myapp/abc123.jsonl JST-93
```

Windows — `pwsh` (PowerShell 7+):

```powershell
# Recover the key, profile the run, file it under conversations/<KEY>/
pwsh -File win/collect_run.ps1 jira-task-executor C:\Users\you\.claude\projects\C--Users-you-src-myapp\abc123.jsonl

# Force the filing key (after a KEY_STATUS=unexpected/no-invocation stop)
pwsh -File win/collect_run.ps1 jira-task-executor C:\Users\you\.claude\projects\C--Users-you-src-myapp\abc123.jsonl JST-93
```

Windows — `powershell.exe` (5.1, ships with Windows): same invocations, plus
`-ExecutionPolicy Bypass` for that one call unless the machine's policy is
already `RemoteSigned`/`Unrestricted` (see execution-policy note below):

```powershell
powershell -ExecutionPolicy Bypass -File win/collect_run.ps1 jira-task-executor C:\Users\you\.claude\projects\C--Users-you-src-myapp\abc123.jsonl
powershell -ExecutionPolicy Bypass -File win/collect_run.ps1 jira-task-executor C:\Users\you\.claude\projects\C--Users-you-src-myapp\abc123.jsonl JST-93
```

Every example above only reads the transcript and the local `conversations/`
tree — nothing is uploaded or posted to Jira; that happens later, in the
skill's own steps (and separately, via `sync_conversations`/`jira_attach`).

## Execution nuances

**The bash original needs a real `jq`; the Windows port doesn't.** The
posix script shells out to `jq` for every JSON read and validation step.
On a bare Windows box with no `jq` on `PATH` (no Chocolatey/winget/scoop
package installed), the bash script fails outright with `jq: command not
found` before it does anything else. This is exactly why the `.ps1` port
reimplements the same logic natively with `ConvertFrom-Json` and .NET
regex/collections instead of shelling out to `jq` — no bash, no `jq`
dependency on the Windows path.

**`ConvertFrom-Json` silently coerces the `timestamp` field — worked
around, not inherited.** Same trap documented in
[`sync-conversation.md`](sync-conversation.md): a JSON string that looks
like an ISO-8601 timestamp gets auto-converted to `[DateTime]` on
parse, which drops the UTC `Z`/precision and reformats to a
locale-specific string on `.ToString()` (`2026-07-17T14:06:39.127Z`
silently becomes `07/17/2026 14:06:39`). `collect_run.ps1` avoids this by
capturing the raw `"timestamp":"…"` text straight off each line with a
regex, before the line is ever handed to `ConvertFrom-Json`, and uses
that raw string for `FIRST_TS`/`LAST_TS` and the `WALL_CLOCK_S`
computation. Confirmed by running the port against a real transcript and
checking `FIRST_TS`/`LAST_TS` came back in the original `…Z` form, not a
reformatted locale string.

**Verified on `pwsh` (PowerShell 7.6.3).** Run against a real
`jira-task-executor` transcript: correctly recovered `KEY_STATUS=expected`
/ `ISSUE_KEY=JST-119` from statuscheck's `issue_key` row, filed
`conversations/JST-119/`, and printed sane metrics (`FIRST_TS`/`LAST_TS`
in proper ISO-8601, `WALL_CLOCK_S≈1449`). Also verified: a bad skill name
and a missing transcript path both exit 1 with a clear stderr message; a
transcript that never invoked the named skill exits 2 with
`KEY_STATUS=no-invocation` and lists the commands it does contain; an
explicit `[issue-key]` argument short-circuits key recovery with
`KEY_STATUS=given`.

**Windows PowerShell 5.1 needs its execution policy addressed before an
unsigned `.ps1` will run at all.** Under the default `Restricted` policy,
`powershell -File collect_run.ps1 ...` fails with `UnauthorizedAccess:
running scripts is disabled on this system` before the script itself gets
a chance to run. This is standard Windows behavior for *any* unsigned
script, not specific to this port — every script under `win/` needs the
same accommodation. Options, in order of preference: run with
`-ExecutionPolicy Bypass` for just that invocation (no lasting change to
the machine), or have the machine's own policy already set to
`RemoteSigned`/`Unrestricted`. `pwsh` (PowerShell 7+) was not observed to
require this on the same machine — its default policy differs. Skills
invoking this script should assume this prerequisite rather than
treating a policy error as a script bug.
