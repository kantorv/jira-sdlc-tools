#!/usr/bin/env bash
# collect_feature.sh — STUB (not yet implemented on POSIX).
#
# The feature-level roll-up collector currently ships as a Windows-only port
# (../win/collect_feature.ps1). This POSIX twin is a deliberate, explicit
# STUB — it does nothing and exits non-zero — so the parity gap is visible at
# the point of use rather than silently producing empty or wrong output.
#
# This intentionally deviates from the repo's usual "every script ships as a
# working posix+win contract pair" rule (AGENTS.md): only the win/ collector +
# report-builder are implemented this round. A full bash port (bash + jq +
# python3, mirroring collect_run.sh / sync_conversations.sh) is future work.
#
# What the real script will do — the contract the win/ port already fulfils:
#   collect_feature <ISSUE-KEY>  ->  resolve every conversation of the feature
#   (reusing sync_conversations' path list) -> run collect_run over each ->
#   emit the feature-report JSON on stdout (+ a human metrics view on stderr).
#   See ../collect_feature.md and ../../references/feature-report-schema.md.
#
# Exit: 3 = not implemented on this platform (never 0 — nothing was produced).

printf 'collect_feature: NOT IMPLEMENTED on POSIX — this is a stub.\n' >&2
printf '  The feature roll-up collector ships Windows-only this round:\n' >&2
printf '    pwsh %s/win/collect_feature.ps1 <ISSUE-KEY>\n' "$(cd "$(dirname "$0")/.." && pwd)" >&2
printf '  (A full bash+jq+python3 port is future work — see ../collect_feature.md.)\n' >&2
exit 3
