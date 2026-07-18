#!/usr/bin/env bash
# feature_report.sh — STUB (not yet implemented on POSIX).
#
# The markdown report-builder half of the feature roll-up currently ships as a
# Windows-only port (../win/feature_report.ps1). This POSIX twin is a
# deliberate, explicit STUB — it does nothing and exits non-zero — so the
# parity gap is visible at the point of use rather than silently emitting an
# empty or malformed report.
#
# This intentionally deviates from the repo's usual "every script ships as a
# working posix+win contract pair" rule (AGENTS.md): only the win/ collector +
# report-builder are implemented this round. A full bash port (bash + jq,
# reading the same collector JSON) is future work.
#
# What the real script will do — the contract the win/ port already fulfils:
#   feature_report [<json-path>]  ->  read collect_feature's JSON (from a path
#   and/or stdin) and render the markdown feature report on stdout. The COLLECTOR
#   owns the JSON schema; this only reads it. See ../feature_report.md and
#   ../../references/feature-report-schema.md.
#
# Exit: 3 = not implemented on this platform (never 0 — nothing was produced).

printf 'feature_report: NOT IMPLEMENTED on POSIX — this is a stub.\n' >&2
printf '  The markdown report-builder ships Windows-only this round:\n' >&2
printf '    collect_feature <KEY> | pwsh %s/win/feature_report.ps1\n' "$(cd "$(dirname "$0")/.." && pwd)" >&2
printf '  (A full bash+jq port is future work — see ../feature_report.md.)\n' >&2
exit 3
