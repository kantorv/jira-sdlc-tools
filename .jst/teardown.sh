#!/usr/bin/env bash
#
# teardown.sh - tear down this worktree's Python environment.
#
# Removes the venv/ directory created by bootstrap.sh.

set -euo pipefail

WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Refuse if this is the main checkout (not a worktree)
# Use mapfile to avoid pipefail + early-exit awk SIGPIPE issue
mapfile -t worktree_list < <(git -C "$WORKTREE" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
MAIN_CHECKOUT="${worktree_list[0]:-}"
[ -n "$MAIN_CHECKOUT" ] && [ "$WORKTREE" != "$MAIN_CHECKOUT" ] \
    || die "this is the main checkout ($WORKTREE), not a worktree. Teardown runs only in worktrees."

if [ -d "$WORKTREE/venv" ]; then
    log "removing $WORKTREE/venv"
    rm -rf "$WORKTREE/venv"
    log "teardown complete"
else
    log "no venv found, nothing to do"
fi