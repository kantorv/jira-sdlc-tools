#!/usr/bin/env bash
# gh.sh — run gh as this project's GitHub identity, for one command only.
#
# Usage:  bash gh.sh <any gh arguments>      e.g.  bash gh.sh pr create -R o/r …
#
# Reads GITHUB_PAT_TOKEN from .jst/jira-sdlc-tools.local.env in the project root
# (found through jst_root, so it works from a worktree and from inside a member
# submodule) and runs gh with GH_TOKEN set for that one process. gh documents
# GH_TOKEN as taking precedence over stored credentials (`gh help environment`),
# so no `gh auth login` is needed and nothing global is written: ~/.config/gh,
# the keyring and the developer's own gh session stay exactly as they were, and
# two projects with different PATs can run side by side without racing
# (JST-331 — the JST-146 per-request pattern, applied to gh).
#
# Pass-through contract: gh's arguments, stdout, stderr and exit code are gh's
# own. The wrapper adds two errors of its own, both on stderr as "jst-gh: …":
#   127 — gh (GitHub CLI) is not installed
#   4   — GITHUB_PAT_TOKEN is unset (gh's own "authentication required" code).
#         Never a fall back to gh's stored session: that is whichever account
#         logged in last, possibly for another project.
#
# PowerShell twin: ../win/gh.ps1 (contract pair — same args/output/exit codes;
# edit one, edit the other). Docs:
# https://kantorv.github.io/jira-sdlc-tools/docs/gh-pat-session-login

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_jst_root.sh"

root=$(jst_root || true)
env_file="${root:-$PWD}/.jst/jira-sdlc-tools.local.env"

command -v gh >/dev/null 2>&1 || {
  printf '%s\n' "jst-gh: gh (GitHub CLI) is not installed — https://cli.github.com" >&2; exit 127; }

# One key, parsed rather than sourced (the file holds every role's secrets):
# the same `NAME = value`, last-match-wins rule as statuscheck's cfg, then one
# surrounding pair of quotes stripped.
tok=""
[ -f "$env_file" ] && tok=$(grep -E '^[[:space:]]*GITHUB_PAT_TOKEN[[:space:]]*=' "$env_file" 2>/dev/null \
  | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
tok=${tok#\"}; tok=${tok%\"}; tok=${tok#\'}; tok=${tok%\'}
if [ -z "$tok" ]; then
  printf '%s\n' "jst-gh: GITHUB_PAT_TOKEN is unset in $env_file — gh runs only with this project's PAT, never gh's stored login" >&2
  exit 4
fi

GH_TOKEN=$tok exec gh "$@"
