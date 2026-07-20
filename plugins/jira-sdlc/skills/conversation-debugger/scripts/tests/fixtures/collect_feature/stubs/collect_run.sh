#!/usr/bin/env bash
# Harness stub — replays captured collect_run KEY=VALUE output for one
# (skill, transcript) pair from $CF_FIXTURE_WORK/collect_run/<uuid>.<skill>.kv.
# A missing pair exits 1 (collect_feature's hard-fail-skip path) — every pair a
# scenario's transcripts can produce should have a .kv file.
set -u
b=$(basename "$2"); b="${b%.jsonl}"
f="$CF_FIXTURE_WORK/collect_run/$b.$1.kv"
if [ ! -f "$f" ]; then
  echo "collect_run stub: no fixture for $1 $b" >&2
  exit 1
fi
cat "$f"
