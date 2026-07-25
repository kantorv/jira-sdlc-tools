#!/usr/bin/env bash
# ensure_local_env.sh — make sure .jst/jira-sdlc-tools.local.env exists in
# this checkout before anything reads it.
#
# A linked worktree shares only tracked files with its main checkout, so it
# is born WITHOUT .jst/jira-sdlc-tools.local.env (gitignored — it holds machine-
# local secrets). Every skill must repair that before the jira.sh calls run,
# or the per-request auth has no role credential on a worktree that was never
# given the file in the first place. Call this FIRST in each skill's step 1,
# before statuscheck.sh — this is the ONLY place the copy
# logic lives; statuscheck.sh delegates here too for its env_local /
# env_local_ignored rows rather than duplicating it.
#
# Usage: bash ensure_local_env.sh
#
# Exit 0 — a linked worktree now has the file (just copied, or already had
#          it — idempotent, never overwrites), OR this is the main checkout
#          (nothing to copy; a main checkout genuinely missing the file is
#          not this script's job — see statuscheck.sh's env_local row).
# Exit 1 — a linked worktree has no local.env and the main checkout doesn't
#          either, so there's nothing to copy. Actionable remedy on stderr.

set -u

WT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$WT_ROOT" ] && exit 0   # not a git repo — statuscheck.sh's git_repo row FAILs on this

# A linked worktree's .git is a *file* (pointer into the main repo's
# .git/worktrees/<name>); the main checkout's .git is a directory.
[ -f "$WT_ROOT/.git" ] || exit 0                        # main checkout — nothing to copy
[ -f "$WT_ROOT/.jst/jira-sdlc-tools.local.env" ] && exit 0   # already present — don't overwrite

# .git points at "gitdir: <main>/.git/worktrees/<name>"; <main> sits three
# dirnames down (worktrees/<name> -> .git -> repo root).
GITDIR=$(sed -n 's/^gitdir: //p' "$WT_ROOT/.git" 2>/dev/null || true)
MAIN_ROOT=$(dirname "$(dirname "$(dirname "$GITDIR")")" 2>/dev/null || true)

# The destination folder is normally already there (.jst/jira-sdlc-tools.env is
# tracked, so checkout materialises .jst/ in a fresh worktree), but create it
# anyway — the copy is the one path that must not depend on that.
if [ -n "$MAIN_ROOT" ] && [ -d "$MAIN_ROOT/.git" ] \
   && [ -f "$MAIN_ROOT/.jst/jira-sdlc-tools.local.env" ] \
   && mkdir -p "$WT_ROOT/.jst" 2>/dev/null \
   && cp "$MAIN_ROOT/.jst/jira-sdlc-tools.local.env" "$WT_ROOT/.jst/jira-sdlc-tools.local.env" 2>/dev/null \
   && [ -f "$WT_ROOT/.jst/jira-sdlc-tools.local.env" ]; then
  echo "ensure_local_env: copied .jst/jira-sdlc-tools.local.env from the main checkout ($MAIN_ROOT)."
  exit 0
fi

printf '%s\n' "ensure_local_env: .jst/jira-sdlc-tools.local.env missing here and not found in the main checkout either — create it in the main checkout first (Jira URL/email/token — see skills/_shared/project-config.md), then rerun." >&2
exit 1
