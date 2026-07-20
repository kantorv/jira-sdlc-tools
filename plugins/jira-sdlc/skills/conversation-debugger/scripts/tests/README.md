# `conversation-debugger` script tests

Golden-file parity harnesses for the scripts in this folder's parent. Each
harness replays captured fixtures through stub siblings and byte-diffs the
result against a committed golden, so a refactor either reproduces the previous
output exactly or fails loudly.

| Harness | Covers |
| --- | --- |
| [`run_collect_feature_golden.sh`](run_collect_feature_golden.sh) | `collect_feature` — the `py/` core, the `posix/` shim, and the `win/` port |

## Why these scripts get tests when the rest of the repo doesn't

Nearly everything in this repo is a prompt an LLM re-reads at run time, and a
prompt is validated by reading it. The `conversation-debugger` scripts are the
exception: they're real programs, and AGENTS.md's own warning applies to them —
*"a script bug is wrong 100% of the time and rots silently in a repo with no
tests."*

Two specific risks make that concrete here:

- **Three implementations, one contract.** `collect_feature` exists as a Python
  core, a bash shim over it, and a hand-maintained PowerShell port that shares
  no code with either. Nothing but a harness can prove the three still agree —
  and the `.ps1` is the one most likely to drift, since most contributors never
  run Windows.
- **A refactor's "nothing changed" is otherwise unfalsifiable.** These scripts
  emit a large nested JSON document. Eyeballing a diff of the *code* cannot
  establish that the *output* is unchanged. Capturing goldens from the
  pre-refactor script and re-running them after is what turns that claim into
  something checked.

## Running

```bash
cd plugins/jira-sdlc/skills/conversation-debugger/scripts

bash tests/run_collect_feature_golden.sh          # all engines
bash tests/run_collect_feature_golden.sh py       # one engine: sh | py | ps1
bash tests/run_collect_feature_golden.sh --update # re-capture goldens (see below)
```

Needs `jq` and `python3`. The `ps1` engine needs `pwsh` — version 7 on Linux is
enough, no Windows box required — and **skips with a loud note when it's
missing**. A green run that skipped `ps1` has *not* verified the Windows port;
read the output, don't just check the exit code.

Exit is `0` only if every selected engine matched every golden.

## What a run actually does

For each scenario, the harness builds a throwaway staging directory and runs the
*real* collector inside it, with only its outermost dependencies faked:

1. **Stage.** A `mktemp -d` gets a `proj/` (holding a synthetic
   `jira-sdlc-tools.local.env` whose `CONVERSATIONS_*` paths point back into the
   staging dir), the scenario's transcripts at those paths, its canned
   `sync_conversations` listings with `@WORK@` resolved to this run's real path,
   its `collect_run` output, and its `acli` response.
2. **Substitute the siblings.** Stub `sync_conversations` / `collect_run` and a
   stub `acli` are placed in an `engine/` dir, which becomes `CF_SCRIPT_DIR` and
   goes first on `PATH`.
3. **Run the collector** from `proj/`, with `GIT_CEILING_DIRECTORIES` set so its
   `git rev-parse` config lookup can't escape into the real repository.
4. **Normalize and diff** stdout against the committed golden.

Everything the collector *owns* — orchestration, skill detection, the
parent-priority dedup, the whole aggregate roll-up, both emit paths — runs for
real. Only the three external programs it shells out to are canned, which is
what makes every number in the output deterministic.

### Normalization

```
jq -S  +  wall_clock_s → null  +  every number + 0  +  $STAGING_DIR → @WORK@
```

The first two are exactly the live cross-host parity recipe documented in
[`../collect_feature.md`](../collect_feature.md#platform-parity): `wall_clock_s`
is the one field that legitimately differs per host, because `collect_run.sh`
measures whole seconds while `collect_run.ps1` keeps the fraction.

The other two are harness-specific. **`+ 0` is not cosmetic** — jq 1.7+
preserves source number literals, so Python's `480.0` and PowerShell's `480`
survive as written and false-fail a diff of two outputs that are numerically
identical. The arithmetic forces canonical formatting. The `@WORK@` substitution
is what lets goldens be committed at all, since the staging path changes every
run.

## Layout

```
tests/
├── run_collect_feature_golden.sh
└── fixtures/collect_feature/
    ├── stubs/                    shared by every scenario
    │   ├── acli                  replays <scenario>/acli.json
    │   ├── sync_conversations.sh/.ps1   replays <scenario>/sync/<KEY>.txt
    │   └── collect_run.sh/.ps1          replays <scenario>/collect_run/<uuid>.<skill>.kv
    └── <scenario>/
        ├── acli.json             the sub-task lookup response (drives @2 vs @3)
        ├── sync/<KEY>.txt        one per key; @WORK@ = staging dir placeholder
        ├── collect_run/          one .kv per (transcript, skill) pair
        ├── transcripts/          .jsonl files; only their skill markers matter
        └── golden.json           committed expected output
```

The `.sh` and `.ps1` stubs are twins on purpose: the PowerShell port shells out
to `.ps1` siblings, so it needs its own stubs reading the same fixture files.

### Scenarios

| Scenario | Key | What it pins |
| --- | --- | --- |
| `single-step` | `FTX-1` | Flat `feature-report@2`, populated. Also carries the awkward cases: a session invoking two skills (two records, one uuid), a transcript with no analyzable skill, an `unexpected`-key record that must stay listed but out of every sum, all three provenance classes, and a tool named `mcp__jira:view` to pin the split-on-*last*-colon tally parsing. |
| `single-step-empty` | `FTX-2` | `@2` with zero conversations. |
| `multistep` | `FTX-10` | Nested `feature-report@3`: parent + two children. The assigner session resolves for the parent *and* both children, and the harness separately asserts it appears exactly once — the parent-priority dedup. |
| `multistep-empty` | `FTX-20` | `@3` with zero conversations. |

⚠️ **`multistep-empty` has no `sync/FTX-21.txt`, and that is deliberate.** The
stub exits 1 for a key it has no fixture for, which is precisely how this
scenario exercises the soft-failure path: in multistep mode an unstarted
sub-task must contribute zero conversations with a note, not sink the whole
roll-up. Adding the "missing" file would silently delete that coverage.

## `--update`

Rewrites the goldens from the `py` engine. Use it **only when an output change
is intended** — the point is that the golden diff appears in the same commit as
the code change, documenting the behavioral delta for review. Running it to make
a red build go green destroys the only record that anything moved.

When refactoring with no intended output change, do the opposite: capture the
goldens from the *pre-change* script first, then refactor until they pass
untouched. That's how the `collect_feature` goldens here were produced.

## Adding coverage

**A scenario:** create `fixtures/collect_feature/<name>/` with the files above,
add `<name>:<KEY>` to `SCENARIOS` in the harness, and generate its golden with
`--update`. Write `@WORK@` wherever a sync listing needs an absolute path.

**A harness for another script:** copy `run_collect_feature_golden.sh` and keep
the shape — stub the siblings, stage hermetically, normalize, diff. The parts
worth carrying over verbatim are the `+ 0` number normalization, the
`GIT_CEILING_DIRECTORIES` guard, and the loud skip when an engine's runtime is
absent.
