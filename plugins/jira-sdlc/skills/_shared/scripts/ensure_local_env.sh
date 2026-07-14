#!/usr/bin/env bash
# ensure_local_env.sh — make sure jira-sdlc-tools.local.env exists in this
# checkout before anything reads it.
#
# A linked worktree shares only tracked files with its main checkout, so it
# is born WITHOUT jira-sdlc-tools.local.env (gitignored — it holds machine-
# local secrets). Every skill must repair that before jira_acli_login.sh
# runs, or login dies on a worktree that was never given the file in the
# first place. Call this FIRST in each skill's step 1, before
# jira_acli_login.sh and statuscheck.sh — this is the ONLY place the copy
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
[ -f "$WT_ROOT/jira-sdlc-tools.local.env" ] && exit 0   # already present — don't overwrite

# .git points at "gitdir: <main>/.git/worktrees/<name>"; <main> sits three
# dirnames down (worktrees/<name> -> .git -> repo root).
GITDIR=$(sed -n 's/^gitdir: //p' "$WT_ROOT/.git" 2>/dev/null || true)
MAIN_ROOT=$(dirname "$(dirname "$(dirname "$GITDIR")")" 2>/dev/null || true)

if [ -n "$MAIN_ROOT" ] && [ -d "$MAIN_ROOT/.git" ] \
   && [ -f "$MAIN_ROOT/jira-sdlc-tools.local.env" ] \
   && cp "$MAIN_ROOT/jira-sdlc-tools.local.env" "$WT_ROOT/jira-sdlc-tools.local.env" 2>/dev/null \
   && [ -f "$WT_ROOT/jira-sdlc-tools.local.env" ]; then
  echo "ensure_local_env: copied jira-sdlc-tools.local.env from the main checkout ($MAIN_ROOT)."
  exit 0
fi

printf '%s\n' "ensure_local_env: jira-sdlc-tools.local.env missing here and not found in the main checkout either — create it in the main checkout first (Jira URL/email/token — see skills/_shared/project-config.md), then rerun." >&2
exit 1
