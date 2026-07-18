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

It renders **both feature types** the collector emits, detected from the JSON:

- **single-step** (`feature-report@2`, flat) → the original template, unchanged.
- **multistep** (`feature-report@3`, nested) → a parent summary, a "token share
  by feature part" table + pie, then one section per **child feature** with that
  child's conversations **in place**, and finally the feature-wide totals /
  by-skill / by-provenance / timeframe roll-ups and pies across the whole
  feature.

Detection is the presence of a `children` array (equivalently a `@3` schema
tag); `@1`/`@2` JSON has no `children` and renders through the **untouched**
single-step path, so there is **no regression** on existing single-step reports.

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

# 2. From a saved JSON file (produced by `collect_feature … > JST-93.json`)
pwsh win/feature_report.ps1 JST-93.json > JST-93-report.md

# 3. Same saved JSON on Windows PowerShell 5.1 (powershell.exe)
powershell -ExecutionPolicy Bypass -File win/feature_report.ps1 JST-93.json > JST-93-report.md
```

The report is written on PowerShell's success stream, so `>` captures it in
every form — its own `pwsh`/`powershell` process, a cross-process pipe
(`pwsh collect_feature.ps1 … | pwsh feature_report.ps1`), or a stage inside an
existing PowerShell session (`… | .\feature_report.ps1 > out.md`). The stdin
and file-path inputs render identically, on both PowerShell 7+ and 5.1.

## What it renders

Markdown on stdout, nothing else (read-only — no files written, no Jira/git).

### Single-step (`@2`)

- **Summary** table — feature key, conversation count (and how many carried
  metrics), the feature's **total token consumption** broken into
  in/out/cache-read/cache-write, the union of models used, skills exercised,
  and issue keys touched, plus total skill turns, total tool calls (with
  errors), and the activity span.
- **Per-conversation — tokens** table — one row per record: uuid, provenance,
  skill, issue, model(s), the four token buckets + total, tool calls, and
  elapsed seconds.
- **Per-conversation — performance** table — skill turns, sidechain turns, tool
  calls, tool errors, elapsed, and first/last activity per record.
- **Tokens by skill** and **Tokens by provenance** — the collector's
  `by_skill` / `by_provenance` roll-ups (analyzed records only).
- **Pie charts** (GitHub-native ```mermaid``` `pie` blocks) of total-token share
  **by conversation** and **by skill**, rendered from those same totals. A pie is
  emitted only when it has **≥ 2** non-zero slices (a single slice is always
  100%); labels sanitize `;` → `,` since a semicolon breaks a mermaid line.
- **Feature totals** — the summed token buckets and the grand total, plus the
  models across the feature.
- **Activity timeframe** — first activity, last activity, and the span
  (with the "elapsed span, not compute time" caveat).

A genuine measured **0** renders as `0`; a record without metrics
(stub/unexpected/no-skill) renders its numeric cells as `—` and says why, so a
real zero is never confused with "not measured". Sections backed by `@2`-only
aggregate fields (by-skill, by-provenance, timeframe) are omitted when given
older `@1` JSON, which still renders.

### Multistep (`@3`)

- **Feature summary** — the same metrics as above but computed **feature-wide**
  (parent + all children): the child-feature count, feature-wide conversation
  count, total token consumption, and the union of models / skills / issue keys.
- **Token share by feature part** — a table (parent-own + each child, with
  per-part conversation count and total tokens) and a **pie** of that share
  (parent + each child), skipping any zero-token part.
- **Parent feature** section — the parent's own conversations rendered **in
  place** with the same per-conversation *tokens* and *performance* tables (as
  `###` sub-sections), plus the by-conversation pie. If the parent has no own
  conversations (e.g. the assigner session wasn't resolved), a short note says so
  instead.
- **One `## Child feature — <KEY>` section per sub-task**, each with that child's
  conversations in place (same two tables + pie). A sub-task with no worktree yet
  renders a "no conversations resolved yet" note rather than empty tables.
- **Feature-wide roll-ups** — **Tokens by skill** (+ pie), **Tokens by
  provenance**, **Feature totals**, and **Activity timeframe**, all across the
  whole feature.

The per-conversation *tokens* / *performance* tables and the by-skill /
by-provenance / totals / timeframe renderers are **shared functions** used by
both paths, so a child's table is identical in form to a single-step feature's —
the single-step output is byte-for-byte the pre-`@3` template.

All pies follow the same rule as single-step: emitted only with **≥ 2** non-zero
slices, `;` → `,` sanitized.

The markdown structure is inline in the script (no external template to drift);
the one shared artifact is the JSON schema doc, which both halves point at.

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | Markdown emitted. |
| `1` | Usage error, or unreadable / invalid / wrong-shape JSON. |

## Script dispatch

```powershell
pwsh  win/feature_report.ps1   [<json-path>]                                   # PowerShell 7+
powershell -ExecutionPolicy Bypass -File win/feature_report.ps1 [<json-path>]  # Windows PowerShell 5.1
```

```bash
bash  posix/feature_report.sh  [<json-path>]   # STUB — prints a notice and exits 3
```

(paths relative to this file's directory, `conversation-debugger/scripts/`)

Windows PowerShell 5.1 (`powershell.exe`) needs `-ExecutionPolicy Bypass` for
an unsigned `.ps1` unless the machine policy already allows it — same
prerequisite as every `win/` script; `pwsh` (7+) was not observed to require
it. The rendered report is identical on both hosts save one cosmetic detail:
timestamps show as a compact `YYYY-MM-DD HH:MM:SSZ` under 5.1 (whose
`ConvertFrom-Json` parses ISO-Z strings to `DateTime`) and as the raw
ISO-8601 string under 7 (which keeps them as text) — the `Ts` helper renders
either, and no measured number changes.

## Platform parity

The full implementation is `win/feature_report.ps1`.
`posix/feature_report.sh` is a **stub**: it prints a "NOT IMPLEMENTED on POSIX"
notice and exits `3`. A full bash port (bash + `jq`, reading the same collector
JSON) is future work; until then the usual diff-the-two-ports parity check in
AGENTS.md does not apply to this pair — by design.
