#!/usr/bin/env bash
# ensure_local_env.sh — give a linked worktree the whole .jst/ contract, and
# make sure git ignores the credential file there, before anything reads it.
#
# A linked worktree shares only TRACKED files with its main checkout. Straight
# after jst-install the whole .jst/ folder is still untracked (it's the payload
# of the recommended first task), so a worktree cut at that moment is born with
# no .jst/ at all — no jira-sdlc-tools.env, and no .gitignore. Copying
# jira-sdlc-tools.local.env in at that point used to land three Jira role
# tokens and a GitHub PAT with nothing ignoring them, one `git add -A` away
# from a commit (JST-301). So this script provisions all three files, and
# treats "git ignores the credential path here" as a precondition for writing
# it rather than as something statuscheck notices afterwards.
#
# Only those three are synced — not whatever else a project keeps in .jst/.
# The list is the contract the skills depend on, and a copy that reaches for
# credentials is the wrong place to be liberal about what it moves; anything
# else in .jst/ arrives the moment the folder is committed.
#
# Call this FIRST in each skill's step 1, before statuscheck.sh — this is the
# ONLY place the copy logic lives; statuscheck.sh delegates here too for its
# env_config / env_local / env_local_ignored rows rather than duplicating it.
#
# Usage: bash ensure_local_env.sh
#
# Exit 0 — a linked worktree now has the .jst/ contract and an ignored
#          local.env (just provisioned, or already there — idempotent, never
#          overwrites an existing file), OR this is the main checkout
#          (nothing to copy; a main checkout genuinely missing the file is
#          not this script's job — see statuscheck.sh's env_local row).
# Exit 1 — a linked worktree has no local.env and the main checkout doesn't
#          either, so there's nothing to copy; or git does not ignore the
#          credential path here and the rule couldn't be established. Either
#          way an actionable remedy goes to stderr, and no unignored
#          credential file is left behind.

set -u

LOCAL_ENV_NAME=jira-sdlc-tools.local.env

WT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -z "$WT_ROOT" ] && exit 0   # not a git repo — statuscheck.sh's git_repo row FAILs on this

# A linked worktree's .git is a *file* (pointer into the main repo's
# .git/worktrees/<name>); the main checkout's .git is a directory.
[ -f "$WT_ROOT/.git" ] || exit 0   # main checkout — nothing to copy

# .git points at "gitdir: <main>/.git/worktrees/<name>"; <main> sits three
# dirnames down (worktrees/<name> -> .git -> repo root).
GITDIR=$(sed -n 's/^gitdir: //p' "$WT_ROOT/.git" 2>/dev/null || true)
MAIN_ROOT=$(dirname "$(dirname "$(dirname "$GITDIR")")" 2>/dev/null || true)
[ -n "$MAIN_ROOT" ] && [ -d "$MAIN_ROOT/.git" ] || MAIN_ROOT=""

JST_DIR="$WT_ROOT/.jst"
IGNORE_FILE="$JST_DIR/.gitignore"

# The destination folder is normally already there (.jst/ is tracked once the
# project has committed it), but create it anyway — every write below is the
# path that must not depend on that.
mkdir -p "$JST_DIR" 2>/dev/null || true

sync_in() { # sync_in <filename> — copy from the main checkout only when absent here
  [ -n "$MAIN_ROOT" ] || return 0
  [ -f "$JST_DIR/$1" ] && return 0
  [ -f "$MAIN_ROOT/.jst/$1" ] || return 0
  cp "$MAIN_ROOT/.jst/$1" "$JST_DIR/$1" 2>/dev/null || return 0
  echo "ensure_local_env: copied .jst/$1 from the main checkout ($MAIN_ROOT)."
}

# 1. The ignore rule, before the credential file it protects. jst-install 1b
#    puts it inside .jst/ precisely so that carrying the folder carries the
#    protection; appending it here covers the case where neither checkout has
#    the rule yet.
sync_in .gitignore
if ! grep -qxF "$LOCAL_ENV_NAME" "$IGNORE_FILE" 2>/dev/null; then
  # A file whose last byte isn't a newline would otherwise swallow the rule
  # onto the end of its final line.
  # Group the redirect: bash applies `>>` before `2>/dev/null`, so an
  # unwritable .jst/ would otherwise announce "Permission denied" on stderr
  # ahead of the precise remedy below — and the ps1 port's try/catch is silent.
  if [ -s "$IGNORE_FILE" ] && [ -n "$(tail -c1 "$IGNORE_FILE" 2>/dev/null)" ]; then
    { printf '\n' >> "$IGNORE_FILE"; } 2>/dev/null || true
  fi
  if { printf '%s\n' "$LOCAL_ENV_NAME" >> "$IGNORE_FILE"; } 2>/dev/null; then
    echo "ensure_local_env: added '$LOCAL_ENV_NAME' to .jst/.gitignore."
  fi
fi

# 2. The team-shared config. Absent from the main checkout too isn't fatal
#    here — statuscheck's env_config row reports that, with its own remedy.
sync_in jira-sdlc-tools.env

# 3. The credential file — but only once git actually ignores the path. Ask
#    git rather than trusting the write above: a negation rule elsewhere
#    ("!.jst/**") can still un-ignore it, and being wrong here is what leaks
#    the tokens.
if ! git -C "$WT_ROOT" check-ignore -q ".jst/$LOCAL_ENV_NAME" 2>/dev/null; then
  if [ -f "$JST_DIR/$LOCAL_ENV_NAME" ]; then
    printf '%s\n' "ensure_local_env: .jst/$LOCAL_ENV_NAME is present here but git does not ignore that path — it holds three Jira role tokens and a GitHub PAT that a 'git add' would commit. Add a line '$LOCAL_ENV_NAME' to .jst/.gitignore (where jst-install puts the rule), then rerun." >&2
  else
    printf '%s\n' "ensure_local_env: refusing to write .jst/$LOCAL_ENV_NAME here — git does not ignore that path, so the three Jira role tokens and the GitHub PAT it holds would be one 'git add' away from a commit. Add a line '$LOCAL_ENV_NAME' to .jst/.gitignore (where jst-install puts the rule), then rerun." >&2
  fi
  exit 1
fi

[ -f "$JST_DIR/$LOCAL_ENV_NAME" ] && exit 0   # already present — don't overwrite

if [ -n "$MAIN_ROOT" ] && [ -f "$MAIN_ROOT/.jst/$LOCAL_ENV_NAME" ] \
   && cp "$MAIN_ROOT/.jst/$LOCAL_ENV_NAME" "$JST_DIR/$LOCAL_ENV_NAME" 2>/dev/null \
   && [ -f "$JST_DIR/$LOCAL_ENV_NAME" ]; then
  echo "ensure_local_env: copied .jst/$LOCAL_ENV_NAME from the main checkout ($MAIN_ROOT)."
  exit 0
fi

printf '%s\n' "ensure_local_env: .jst/$LOCAL_ENV_NAME missing here and not found in the main checkout either — create it in the main checkout first (Jira URL/email/token — see skills/_shared/project-config.md), then rerun." >&2
exit 1
