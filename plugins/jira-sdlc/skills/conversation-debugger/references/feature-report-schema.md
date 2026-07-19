# Feature-report JSON schema

This is the contract between the two halves of the feature roll-up:
`collect_feature` **emits** this JSON, `feature_report` **reads** it. The
collector is the single owner of the schema — the report-builder never
re-measures anything, it only renders what is here. If a field needs to
change, change it in `collect_feature` first; the report-builder follows.

## Two feature types, two shapes

`collect_feature` detects the feature **type** from Jira (one `acli jira
workitem view <KEY> --json --fields 'summary,subtasks'` — `subtasks` must be
named explicitly, the default `--json` omits it) and emits one of two shapes:

- **single-step** — the issue has **no** sub-tasks: one cohesive feature with
  its conversations. Emits the **flat `@2`** shape below (unchanged).
- **multistep** — the issue **is a parent** with sub-tasks: a parent story
  whose child features (sub-tasks) each have their own conversations. Emits the
  **nested `@3`** shape ([below](#multistep-3-shape-nested)) — the parent's own
  conversations, a `children[]` array (each child carrying its own
  `conversations[]` + a per-child roll-up of the *same shape as `aggregate`*),
  and a feature-wide `aggregate` rolled up across the parent **and** all
  children.

The `schema` field carries a version tag
(`jira-sdlc/conversation-debugger/feature-report@2` or `@3`) so the shape is
detectable rather than guessed. The layering is backward-compatible and
**version-detectable**, following the `@1 → @2` convention:

- `@2` **added** aggregate fields (`skill_turns`, `sidechain_turns`,
  `tool_calls`, `tool_errors`, `timeframe`, `by_skill`, `by_provenance`) — a
  superset of `@1`, so a report-builder that guards for their absence renders
  `@1` JSON unchanged.
- `@3` is a **new nested container** for multistep features; it does **not**
  change `@2`. A single-step feature still emits `@2` byte-for-byte, so there
  is no regression on existing single-step reports. The report-builder detects
  a multistep report by the presence of `children` (equivalently, a `@3` schema
  tag) and otherwise takes the untouched single-step path. Every `aggregate`
  inside `@3` — the parent's, each child's, and the feature-wide one — reuses
  the `@2` aggregate shape verbatim.

## Single-step (`@2`) shape

```jsonc
{
  "schema": "jira-sdlc/conversation-debugger/feature-report@2",
  "feature": "JST-122",            // the feature key this roll-up is for (the collector's argument)
  "conversation_count": 2,          // number of per-conversation records below
  "conversations": [                // one record per (conversation, invoked skill)
    {
      "uuid": "d7bc6cdf-…",         // transcript filename without .jsonl
      "transcript": "C:\\…\\d7bc6cdf-….jsonl",   // absolute path collect_run profiled
      "provenance": "worktree",     // "worktree" | "main-checkout" | "unknown"
      "skill": "jira-task-executor",// which of the 3 skills this record scopes to (null if none)
      "issue_key": "JST-122",       // the key collect_run recovered for this run (may differ from feature, e.g. a sub-task)
      "key_status": "expected",     // collect_run's KEY_STATUS: expected | given | stub | unexpected | no-skill
      "models": ["claude-opus-4-8"],// executing model(s) for this conversation
      "tokens": {
        "in": 64,                   // TOKENS_IN
        "out": 49637,               // TOKENS_OUT
        "cache_read": 3535466,      // TOKENS_CACHE_READ
        "cache_write": 123678,      // TOKENS_CACHE_WRITE
        "total": 3708845            // in + out + cache_read + cache_write
      },
      "skill_turns": 26,            // SKILL_TURNS (distinct API responses; null when no metrics)
      "sidechain_turns": 0,         // SIDECHAIN_TURNS
      "tool_calls": 36,             // TOOL_CALLS
      "tool_errors": 2,             // TOOL_ERRORS
      "wall_clock_s": 1754.7,       // WALL_CLOCK_S (elapsed span, not compute time)
      "first_ts": "2026-07-18T10:35:59.356Z",
      "last_ts":  "2026-07-18T10:59:12.207Z",
      "size_bytes": 3874112         // TRANSCRIPT_BYTES — transcript size in bytes; null when absent (metric-less record, or older collect_run)
    }
    // …one per (conversation, skill)
  ],
  "aggregate": {
    "conversation_count": 2,        // == top-level conversation_count
    "analyzed_count": 2,            // records that carried metrics (key_status expected/given)
    "tokens": {                     // SUMMED over analyzed records only
      "in": 92, "out": 67030, "cache_read": 4602634, "cache_write": 195871,
      "total": 4865627              // the feature's TOTAL token consumption, at a glance
    },
    "skill_turns": 102,             // SUMMED skill turns over analyzed records
    "sidechain_turns": 0,           // SUMMED sidechain turns
    "tool_calls": 109,              // SUMMED tool calls
    "tool_errors": 6,               // SUMMED tool errors
    "timeframe": {                  // wall-clock window across analyzed records
      "first_ts": "2026-07-18T10:02:11.000Z",  // earliest first_ts
      "last_ts":  "2026-07-18T14:01:25.783Z",  // latest last_ts
      "span_s": 14354.2             // (last - first) in seconds — includes idle gaps; null if no timestamps
    },
    "models": ["claude-opus-4-8"],  // union of executing models across the feature
    "skills": ["jira-task-executor","jira-task-assigner"],  // union of skills exercised
    "issue_keys": ["JST-122"],      // union of recovered keys (a multistep feature lists sub-task keys too)
    "by_skill": [                   // per-skill token roll-up (analyzed records only)
      { "skill": "jira-task-executor", "conversations": 1,
        "tokens": { "in": 114, "out": 77772, "cache_read": 7707927, "cache_write": 158910, "total": 7944723 } }
      // …one per distinct skill
    ],
    "by_provenance": [              // per-provenance token roll-up (analyzed records only)
      { "provenance": "worktree", "conversations": 2,
        "tokens": { "in": 168, "out": 104077, "cache_read": 10128429, "cache_write": 249614, "total": 10482288 } }
      // …one per distinct provenance ("worktree" | "main-checkout" | "unknown")
    ]
  }
}
```

## Multistep (`@3`) shape (nested)

Emitted only when `<KEY>` is a parent with sub-tasks. The `conversations` /
`aggregate` **record shapes are identical to `@2`** — `@3` only adds a nesting
layer around them: a `parent` object, a `children[]` array, and a top-level
feature-wide `aggregate`.

```jsonc
{
  "schema": "jira-sdlc/conversation-debugger/feature-report@3",
  "feature": "JST-122",             // the parent key this roll-up is for
  "feature_type": "multistep",      // explicit marker ("multistep"); absent on @2 single-step
  "parent": {                       // the PARENT's own conversations + roll-up
    "key": "JST-122",
    "summary": "conversation-debugger: feature-level token/cost + model report",
    "conversation_count": 4,
    "conversations": [ /* @2 records — same shape */ ],
    "aggregate": { /* @2 aggregate — same shape, over the parent's own records */ }
  },
  "children": [                     // one entry per sub-task
    {
      "key": "JST-125",
      "summary": "conversation-debugger: multistep feature report — nested child roll-up",
      "conversation_count": 1,
      "conversations": [ /* @2 records — same shape */ ],
      "aggregate": { /* @2 aggregate — same shape, over THIS child's records */ }
      // …a child with no worktree yet has conversation_count 0, conversations [],
      //   and an all-zero aggregate — it still appears, so coverage stays honest.
    }
    // …one per sub-task
  ],
  "conversation_count": 5,          // feature-wide: parent's own + every child's
  "aggregate": { /* @2 aggregate — same shape, over parent + ALL children */ }
}
```

### `@3` field notes

- **Every `aggregate` is a `@2` aggregate.** `parent.aggregate`,
  `children[].aggregate`, and the top-level feature-wide `aggregate` all use the
  identical shape documented above. The report-builder and any consumer reuse
  one code path for all of them.

- **The feature-wide `aggregate` spans parent + all children.** It is the roll-up
  over the union of the parent's own records and every child's records — the
  feature's total token consumption, the union of models/skills/keys, and the
  by-skill / by-provenance / timeframe roll-ups across the whole feature.
  `aggregate.issue_keys` therefore lists the parent key **and** the sub-task
  keys.

- **The creating assigner session belongs to the parent — counted once.** A
  multistep assigner session (in the main checkout) mentions the parent key
  **and** every sub-task key, so the per-key resolution finds it for the parent
  *and* each child. `collect_feature` de-duplicates by transcript path with
  **parent-priority**: the session is attributed to `parent`, dropped from every
  child, and its tokens counted exactly once feature-wide. (Worktree sessions are
  folder-scoped per key and never overlap; only the assigner session does.)

- **A child may be empty.** A sub-task with no worktree yet (or no sessions in
  it) contributes `conversation_count: 0`, `conversations: []`, and an all-zero
  `aggregate`. It is still listed so the report shows the sub-task exists and is
  not yet started.

- **Detection is Jira-driven, with a safe fallback.** The single/multistep split
  comes from the `subtasks` lookup, wrapped in a long timeout (the API can take
  minutes). If the `acli` fetch fails or times out, `collect_feature` falls back
  to **single-step (`@2`)** with a loud stderr WARN rather than aborting the
  read-only roll-up.

## Field notes that matter

- **One record per `(conversation, skill)`, not per conversation.** A single
  session that invoked two skills (e.g. an executor run that later re-ran as a
  reviewer) yields two records with the same `uuid` and different `skill` —
  because `collect_run` scopes its metrics to one skill's own turns
  (`attributionSkill`). This is why `skill` is a per-record field.

- **`issue_key` can differ from `feature`.** For a multistep feature, a
  worktree executor session on a sub-task recovers the *sub-task* key, not the
  top-level feature key. Both are legitimate; `aggregate.issue_keys` is the
  union.

- **Metrics may be absent.** A record with `key_status` of `stub`,
  `unexpected`, or `no-skill` carries no measured metrics — its numeric fields
  are `0`/`null` and it is **excluded from `aggregate` token sums** (but still
  listed, so coverage stays honest). `analyzed_count` is how many records
  actually contributed.

- **Every number is `collect_run`'s own.** `collect_feature` copies the
  measured `KEY=VALUE` fields verbatim and only *sums* / *unions* / *min-maxes*
  them for the aggregate — it never re-derives a token count or a duration.
  `tokens.total`, the `by_skill`/`by_provenance` sums, and the turn/tool sums
  are plain additions of measured values; `timeframe.span_s` is the one
  subtraction (`last_ts − first_ts`). All are computed **in the collector** so
  the report-builder stays a pure renderer. The same caveats as `collect_run`
  apply: `wall_clock_s` (and therefore `span_s`) is elapsed span — it includes
  waits on a human and idle gaps between sessions, not compute time, and does
  **not** equal the sum of per-conversation elapsed; cache-read dominates a long
  run; there is no cost field, so tokens are never converted to money.

- **`by_skill` / `by_provenance` cover analyzed records only.** Their token
  sums match `aggregate.tokens` (metric-less records contribute nothing), so a
  non-analyzed conversation appears in the per-conversation listing for coverage
  but not in these roll-ups.

- **`size_bytes` is the transcript's on-disk size, measured upstream.** It is
  `collect_run`'s `TRANSCRIPT_BYTES` (a `wc -c` / `.Length` stat of the profiled
  `.jsonl`), threaded verbatim through `collect_feature` — the same owner split as
  every other number: the collector measures, the report-builder only renders it
  human-readably (KB/MB). It cannot be a `feature_report`-only field: each record's
  `transcript` is the collector's *machine* path and the JSON is portable, so the
  report-builder cannot reliably stat it. `null` when absent — a metric-less
  record (`stub`/`unexpected`/`no-skill`), or JSON from a `collect_run` predating
  this field — and the report renders `-` there, so it is backward compatible.
