#!/usr/bin/env bash
# run_collect_feature_golden.sh [sh|py|ps1|all] [--update]
#
# Golden-file parity harness for collect_feature (see ../collect_feature.md
# → "Golden-file harness"). Each fixture scenario replays canned
# sync_conversations / collect_run / acli output through stub siblings, so the
# collector's real orchestration, dedup, and aggregation run end to end with
# every number deterministic. The resulting stdout JSON is normalized and
# diffed byte-for-byte against the committed golden.
#
# Engines (default: all):
#   sh  — posix/collect_feature.sh, the thin shim (proves the shim dispatch)
#   py  — python3 py/collect_feature.py, the dual-use core, invoked directly
#   ps1 — win/collect_feature.ps1 under pwsh (skipped with a note if pwsh is
#         not installed; pwsh 7 on Linux is enough — see AGENTS.md)
#
# Normalization (exactly what ../collect_feature.md documents for live parity
# checks, plus a staging-path substitution the fixtures need):
#   * jq -S                  — canonical key order
#   * wall_clock_s → null    — the one documented per-host difference
#   * every number + 0       — canonical numeric formatting (jq ≥1.7 preserves
#                              literals, so 480 vs 480.0 would false-fail)
#   * $WORK → @WORK@         — the per-run staging dir, so goldens are
#                              location-independent
#
# Scenarios (fixtures/collect_feature/<name>/):
#   single-step        — flat feature-report@2, populated (incl. a two-skill
#                        session, a no-skill transcript, an unexpected-key
#                        record excluded from sums, all three provenances)
#   single-step-empty  — feature-report@2 with zero conversations
#   multistep          — nested feature-report@3, parent + 2 children; the
#                        assigner session resolves for parent AND both
#                        children, and the harness asserts it is counted
#                        exactly once feature-wide (parent-priority dedup)
#   multistep-empty    — feature-report@3 with zero conversations; the child's
#                        sync fixture is deliberately missing, exercising the
#                        soft zero-conversations path
#
# --update rewrites the goldens from the py engine. Use it only when an output
# change is intended — the golden diff in the commit then documents the change.
#
# Exit: 0 = every selected engine matched every golden; 1 = any mismatch or
# harness error.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
FIX="$HERE/fixtures/collect_feature"

ENGINES="sh py ps1"
UPDATE=0
for arg in "$@"; do
  case "$arg" in
    sh|py|ps1) ENGINES="$arg" ;;
    all)       ENGINES="sh py ps1" ;;
    --update)  UPDATE=1; ENGINES="py" ;;
    *) echo "usage: run_collect_feature_golden.sh [sh|py|ps1|all] [--update]" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "harness: jq is required" >&2; exit 1; }

# wall_clock_s nulled (documented per-host difference), numbers canonicalized
# (jq ≥1.7 preserves source literals: 480 vs 480.0 would otherwise false-fail).
NORM='walk(if type=="object" and has("wall_clock_s") then .wall_clock_s = null else . end
           | if type=="number" then . + 0 else . end)'

SCENARIOS="single-step:FTX-1 single-step-empty:FTX-2 multistep:FTX-10 multistep-empty:FTX-20"
ASSIGNER_UUID="eeeeeeee-0010-4000-8000-000000000010"   # multistep dedup assertion

fails=0
skipped_ps1=0

stage() {  # stage <scenario> -> prints the staging dir
  local scenario="$1" work
  work=$(mktemp -d) || exit 1
  mkdir -p "$work/proj" "$work/engine" "$work/sync"
  # controlled provenance config, read from cwd ($work/proj is not a git repo;
  # GIT_CEILING_DIRECTORIES keeps discovery from climbing to any real one)
  {
    echo "CONVERSATIONS_WORKTREES_PREFIX=$work/wt"
    echo "CONVERSATIONS_MAINREPO_PATH=$work/main"
  } > "$work/proj/jira-sdlc-tools.local.env"
  # transcripts (skill-marker content the collector greps) at their staged paths
  if [ -d "$FIX/$scenario/transcripts" ]; then
    cp -R "$FIX/$scenario/transcripts/." "$work/"
  fi
  # sync listings with @WORK@ resolved to this run's staging dir
  local f
  for f in "$FIX/$scenario/sync/"*.txt; do
    [ -e "$f" ] || continue
    sed "s|@WORK@|$work|g" "$f" > "$work/sync/$(basename "$f")"
  done
  [ -d "$FIX/$scenario/collect_run" ] && cp -R "$FIX/$scenario/collect_run" "$work/"
  cp "$FIX/$scenario/acli.json" "$work/"
  # stub siblings + stub acli become the engine dir
  cp "$FIX/stubs/"* "$work/engine/"
  chmod +x "$work/engine/"*.sh "$work/engine/acli"
  echo "$work"
}

run_engine() {  # run_engine <engine> <work> <key> -> collector exit code; JSON in $work/out.json
  local engine="$1" work="$2" key="$3" rc
  (
    cd "$work/proj" || exit 1
    export CF_FIXTURE_WORK="$work"
    export CF_SCRIPT_DIR="$work/engine"
    export GIT_CEILING_DIRECTORIES="$work"
    export PATH="$work/engine:$PATH"
    case "$engine" in
      sh)  bash "$SCRIPTS/posix/collect_feature.sh" "$key" ;;
      py)  python3 "$SCRIPTS/py/collect_feature.py" "$key" ;;
      ps1) cp "$SCRIPTS/win/collect_feature.ps1" "$work/engine/"
           pwsh -NoProfile -File "$work/engine/collect_feature.ps1" "$key" ;;
    esac
  ) > "$work/out.json" 2> "$work/err.txt"
  rc=$?
  return $rc
}

for engine in $ENGINES; do
  if [ "$engine" = ps1 ] && ! command -v pwsh >/dev/null 2>&1; then
    echo "SKIP  ps1 (pwsh not installed — see AGENTS.md for the pwsh-on-Linux parity setup)"
    skipped_ps1=1
    continue
  fi
  for pair in $SCENARIOS; do
    scenario="${pair%%:*}"; key="${pair##*:}"
    golden="$FIX/$scenario/golden.json"
    work=$(stage "$scenario")

    if ! run_engine "$engine" "$work" "$key"; then
      echo "FAIL  $engine/$scenario — collector exited non-zero; stderr:" >&2
      sed 's/^/        /' "$work/err.txt" >&2
      fails=$((fails + 1)); rm -rf "$work"; continue
    fi

    jq -S "$NORM" "$work/out.json" | sed "s|$work|@WORK@|g" > "$work/norm.json" || {
      echo "FAIL  $engine/$scenario — output is not valid JSON" >&2
      fails=$((fails + 1)); rm -rf "$work"; continue
    }

    if [ "$UPDATE" -eq 1 ]; then
      cp "$work/norm.json" "$golden"
      echo "WROTE $scenario/golden.json (from $engine)"
    elif [ ! -f "$golden" ]; then
      echo "FAIL  $engine/$scenario — no golden.json (run with --update to create)" >&2
      fails=$((fails + 1))
    elif ! diff -u "$golden" "$work/norm.json" > "$work/diff.txt"; then
      echo "FAIL  $engine/$scenario — output differs from golden:" >&2
      sed 's/^/        /' "$work/diff.txt" >&2
      fails=$((fails + 1))
    else
      echo "PASS  $engine/$scenario"
    fi

    # multistep dedup: the assigner session resolves for the parent and both
    # children but must be recorded exactly once feature-wide (parent-priority)
    if [ "$scenario" = multistep ] && [ "$UPDATE" -eq 0 ]; then
      n=$(jq "[.. | objects | select(.uuid? == \"$ASSIGNER_UUID\")] | length" "$work/norm.json")
      if [ "$n" = 1 ]; then
        echo "PASS  $engine/$scenario dedup (assigner session counted once)"
      else
        echo "FAIL  $engine/$scenario dedup — assigner session appears $n times, expected 1" >&2
        fails=$((fails + 1))
      fi
    fi
    rm -rf "$work"
  done
done

if [ "$fails" -gt 0 ]; then
  echo "run_collect_feature_golden: $fails failure(s)" >&2
  exit 1
fi
[ "$skipped_ps1" -eq 1 ] && echo "note: ps1 engine skipped — parity for the .ps1 port was NOT verified on this run"
echo "run_collect_feature_golden: all green"
