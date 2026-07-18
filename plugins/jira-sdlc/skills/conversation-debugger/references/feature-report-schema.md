# Feature-report JSON schema

This is the contract between the two halves of the feature roll-up:
`collect_feature` **emits** this JSON, `feature_report` **reads** it. The
collector is the single owner of the schema — the report-builder never
re-measures anything, it only renders what is here. If a field needs to
change, change it in `collect_feature` first; the report-builder follows.

The `schema` field carries a version tag
(`jira-sdlc/conversation-debugger/feature-report@2`) so a future breaking
change is detectable rather than silent. `@2` **added** aggregate fields
(`skill_turns`, `sidechain_turns`, `tool_calls`, `tool_errors`, `timeframe`,
`by_skill`, `by_provenance`) — a superset of `@1`, so a report-builder that
guards for their absence renders `@1` JSON unchanged.

## Shape

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
      "last_ts":  "2026-07-18T10:59:12.207Z"
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
