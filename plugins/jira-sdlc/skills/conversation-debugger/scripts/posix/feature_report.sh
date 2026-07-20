#!/usr/bin/env bash
# feature_report.sh [<json-path>] — POSIX entry point for the feature-report
# renderer. The implementation is the dual-use Python core ../py/feature_report.py
# (see its header for the full contract: collect_feature JSON in on a path arg or
# stdin, markdown report on stdout, exit 0/1); this shim only checks python3 and
# exec's it, so the skill's existing `bash posix/feature_report.sh` dispatch
# keeps working. Windows twin: ../win/feature_report.ps1 (native PowerShell,
# no-Python back-compat; same CLI, stdout, exit codes).
set -u
command -v python3 >/dev/null 2>&1 || {
  printf 'feature_report: python3 is required but not on PATH.\n' >&2; exit 1; }
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$DIR/../py/feature_report.py" "$@"
