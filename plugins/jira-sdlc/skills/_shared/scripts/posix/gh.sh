#!/usr/bin/env bash
# gh.sh — run gh as this project's GitHub identity, for one command only.
#
# Usage:  bash gh.sh <any gh arguments>      e.g.  bash gh.sh pr create -R o/r …
#
# Reads GITHUB_PAT_TOKEN through _jst_config.sh — from the project's own .jst/
# local env, or from the credential profile the project uses (JSW-37); the
# project root is found through jst_root, so it works from a worktree and from
# inside a member submodule — and runs gh with GH_TOKEN set for that one process. gh documents
# GH_TOKEN as taking precedence over stored credentials (`gh help environment`),
# so no `gh auth login` is needed and nothing global is written: ~/.config/gh,
# the keyring and the developer's own gh session stay exactly as they were, and
# two projects with different PATs can run side by side without racing
# (JST-331 — the JST-146 per-request pattern, applied to gh).
#
# Pass-through contract: gh's arguments, stdout, stderr and exit code are gh's
# own. The wrapper adds two errors of its own, both on stderr as "jst-gh: …":
#   127 — gh (GitHub CLI) is not installed
#   4   — no GITHUB_PAT_TOKEN: unset, or the credentials can't be resolved (a
#         partial set, a missing or open profile, an owner mismatch) — gh's own
#         "authentication required" code.
#         Never a fall back to gh's stored session: that is whichever account
#         logged in last, possibly for another project.
#
# PowerShell twin: ../win/gh.ps1 (contract pair — same args/output/exit codes;
# edit one, edit the other). Docs:
# https://kantorv.github.io/jira-sdlc-tools/docs/gh-pat-session-login

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_jst_root.sh"
. "$(dirname "${BASH_SOURCE[0]}")/_jst_config.sh"

command -v gh >/dev/null 2>&1 || {
  printf '%s\n' "jst-gh: gh (GitHub CLI) is not installed — https://cli.github.com" >&2; exit 127; }

# One key, from the group's one source (never sourced: the files hold every
# role's secrets), then one surrounding pair of quotes stripped.
jst_config_init
if ! jst_cred_resolve; then
  printf '%s\n' "jst-gh: $JST_CRED_ERR — $JST_CRED_FIX (gh runs only with this project's PAT, never gh's stored login)" >&2
  exit 4
fi
tok=$(jst_cred GITHUB_PAT_TOKEN || true)
tok=${tok#\"}; tok=${tok%\"}; tok=${tok#\'}; tok=${tok%\'}
if [ -z "$tok" ]; then
  printf '%s\n' "jst-gh: GITHUB_PAT_TOKEN is unset in $JST_CRED_WHERE — gh runs only with this project's PAT, never gh's stored login" >&2
  exit 4
fi

GH_TOKEN=$tok exec gh "$@"
