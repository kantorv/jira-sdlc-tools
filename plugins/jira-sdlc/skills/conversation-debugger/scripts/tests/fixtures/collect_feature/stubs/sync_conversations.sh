#!/usr/bin/env bash
# Harness stub — replays a captured sync_conversations listing for one key.
# The harness stages the per-key files under $CF_FIXTURE_WORK/sync/; a key with
# no staged file exits 1, which is how a scenario exercises the collector's
# soft/fatal handling of a failed sync.
set -u
f="$CF_FIXTURE_WORK/sync/$1.txt"
if [ ! -f "$f" ]; then
  echo "sync_conversations stub: no fixture for $1" >&2
  exit 1
fi
cat "$f"
