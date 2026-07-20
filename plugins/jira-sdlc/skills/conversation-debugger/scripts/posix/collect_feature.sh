#!/usr/bin/env bash
# collect_feature.sh <ISSUE-KEY> — POSIX entry point, kept so the skill's
# existing dispatch is unchanged. A thin shim: all logic lives in the dual-use
# core ../py/collect_feature.py (its docstring is the full header; usage notes
# in ../collect_feature.md).
set -u
command -v python3 >/dev/null 2>&1 || {
  printf 'collect_feature: python3 is required but not on PATH.\n' >&2; exit 1; }
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$DIR/../py/collect_feature.py" "$@"
