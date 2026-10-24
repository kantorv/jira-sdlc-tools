# strategies/submodules.sh — a parent repo holding its member repos as git
# submodules. Sourced by repos.sh, which provides ROOT, BASE_BRANCH,
# MEMBERS_CFG, LIST_HEADER and the helpers. One function per verb: s_<verb>.
# win/strategies/submodules.ps1 is the twin.
#
# Members are the paths JST_MEMBERS lists, in that order; .gitmodules checks
# them rather than defining them, so a vendored submodule can never become a
# member by accident. Every other top-level submodule is pinned. Nested
# submodules (a member's own) are never members.

# members_check — fill MEMBERS (validated paths, JST_MEMBERS order), PINNED and
# ERR (the first problem found, empty when valid). On an error MEMBERS and
# PINNED are left empty: a half-validated list would read as a real one.
members_check() {
  _members_check
  [ -z "$ERR" ] || { MEMBERS=""; PINNED=""; }
}
_members_check() {
  local all p seen=" "
  MEMBERS="" PINNED="" ERR=""
  if [ ! -f "$ROOT/.gitmodules" ]; then
    ERR="JST_MEMBERS is set, but the project has no .gitmodules — list the submodule paths that take part in issues, or leave it empty for a single-repo project"
    return
  fi
  all=" $(submodules | cut -f2 | paste -sd' ' -) "
  for p in $MEMBERS_CFG; do
    case "$seen" in *" $p "*) ERR="JST_MEMBERS lists '$p' twice"; return ;; esac
    case "$all" in *" $p "*) ;; *) ERR="JST_MEMBERS lists '$p', which isn't a top-level submodule in .gitmodules"; return ;; esac
    seen="$seen$p "
    MEMBERS="${MEMBERS:+$MEMBERS }$p"
  done
  for p in $all; do
    case "$seen" in *" $p "*) ;; *) PINNED="${PINNED:+$PINNED }$p" ;; esac
  done
}

s_strategy() {
  members_check
  printf 'strategy=submodules\nroot=%s\nmembers=%s\npinned=%s\n' "$ROOT" "$MEMBERS" "$PINNED"
  if [ -n "$ERR" ]; then printf 'error=%s\n' "$ERR"; exit 2; fi
}

# member_base <name> — the member's base: its .gitmodules branch, else the
# project's DEFAULT_BASE_BRANCH. `branch = .` ("same as the superproject")
# can't name a base, so it reads as `error`.
member_base() {
  local b
  b=$(git config -f "$ROOT/.gitmodules" --get "submodule.$1.branch" 2>/dev/null || true)
  case "$b" in
    .)  printf 'error' ;;
    "") printf '%s' "${BASE_BRANCH:--}" ;;
    *)  printf '%s' "$b" ;;
  esac
}

s_list() {
  local p name url slug root_url
  members_check
  if [ -n "$ERR" ]; then printf 'error=%s\n' "$ERR"; exit 2; fi
  printf '%s\n' "$LIST_HEADER"
  # The root's own state, without its submodules: a member on its issue branch
  # always differs from the parent's gitlink, and moving the gitlink is
  # landing's job, not a sign of uncommitted work here.
  repo_row . root "${BASE_BRANCH:--}" "--ignore-submodules=all"
  root_url=$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)
  for p in $MEMBERS; do
    name=$(submodules | awk -F'\t' -v p="$p" '$2 == p { print $1; exit }')
    if [ "$(git -C "$ROOT/$p" rev-parse --show-toplevel 2>/dev/null)" = "$ROOT/$p" ]; then
      repo_row "$p" member "$(member_base "$name")" ""
    else
      url=$(git config -f "$ROOT/.gitmodules" --get "submodule.$name.url" 2>/dev/null || true)
      slug=$(gh_slug "$(resolve_url "$root_url" "$url")" 2>/dev/null) || slug=-
      printf '%s\tmember\tno\t%s\t%s\t-\t-\t-\n' "$p" "$slug" "$(member_base "$name")"
    fi
  done
}

s_prs() { v_prs; }

s_gate() {
  # A multistep issue across members needs per-member parent PRs before it can
  # land — a third level this strategy doesn't build yet. Say so instead of
  # guessing at a phase.
  if [ -n "$OPT_MULTISTEP" ]; then
    need_branch
    printf 'phase=stop\nreason=multistep issues (Jira sub-tasks) across member repos aren'"'"'t supported yet — review the sub-task PRs by hand\nroot=unknown\nmembers=unknown\n'
    exit 0
  fi
  v_gate
}

s_land() { v_land; }
