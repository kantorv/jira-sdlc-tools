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

# actionlint isn't a PyPI package — it's a Go binary. Fetch a pinned release
# tarball and check it against a hash recorded here, so a changed upstream
# asset fails the bootstrap instead of running. To bump: change the version
# and copy the hashes from that release's actionlint_<ver>_checksums.txt.
ACTIONLINT_VERSION=1.7.12
case "$(uname -s)_$(uname -m)" in
    Linux_x86_64)                ACTIONLINT_PLATFORM=linux_amd64  ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8 ;;
    Linux_aarch64|Linux_arm64)   ACTIONLINT_PLATFORM=linux_arm64  ACTIONLINT_SHA256=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6 ;;
    Darwin_x86_64)               ACTIONLINT_PLATFORM=darwin_amd64 ACTIONLINT_SHA256=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644 ;;
    Darwin_arm64)                ACTIONLINT_PLATFORM=darwin_arm64 ACTIONLINT_SHA256=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f ;;
    *) die "no pinned actionlint build for $(uname -s)/$(uname -m) — install it yourself" ;;
esac
log "installing actionlint $ACTIONLINT_VERSION into $WORKTREE/venv/bin"
tarball="$WORKTREE/venv/actionlint.tar.gz"
curl -fsSL -o "$tarball" \
    "https://github.com/rhysd/actionlint/releases/download/v$ACTIONLINT_VERSION/actionlint_${ACTIONLINT_VERSION}_$ACTIONLINT_PLATFORM.tar.gz"
actual="$( (sha256sum "$tarball" 2>/dev/null || shasum -a 256 "$tarball") | cut -d' ' -f1)"
[ "$actual" = "$ACTIONLINT_SHA256" ] || die "actionlint checksum mismatch (got $actual)"
tar -xzf "$tarball" -C "$WORKTREE/venv/bin" actionlint
rm -f "$tarball"

log "bootstrap complete — activate in your shell with: source $WORKTREE/venv/bin/activate"