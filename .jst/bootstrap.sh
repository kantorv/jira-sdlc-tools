#!/usr/bin/env bash
#
# bootstrap.sh - provision this worktree's Python environment.
#
# Runs once per worktree: if venv/ exists, it exits quietly.
# To re-bootstrap: rm -rf venv && .jst/bootstrap.sh
#
# The venv is only active inside this script; activate it in your own shell:
#   source venv/bin/activate

set -euo pipefail

WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Refuse if this is the main checkout (not a worktree)
# Use mapfile to avoid pipefail + early-exit awk SIGPIPE issue
mapfile -t worktree_list < <(git -C "$WORKTREE" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
MAIN_CHECKOUT="${worktree_list[0]:-}"
[ -n "$MAIN_CHECKOUT" ] && [ "$WORKTREE" != "$MAIN_CHECKOUT" ] \
    || die "this is the main checkout ($WORKTREE), not a worktree. Bootstrap runs only in worktrees."

# Already bootstrapped?
[ -d "$WORKTREE/venv" ] && exit 0

# Create venv and install cedit
log "python environment: $WORKTREE/venv"
python3 -m venv "$WORKTREE/venv"
# activate scripts touch unset variables ($PS1), which trips `set -u`
set +u; . "$WORKTREE/venv/bin/activate"; set -u
pip install cedit

log "bootstrap complete — activate in your shell with: source $WORKTREE/venv/bin/activate"