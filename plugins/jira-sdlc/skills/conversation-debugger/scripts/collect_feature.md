# `collect_feature` — logic and execution nuances

`collect_feature` is the **feature-level** roll-up collector for
conversation-debugger. Where [`collect_run`](collect_run.md) profiles one
transcript, `collect_feature` profiles a whole feature: given a Jira issue
key it resolves every conversation that belongs to that feature, runs
`collect_run` over each, and rolls the measured per-conversation metrics up
into per-feature totals — the feature's total token consumption and the union
of executing models across it. It emits JSON on stdout (consumed by
[`feature_report`](feature_report.md)) and a human-readable metrics view on
stderr.

**It handles two feature types**, auto-detected from Jira:

- **single-step** — `<KEY>` has **no** sub-tasks: one cohesive feature with its
  conversations. Emits the flat **`feature-report@2`** JSON (unchanged behavior).
- **multistep** — `<KEY>` **is a parent** with sub-tasks: a parent story whose
  child features (sub-tasks) each have their own conversations. Emits the nested
  **`feature-report@3`** JSON — the parent's own conversations, a `children[]`
  array (each child with its own conversations + per-child roll-up), and a
  feature-wide aggregate across the parent **and** all children.

Detection is a single Jira fetch (see [Feature-type detection](#feature-type-detection)
below); the schema for both shapes is owned here and documented in
[`../references/feature-report-schema.md`](../references/feature-report-schema.md).

**It ships as a working posix+win contract pair** — the bash port
(`posix/collect_feature.sh`) and the PowerShell port (`win/collect_feature.ps1`)
take the same argument, emit the same JSON/stderr split, and use the same exit
codes (see [Platform parity](#platform-parity) below). Callers pick the branch
from their own runtime: `bash posix/collect_feature.sh` on Linux/macOS,
`pwsh`/`powershell win/collect_feature.ps1` on Windows.

## Arguments

| Argument | Required | Description |
| --- | --- | --- |
| `<ISSUE-KEY>` | yes | The feature's Jira issue key, e.g. `JST-122`. Positional; matched against `[A-Za-z]+-[0-9]+`. Anything malformed prints usage to stderr and exits 1. |

No flags. Like the other scripts it reads `PROJECT_KEY` and the two
`CONVERSATIONS_*` transcript-folder variables from
`jira-sdlc-tools(.local).env` (via `git rev-parse --show-toplevel`), so run it
from inside the project checkout.

## Feature-type detection

Before resolving any conversations, `collect_feature` asks Jira whether `<KEY>`
is a multistep parent:

```
acli jira workitem view <KEY> --json --fields 'summary,subtasks'
```

The key is **positional**, and `subtasks` **must be named explicitly** — the
default `--json` omits it, so a naive fetch would report every parent as
single-step (the same gotcha [`../../docs/examples/acli-list-subtasks.py`](../../docs/examples/acli-list-subtasks.py)
documents). **Non-empty `subtasks` → multistep; empty → single-step.**

The call is wrapped in a **long timeout** (run in a background job; the API can
legitimately take minutes). If `acli` is missing, errors, or times out,
`collect_feature` falls back to **single-step** with a loud stderr WARN rather
than aborting — the roll-up is read-only, so the safe default is the historical
flat report.

## What it does

For a **multistep** parent, steps 1–2 below run once for the parent's own key
and once per sub-task key; the parent's own conversations and each child's are
kept separate, and step 3 produces a per-child roll-up plus a feature-wide one.
A single-step feature runs steps 1–3 once over its own key. In multistep mode a
missing worktree for one part (parent or a child) is a stderr NOTE + zero
conversations for that part, not a fatal error — only a single-step feature's
own `sync_conversations` failure is fatal.

1. **Resolve the feature's conversations by reusing `sync_conversations`.** It
   runs `sync_conversations.ps1 <KEY>` (read-only, no `--attach`) and reads its
   machine-readable `=== attachment paths ===` block for the transcript list —
   the same "all worktree sessions + the single creating assigner session" set
   `sync_conversations` already computes. Nothing about transcript-path
   derivation is re-implemented here; if `sync_conversations` exits non-zero
   (bad config, no worktree folder), `collect_feature` relays that and stops
   **for a single-step feature** — in multistep mode the same non-zero exit for
   one part (parent or a child) is a NOTE + zero conversations for that part, so
   an unstarted sub-task never sinks the whole roll-up.
   Provenance (`worktree` vs `main-checkout`) is classified from the same two
   `CONVERSATIONS_*` config folders, not by scraping the human listing.

2. **Profile each conversation with `collect_run`.** For each resolved
   transcript it detects which of the three analyzable skills the session
   invoked (the same namespaced-or-bare `<command-name>` match `collect_run`
   accepts) and runs `collect_run.ps1 <skill> <path>` once per invoked skill.
   It parses `collect_run`'s `KEY=VALUE` output into one per-conversation
   record — **every metric is `collect_run`'s own**, copied verbatim; nothing
   is re-measured or re-estimated here. That includes the transcript's on-disk
   `size_bytes` (from `collect_run`'s `TRANSCRIPT_BYTES`) — threaded straight
   through, since only `collect_run` holds the transcript path to stat.

3. **Aggregate.** Over the records that carried metrics: token buckets (in /
   out / cache-read / cache-write, plus a summed total) and the turn/tool counts
   (`skill_turns`, `sidechain_turns`, `tool_calls`, `tool_errors`) are summed;
   models, skills, and recovered issue keys are unioned; tokens are also rolled
   up **per skill** (`by_skill`) and **per provenance** (`by_provenance`); and a
   feature `timeframe` is derived — earliest `first_ts`, latest `last_ts`, and
   the `span_s` between them. The aggregate `total` is the feature's
   whole-feature token consumption at a glance. Every value is a plain
   sum / union / min-max of `collect_run`'s own measured numbers (`span_s` the
   one subtraction); the schema is in
   [`../references/feature-report-schema.md`](../references/feature-report-schema.md).
   For a **multistep** parent this aggregate is computed three ways from the
   *same* function: once per child (its per-child roll-up), once over the
   parent's own records, and once feature-wide over the parent **plus every
   child**. The creating assigner session — which mentions the parent and every
   sub-task key, so it resolves for each — is de-duplicated by transcript path
   with **parent-priority** and counted once feature-wide.

## Output — two streams, split on purpose

- **stdout = the feature-report JSON, and nothing else.** This is the
  machine-readable output; its schema is owned here and documented in
  [`../references/feature-report-schema.md`](../references/feature-report-schema.md).
  Keeping stdout pure JSON is what lets it pipe straight into the
  report-builder.
- **stderr = the human view**: `sync_conversations`' grouped listing followed
  by a per-conversation + totals metrics table — so a bare console run shows
  both the listing and the metrics "along" it (as the issue asked) while stdout
  stays pipe-safe.

Two equivalent ways to get the markdown (the human view still prints to the
console via stderr). On POSIX:

```bash
# 1. One-shot pipe: collector JSON straight into the report-builder
bash posix/collect_feature.sh JST-93 | bash posix/feature_report.sh > JST-93-report.md

# 2. Two steps: save the JSON first (keep/inspect it), then render markdown from it
bash posix/collect_feature.sh JST-93 > JST-93.json          # JSON only; human view still on stderr
bash posix/feature_report.sh JST-93.json > JST-93-report.md
```

On Windows, dispatch each script as its own `pwsh` process:

```powershell
pwsh win/collect_feature.ps1 JST-93 | pwsh win/feature_report.ps1 > JST-93-report.md
```

On **Windows PowerShell 5.1** (`powershell.exe`) swap each `pwsh X` for
`powershell -ExecutionPolicy Bypass -File X`.

Both platforms produce the **same report structure and the same measured
metrics**. Two cosmetic caveats: (a) PowerShell 5.1 serializes a whole-number
`span_s` as `3685.0`, 7 as `3685` — same value, and the report-builder reads
either; (b) every per-conversation number is `collect_run`'s own, and the POSIX
`collect_run.sh` measures `WALL_CLOCK_S` at **whole-second** resolution while
`collect_run.ps1` keeps the fractional part — so the `elapsed (s)` column (and
nothing else) can differ by well under a second between the two hosts. That is a
`collect_run` port difference, not a `collect_feature` one; the roll-up copies
whatever its host's `collect_run` reports.

**Records-per-conversation, not one-per-conversation.** A session that invoked
two skills produces two records (same `uuid`, different `skill`) because
`collect_run` scopes metrics to one skill's turns. See the schema doc's field
notes.

**Side effect: `collect_run` files each transcript under
`conversations/<KEY>/` as it profiles it** — that is `collect_run`'s normal
behavior, and `conversations/` is git-ignored, so it stays local. Nothing is
uploaded or posted to Jira; the roll-up is read-and-report only.

## Exit codes

| Exit | Meaning |
| --- | --- |
| `0` | JSON emitted (including for a feature that resolved zero conversations — an empty but valid roll-up). |
| `1` | Usage error, environment error, or `sync_conversations` failed. |

Individual `collect_run` hiccups don't abort the whole roll-up: a `collect_run`
hard error (exit 1) on one transcript is noted on stderr and that
`(conversation, skill)` is skipped; a `stub`/`unexpected` result is recorded
without metrics and excluded from the token sums (but still listed, so coverage
stays honest).

## Script dispatch

Callers decide POSIX vs. Windows from their own runtime before invoking:

```bash
bash  posix/collect_feature.sh  <ISSUE-KEY>   # Linux / macOS
```

```powershell
pwsh  win/collect_feature.ps1   <ISSUE-KEY>                                    # PowerShell 7+
powershell -ExecutionPolicy Bypass -File win/collect_feature.ps1 <ISSUE-KEY>   # Windows PowerShell 5.1
```

(paths relative to this file's directory, `conversation-debugger/scripts/`)

Windows PowerShell 5.1 (`powershell.exe`) needs `-ExecutionPolicy Bypass` for
an unsigned `.ps1` unless the machine policy is already
`RemoteSigned`/`Unrestricted` — the same prerequisite every script under
`win/` has (see [`collect_run.md`](collect_run.md#execution-nuances)); `pwsh`
(7+) was not observed to require it.

## Platform parity

`collect_feature` ships as a working **posix+win contract pair**:
`posix/collect_feature.sh` (bash + `jq` via `collect_run` + `python3` for the
nested roll-up, mirroring `collect_run.sh` / `sync_conversations.sh`) and
`win/collect_feature.ps1` take the same argument and emit the same JSON/stderr
split with the same exit codes. Because the JSON's numbers are each host's
`collect_run` output verbatim, a raw byte-diff of the two collectors' JSON is
**not** the parity check: the `wall_clock_s` field (and nothing else) traces to
the `collect_run.sh` vs `collect_run.ps1` precision difference noted above.
Verify parity on quiescent data by comparing the two collectors' JSON with
`wall_clock_s` normalized out, e.g.:

```bash
NORM='walk(if type=="object" and has("wall_clock_s") then .wall_clock_s=null else . end)'
diff <(jq -S "$NORM" <(bash posix/collect_feature.sh JST-93 2>/dev/null)) \
     <(jq -S "$NORM" <(pwsh win/collect_feature.ps1 JST-93 2>/dev/null))
```

(Resolve every conversation of a **live** feature and the numbers move as its
sessions run — compare a feature whose sessions have finished, or capture both
within the same quiet window.) The rendered markdown is byte-for-byte identical
across hosts save that same `elapsed (s)` column.
