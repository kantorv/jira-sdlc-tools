# Feature-report JSON schema

This is the contract between the two halves of the feature roll-up:
`collect_feature` **emits** this JSON, `feature_report` **reads** it. The
collector is the single owner of the schema — the report-builder never
re-measures anything, it only renders what is here. If a field needs to
change, change it in `collect_feature` first; the report-builder follows.

The `schema` field carries a version tag
(`jira-sdlc/conversation-debugger/feature-report@1`) so a future breaking
change is detectable rather than silent.

## Shape

```jsonc
{
  "schema": "jira-sdlc/conversation-debugger/feature-report@1",
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
    "models": ["claude-opus-4-8"],  // union of executing models across the feature
    "skills": ["jira-task-executor","jira-task-assigner"],  // union of skills exercised
    "issue_keys": ["JST-122"]       // union of recovered keys (a multistep feature lists sub-task keys too)
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
  measured `KEY=VALUE` fields verbatim and only *sums* them for the aggregate —
  it never re-derives a token count or a duration. `total` is the one computed
  value (a plain sum of the four buckets). The same caveats as `collect_run`
  apply: `wall_clock_s` is elapsed span (includes waits on a human), not
  compute time; cache-read dominates a long run; there is no cost field, so
  tokens are never converted to money.
