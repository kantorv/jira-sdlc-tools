# _jst_root.sh — where the project lives, for every script in this folder.
# Sourced, never run: `. "$(dirname "${BASH_SOURCE[0]}")/_jst_root.sh"`.
# win/_jst_root.ps1 is its twin; keep the two in step.
#
# jst_root — print the project root: the folder whose .jst/ holds the config.
#
#   Starts at the git toplevel and walks up through superprojects, because a
#   project can hold its member repos as submodules and a skill may run from
#   inside one. git answers --show-superproject-working-tree one level at a
#   time, so a nested submodule needs the loop. The root is the OUTERMOST level
#   of that chain that has a .jst/ folder:
#     - a plain repo is a chain of one, so it resolves exactly as
#       --show-toplevel always did;
#     - inside a member, the parent wins, even when the member has a .jst/ of
#       its own (it may also be used standalone) — the project's config rules;
#     - a project vendored into an unrelated repo stops at itself, because the
#       outer repo has no .jst/;
#     - when no level has .jst/ yet (a worktree cut before .jst/ was committed),
#       it's the outermost level, which is where ensure_local_env creates it.
#   Exit 1 and no output outside a git repository.
jst_root() {
  local d sup outer="" found="" n=0
  d=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$d" ] || return 1
  while [ -n "$d" ] && [ "$n" -lt 32 ]; do   # the cap only guards against a loop
    outer=$d
    [ -d "$d/.jst" ] && found=$d
    sup=$(git -C "$d" rev-parse --show-superproject-working-tree 2>/dev/null || true)
    d=$sup
    n=$((n + 1))
  done
  printf '%s\n' "${found:-$outer}"
}

# _jst_gitdir <root> — the gitdir a .git *file* points at, absolute. Empty when
# .git is a directory. git writes a linked worktree's gitdir absolute, but a
# submodule's (and, with worktree.useRelativePaths, a worktree's) relative to
# the folder holding the .git file — not to the caller's working directory.
_jst_gitdir() {
  local gd
  [ -f "$1/.git" ] || return 0
  gd=$(sed -n 's/^gitdir: //p' "$1/.git" 2>/dev/null | head -1)
  [ -n "$gd" ] || return 0
  case "$gd" in /*|[A-Za-z]:*) ;; *) gd="$1/$gd" ;; esac
  printf '%s\n' "$gd"
}

# jst_is_linked_worktree <root> — exit 0 when <root> is a linked worktree.
#   A worktree's .git is a file pointing at <main>/.git/worktrees/<name>. A
#   submodule's .git is a file too — pointing at …/modules/<name> — so "is .git
#   a file" alone misreads every member as a worktree. The worktrees/ parent is
#   what tells them apart.
jst_is_linked_worktree() {
  local gd
  gd=$(_jst_gitdir "$1")
  [ -n "$gd" ] && [ "$(basename "$(dirname "$gd")")" = "worktrees" ]
}

# jst_main_checkout <root> — print the main checkout's root when <root> is a
#   linked worktree whose main checkout still exists (<main> sits three
#   dirnames up from the gitdir: worktrees/<name> -> .git -> repo root).
#   Prints nothing otherwise; exit 0 either way.
jst_main_checkout() {
  local m
  jst_is_linked_worktree "$1" || return 0
  m=$(dirname "$(dirname "$(dirname "$(_jst_gitdir "$1")")")")
  [ -d "$m/.git" ] && printf '%s\n' "$m"
  return 0
}
