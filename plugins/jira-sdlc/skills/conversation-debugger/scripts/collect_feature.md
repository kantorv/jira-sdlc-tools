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

**This round it ships Windows-only** (`win/collect_feature.ps1`). The POSIX
twin (`posix/collect_feature.sh`) is a deliberate **stub** that announces
itself and exits non-zero — an explicit parity gap, not a silent one (see
[Platform parity](#platform-parity) below). This departs, on purpose, from the
repo's usual "every script ships as a working posix+win contract pair" rule.

## Arguments

| Argument | Required | Description |
| --- | --- | --- |
| `<ISSUE-KEY>` | yes | The feature's Jira issue key, e.g. `JST-122`. Positional; matched against `[A-Za-z]+-[0-9]+`. Anything malformed prints usage to stderr and exits 1. |

No flags. Like the other scripts it reads `PROJECT_KEY` and the two
`CONVERSATIONS_*` transcript-folder variables from
`jira-sdlc-tools(.local).env` (via `git rev-parse --show-toplevel`), so run it
from inside the project checkout.

## What it does

1. **Resolve the feature's conversations by reusing `sync_conversations`.** It
   runs `sync_conversations.ps1 <KEY>` (read-only, no `--attach`) and reads its
   machine-readable `=== attachment paths ===` block for the transcript list —
   the same "all worktree sessions + the single creating assigner session" set
   `sync_conversations` already computes. Nothing about transcript-path
   derivation is re-implemented here; if `sync_conversations` exits non-zero
   (bad config, no worktree folder), `collect_feature` relays that and stops.
   Provenance (`worktree` vs `main-checkout`) is classified from the same two
   `CONVERSATIONS_*` config folders, not by scraping the human listing.

2. **Profile each conversation with `collect_run`.** For each resolved
   transcript it detects which of the three analyzable skills the session
   invoked (the same namespaced-or-bare `<command-name>` match `collect_run`
   accepts) and runs `collect_run.ps1 <skill> <path>` once per invoked skill.
   It parses `collect_run`'s `KEY=VALUE` output into one per-conversation
   record — **every metric is `collect_run`'s own**, copied verbatim; nothing
   is re-measured or re-estimated here.

3. **Aggregate.** Token buckets (in / out / cache-read / cache-write, plus a
   summed total) are summed across the records that carried metrics; models,
   skills, and recovered issue keys are unioned. The aggregate `total` is the
   feature's whole-feature token consumption at a glance.

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

Two equivalent ways to get the markdown (both dispatch each script as its own
`pwsh` process; the human view still prints to the console via stderr):

```powershell
# 1. One-shot pipe: collector JSON straight into the report-builder
pwsh win/collect_feature.ps1 JST-93 | pwsh win/feature_report.ps1 > JST-93-report.md

# 2. Two steps: save the JSON first (keep/inspect it), then render markdown from it
pwsh win/collect_feature.ps1 JST-93 > JST-93.json          # JSON only; human view still on stderr
pwsh win/feature_report.ps1 JST-93.json > JST-93-report.md
```

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

Callers decide POSIX vs. Windows from their own runtime before invoking — the
POSIX path is a stub this round:

```powershell
pwsh  win/collect_feature.ps1   <ISSUE-KEY>
```

```bash
bash  posix/collect_feature.sh  <ISSUE-KEY>   # STUB — prints a notice and exits 3
```

(paths relative to this file's directory, `conversation-debugger/scripts/`)

Windows PowerShell 5.1 (`powershell.exe`) needs `-ExecutionPolicy Bypass` for
an unsigned `.ps1` unless the machine policy is already
`RemoteSigned`/`Unrestricted` — the same prerequisite every script under
`win/` has (see [`collect_run.md`](collect_run.md#execution-nuances)); `pwsh`
(7+) was not observed to require it.

## Platform parity

The full implementation is `win/collect_feature.ps1`.
`posix/collect_feature.sh` is a **stub**: it prints a "NOT IMPLEMENTED on
POSIX" notice naming the win/ port and exits `3` (never `0` — nothing is
produced). This makes the parity gap explicit at the point of use. A full bash
port (bash + `jq` + `python3`, mirroring `collect_run.sh` /
`sync_conversations.sh`) is future work; until then the usual
diff-the-two-ports parity check in AGENTS.md does not apply to this pair —
by design.
