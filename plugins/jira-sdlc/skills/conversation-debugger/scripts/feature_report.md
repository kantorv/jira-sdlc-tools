# `feature_report` — logic and execution nuances

`feature_report` is the report-builder half of the feature roll-up: it consumes
the JSON that [`collect_feature`](collect_feature.md) emits and renders a
markdown feature report from it. The pipeline is one direction only —

```
collect_feature <KEY>  ->  JSON  ->  feature_report  ->  markdown
```

— and the split of responsibility is strict: **`collect_feature` owns the JSON
schema; `feature_report` only reads it.** Every number in the report is a value
the collector already measured; the report-builder computes nothing and
re-measures nothing. The schema is documented in
[`../references/feature-report-schema.md`](../references/feature-report-schema.md).

**This round it ships Windows-only** (`win/feature_report.ps1`). The POSIX twin
(`posix/feature_report.sh`) is a deliberate **stub** that exits non-zero — an
explicit parity gap, matching `collect_feature`.

## Arguments and input

| Input | Description |
| --- | --- |
| `[<json-path>]` (positional) | Path to a `collect_feature` JSON file. A missing file exits 1. |
| stdin | If no path is given (or the path is `-`), the JSON is read from the pipe — both the PowerShell object pipeline (`… \| .\feature_report.ps1`) and a process's redirected stdin (`pwsh … \| pwsh feature_report.ps1`) work. |

With **no path and no piped input** it prints usage and exits 1 rather than
blocking on the console. Empty or non-JSON input, or JSON missing the
`feature`/`conversations`/`aggregate` keys, exits 1 with a clear message.

```powershell
# 1. One-shot pipe (from stdin) — collector JSON straight in
pwsh win/collect_feature.ps1 JST-93 | pwsh win/feature_report.ps1 > JST-93-report.md

# 2. Two steps — from a saved JSON file
pwsh win/collect_feature.ps1 JST-93 > JST-93.json
pwsh win/feature_report.ps1 JST-93.json > JST-93-report.md
```

The report is written on PowerShell's success stream, so `>` captures it in
every form — as its own `pwsh` process, or as a stage inside an existing
session (`… | .\feature_report.ps1 > out.md`).

## What it renders

Markdown on stdout, nothing else (read-only — no files written, no Jira/git):

- **Summary** table — feature key, conversation count (and how many carried
  metrics), the feature's **total token consumption** broken into
  in/out/cache-read/cache-write, the union of models used, skills exercised,
  and issue keys touched.
- **Per-conversation** table — one row per record: uuid, provenance, skill,
  issue, model(s), the four token buckets + total, tool calls, and elapsed
  seconds. Records without metrics (stub/unexpected/no-skill) render their
  numeric cells as `-`.
- **Feature totals** — the summed token buckets and the grand total, plus the
  models across the feature.

The markdown structure is inline in the script (no external template to drift);
the one shared artifact is the JSON schema doc, which both halves point at.

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Markdown emitted. |
| `1` | Usage error, or unreadable / invalid / wrong-shape JSON. |

## Script dispatch

```powershell
pwsh  win/feature_report.ps1   [<json-path>]
```

```bash
bash  posix/feature_report.sh  [<json-path>]   # STUB — prints a notice and exits 3
```

(paths relative to this file's directory, `conversation-debugger/scripts/`)

Windows PowerShell 5.1 (`powershell.exe`) needs `-ExecutionPolicy Bypass` for
an unsigned `.ps1` unless the machine policy already allows it — same
prerequisite as every `win/` script; `pwsh` (7+) was not observed to require
it.

## Platform parity

The full implementation is `win/feature_report.ps1`.
`posix/feature_report.sh` is a **stub**: it prints a "NOT IMPLEMENTED on POSIX"
notice and exits `3`. A full bash port (bash + `jq`, reading the same collector
JSON) is future work; until then the usual diff-the-two-ports parity check in
AGENTS.md does not apply to this pair — by design.
