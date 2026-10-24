#!/usr/bin/env bash
# repos.sh — the set of repos an issue's work spans, behind one front door.
#
# A project is one repo (the "single" strategy) or a parent repo holding member
# repos as git submodules (the "submodules" strategy). The skills call this
# script for repo work and act on its output; which strategy applies, and what
# it means for each verb, lives in strategies/<name>.sh. A single-repo project
# is a set of one, so the same skill sentence covers both. Design:
# https://kantorv.github.io/jira-sdlc-tools/docs/proposals/submodules-strategy
#
# Usage: bash repos.sh <verb>
#   strategy  which strategy applies — key=value lines:
#               strategy=single|submodules
#               root=<project root>
#               members=<paths, space-separated; empty for single>
#               pinned=<top-level submodules that aren't members>
#   list      one row per repo in the set, root first — tab-separated, with a
#             header: repo role initialized slug base branch dirty ahead.
#             Local facts only: no network.
#
# The strategy comes from JST_MEMBERS in .jst/jira-sdlc-tools.env: the
# submodule paths that take part in issues. Unset or empty → single, whether or
# not the project has submodules (unlisted ones stay pinned); set → submodules.
#
# Exit 0 — ok.
# Exit 2 — usage error (message on stderr, nothing on stdout), or JST_MEMBERS
#          is invalid: stdout then ends with an `error=<reason>` line, which
#          statuscheck's repo_strategy row relays.
#
# win/repos.ps1 is the twin: same arguments, output and exit codes.

set -u
SC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SC_DIR/_jst_root.sh"

die_usage() { printf '%s\n' "repos: $1" >&2; exit 2; }

VERB="${1:-}"
case "$VERB" in
  strategy|list) ;;
  "") die_usage "a verb is required — one of: strategy, list" ;;
  *)  die_usage "unknown verb '$VERB' — one of: strategy, list" ;;
esac

ROOT=$(jst_root) || die_usage "not inside a git repository"
CFG_DIR="$ROOT/.jst"

# Same `NAME = value` parser as the other scripts: local.env overrides .env,
# the last match in a file wins, values are parsed, never sourced.
cfg() {
  local f v
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$CFG_DIR/$f" ] || continue
    v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$CFG_DIR/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}

# --- helpers the strategies share ---------------------------------------------

# gh_slug <remote-url> -> OWNER/REPO; non-zero when not github.com (statuscheck's rule).
gh_slug() {
  local u="$1" s
  case "$u" in *github.com*) ;; *) return 1 ;; esac
  s=${u#*github.com}
  s=${s#:}; s=${s#/}; s=${s%/}; s=${s%.git}
  printf '%s' "$s" | grep -qE '^[^/]+/[^/]+$' || return 1
  printf '%s' "$s"
}

# resolve_url <base-url> <url> — a .gitmodules URL, with git's relative form
# (./x, ../x) resolved against the root's origin. Absolute URLs pass through.
resolve_url() {
  local base="$2" rel
  case "$2" in ./*|../*) ;; *) printf '%s' "$2"; return 0 ;; esac
  base="$1"; rel="$2"
  base=${base%/}
  while :; do
    case "$rel" in
      ./*)  rel=${rel#./} ;;
      ../*) rel=${rel#../}
            case "$base" in */*) base=${base%/*} ;; *:*) base=${base%%:*}: ;; esac ;;
      *) break ;;
    esac
  done
  case "$base" in *:) printf '%s%s' "$base" "$rel" ;; *) printf '%s/%s' "$base" "$rel" ;; esac
}

# submodules — "<name>\t<path>" per top-level submodule, in .gitmodules order.
# Names may contain dots, hence the greedy match.
submodules() {
  [ -f "$ROOT/.gitmodules" ] || return 0
  git config -f "$ROOT/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | sed -E 's/^submodule\.(.*)\.path (.*)$/\1\t\2/'
}

# repo_row <path> <role> <base> <dirty-flags> — one `list` row for a checked-out repo.
repo_row() {
  local p="$1" dir branch dirty ahead slug url
  dir="$ROOT"; [ "$p" = . ] || dir="$ROOT/$p"
  url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  slug=$(gh_slug "$url" 2>/dev/null) || slug=-
  branch=$(git -C "$dir" branch --show-current 2>/dev/null || true)
  [ -n "$branch" ] || branch="(detached)"
  # shellcheck disable=SC2086  # $4 is a deliberate list of flags
  if [ -n "$(git -C "$dir" status --porcelain $4 2>/dev/null)" ]; then dirty=yes; else dirty=no; fi
  ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null) || ahead=-
  printf '%s\t%s\tyes\t%s\t%s\t%s\t%s\t%s\n' "$p" "$2" "$slug" "$3" "$branch" "$dirty" "$ahead"
}

LIST_HEADER=$(printf 'repo\trole\tinitialized\tslug\tbase\tbranch\tdirty\tahead')
BASE_BRANCH=$(cfg DEFAULT_BASE_BRANCH || true)
MEMBERS_CFG=$(cfg JST_MEMBERS || true)

if [ -n "$MEMBERS_CFG" ]; then STRATEGY=submodules; else STRATEGY=single; fi
. "$SC_DIR/strategies/$STRATEGY.sh"

"s_$VERB"
