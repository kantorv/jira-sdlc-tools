#!/usr/bin/env bash
# github_pat_auth.sh — run the skills' git/gh against GitHub as the agent's
# repo-scoped fine-grained PAT, without touching the human's persistent config.
#
# The contract this script implements is documented in detail at
# ../../docs/github/GITHUB-AUTH-STRATEGY.md — read that for the *why*
# ("agent never writes persistent auth state"). This file is the *how*: a
# single choke point the skills call instead of `git`/`gh` directly, so the
# PAT is supplied fresh per command and leaves no trace.
#
# The invariant (strategy doc §3/§5): exactly one identity lives in
# persistent config — the human's. `origin` is never re-pointed, nothing is
# ever written to .git/config or ~/.config/gh/hosts.yml, and the token is
# never embedded in a URL, printed, or placed on a command line.
#
# Usage:
#   bash github_pat_auth.sh remote-url            # print the HTTPS clone URL derived from origin
#   bash github_pat_auth.sh verify               # PAT present + GitHub accepts it (repo-scoped); exit 0/1
#   bash github_pat_auth.sh git <git-args...>    # run `git` with the PAT credential helper applied
#   bash github_pat_auth.sh gh  <gh-args...>     # run `gh`  with GH_TOKEN=<PAT> for this one process
#   bash github_pat_auth.sh fetch               # git fetch over the PAT-based HTTPS URL into refs/remotes/origin/*
#
# Token: read from GITHUB_PAT_TOKEN in jira-sdlc-tools.local.env (machine-specific,
# gitignored — same treatment as JIRA_TOKEN). local.env stores it with the
# `NAME = value` convention; a value wrapped in a single layer of surrounding
# " or ' quotes is stripped here (a literal quote pair breaks gh's Bearer
# header), so the env file may quote the token for readability. The token is
# NEVER printed to stdout, placed on a command line, or embedded in a URL.
#
# Option A (strategy doc §4) for git push/fetch/pull: the caller passes an
# explicit HTTPS URL (from `remote-url`) as one of the args, and this wrapper
# supplies the PAT via an INLINE, BY-NAME credential helper — the helper
# references $GITHUB_PAT_TOKEN by name, so the value rides in the git
# process's environment, never in argv/the URL. For gh: the token is exported
# as GH_TOKEN for that one `gh` process only.
#
# Exit codes:
#   0 — remote-url printed; verify passed; or the wrapped git/gh exited 0.
#   1 — bad usage, PAT missing/invalid, gh not installed (verify), or the
#       wrapped git/gh exited non-zero (relayed). The relayed exit code is 1
#       even if the child exited with something else, so callers can `|| exit 1`.

set -u

_usage() {
  cat <<'EOF' >&2
github_pat_auth.sh — PAT-scoped git/gh for the jira-sdlc skills.
Usage:
  bash github_pat_auth.sh remote-url          print the HTTPS clone URL derived from origin
  bash github_pat_auth.sh verify              check the PAT is present + GitHub accepts it
  bash github_pat_auth.sh git <git-args...>   run git with the PAT credential helper
  bash github_pat_auth.sh gh  <gh-args...>    run gh with GH_TOKEN=<PAT> for one process
  bash github_pat_auth.sh fetch               git fetch over the PAT-based HTTPS URL into refs/remotes/origin/*
See ../../docs/github/GITHUB-AUTH-STRATEGY.md for the design.
EOF
}

# Same `NAME = value` parser + local-overrides-team precedence as
# statuscheck.sh / jira_acli_login.sh. Keep them in sync; don't add a second.
_cfg() {
  local cfg_dir f v
  cfg_dir=$(git rev-parse --show-toplevel 2>/dev/null || true)
  cfg_dir="${cfg_dir:-$PWD}"
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$cfg_dir/$f" ] || continue
    v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$cfg_dir/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}

# Resolve the PAT. Never echoes the value. Strips whitespace/CRLF + one layer
# of surrounding " or ' (a quote pair in local.env breaks gh's Bearer header).
_pat_value() {
  local raw
  raw=$(_cfg GITHUB_PAT_TOKEN || true)
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | tr -d '\r\n' \
    | sed -E -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//' \
            -e 's/^"(.*)"$/\1/' -e "s/^'(.*)'$/\1/"
}

# Derive the canonical HTTPS clone URL from the human's `origin` remote.
# Accepts SSH forms (git@github.com:OWNER/REPO.git, ssh://git@github.com/...)
# and HTTPS, all normalized to https://github.com/OWNER/REPO.git — repo-generic,
# no hardcoded owner/repo. Errors if origin isn't github.com (the PAT is
# scoped to a github.com repo; a non-github origin means the PAT can't apply).
_remote_https() {
  local url host path
  url=$(git remote get-url origin 2>/dev/null || true)
  [ -n "$url" ] || { printf '%s\n' "github_pat_auth: no `origin` remote in this repo." >&2; return 1; }
  case "$url" in
    git@github.com:*) host=github.com; path=${url#git@github.com:} ;;
    ssh://git@github.com/*) host=github.com; path=${url#ssh://git@github.com/} ;;
    ssh://github.com/*)     host=github.com; path=${url#ssh://github.com/} ;;
    https://github.com/*)   host=github.com; path=${url#https://github.com/} ;;
    http://github.com/*)    host=github.com; path=${url#http://github.com/} ;;
    *) printf '%s\n' "github_pat_auth: origin is '$url' — not a github.com remote; the PAT is scoped to a github.com repo." >&2; return 1 ;;
  esac
  path=${path%.git}
  [ -n "$path" ] || { printf '%s\n' "github_pat_auth: could not parse owner/repo from origin '$url'." >&2; return 1; }
  printf 'https://%s/%s.git' "$host" "$path"
}

# --- subcommands ---------------------------------------------------------

cmd_remote_url() {
  _remote_https
}

cmd_verify() {
  local pat url owner_repo
  pat=$(_pat_value) || {
    printf '%s\n' "github_pat_auth: GITHUB_PAT_TOKEN is unset or empty in jira-sdlc-tools.local.env — set it to the fine-grained PAT value (see ../../docs/github/GITHUB-AUTH-STRATEGY.md §1)." >&2
    return 1; }
  url=$(_remote_https) || return 1
  owner_repo=${url#https://github.com/}
  owner_repo=${owner_repo%.git}
  command -v gh >/dev/null 2>&1 || {
    printf '%s\n' "github_pat_auth: gh is not installed — install it (https://cli.github.com), then rerun." >&2
    return 1; }
  # A repo-scoped GET that REQUIRES authentication — not `/user`, not an
  # anonymous-readable repo endpoint (a public repo returns 200 with no auth,
  # which would mask a dead/missing token). requests the PAT's repo, and only
  # that repo: the real proof the token value + scopes work for this repo.
  if env GH_TOKEN="$pat" gh api "repos/${owner_repo}" >/dev/null 2>&1; then
    printf 'github_pat_auth: OK — GITHUB_PAT_TOKEN authenticated for %s.\n' "$owner_repo"
    return 0
  else
    printf '%s\n' "github_pat_auth: GITHUB_PAT_TOKEN rejected by GitHub for ${owner_repo} (401/403). Check the value in jira-sdlc-tools.local.env (a surrounding quote pair breaks it), that it is the fine-grained PAT (not a classic token), and that it is scoped to ${owner_repo} with Contents + Metadata + Pull requests — see ../../docs/github/GITHUB-AUTH-STRATEGY.md." >&2
    return 1
  fi
}

cmd_git() {
  [ $# -gt 0 ] || { _usage; return 1; }
  local pat
  pat=$(_pat_value) || {
    printf '%s\n' "github_pat_auth: GITHUB_PAT_TOKEN is unset or empty in jira-sdlc-tools.local.env — set it before running git (see ../../docs/github/GITHUB-AUTH-STRATEGY.md)." >&2
    return 1; }
  # Clear any inherited credential helpers first (an empty `-c credential.helper=`
  # resets the list so the human's keychain/gh helper is NOT consulted in
  # addition to ours), then set ours BY NAME — $GITHUB_PAT_TOKEN resolves in
  # the helper's shell from git's environment, never in argv. The caller passes
  # the explicit HTTPS URL (from `remote-url`) as one of the args; we only add
  # auth, never a target. See strategy doc §4 option A.
  env GITHUB_PAT_TOKEN="$pat" git \
    -c credential.helper= \
    -c 'credential.helper=!f(){ echo username=x-access-token; echo "password=$GITHUB_PAT_TOKEN"; }; f' \
    "$@"
}

# The explicit-HTTPS-URL form of `git fetch origin --prune`. Fetching the named
# `origin` remote would route over the human's SSH (strategy doc §3/§4: origin
# stays SSH), so instead fetch the derived HTTPS URL + PAT and map the refspec
# into refs/remotes/origin/*. Two reasons this matters: (a) the skills' prose
# reads `origin/<branch>` tracking refs, so they must stay current without
# touching the human's SSH remote; (b) a push via the explicit URL (cmd_git
# above) does NOT create local refs/remotes/origin/<branch> the way pushing a
# named remote does, so sibling worktrees only see the pushed branch after a
# fetch — this is that fetch. See §4 option A.
cmd_fetch() {
  local pat url
  pat=$(_pat_value) || {
    printf '%s\n' "github_pat_auth: GITHUB_PAT_TOKEN is unset or empty in jira-sdlc-tools.local.env — set it before fetching (see ../../docs/github/GITHUB-AUTH-STRATEGY.md)." >&2
    return 1; }
  url=$(_remote_https) || return 1
  env GITHUB_PAT_TOKEN="$pat" git \
    -c credential.helper= \
    -c 'credential.helper=!f(){ echo username=x-access-token; echo "password=$GITHUB_PAT_TOKEN"; }; f' \
    fetch "$url" '+refs/heads/*:refs/remotes/origin/*' --prune
}

cmd_gh() {
  [ $# -gt 0 ] || { _usage; return 1; }
  local pat
  pat=$(_pat_value) || {
    printf '%s\n' "github_pat_auth: GITHUB_PAT_TOKEN is unset or empty in jira-sdlc-tools.local.env — set it before running gh (see ../../docs/github/GITHUB-AUTH-STRATEGY.md)." >&2
    return 1; }
  # gh honors an inline GH_TOKEN ahead of any stored login and never reads or
  # writes ~/.config/gh/hosts.yml when it's set — the human's gh session is
  # untouched. This wrapper NEVER runs `gh auth login`/`gh auth logout` (§5).
  assert_not_auth "$@"
  env GH_TOKEN="$pat" gh "$@"
}

# Defense-in-depth: `gh auth login` / `gh auth logout` would clobber the
# human's machine-wide gh session (strategy doc §5) — block them at the only
# choke point the skills have for gh, so a skill drift can't slip one through.
assert_not_auth() {
  [ "${1:-}" = auth ] && { case "${2:-}" in
    login|logout) printf '%s\n' "github_pat_auth: refusing 'gh auth $2' — it overwrites the human's gh session machine-wide (strategy doc §5). The agent supplies the PAT per call via GH_TOKEN; it never 'logs in'." >&2; return 1 ;;
  esac; }
  return 0
}

# --- dispatch ------------------------------------------------------------

sub="${1:-}"
[ -n "$sub" ] || { _usage; exit 1; }
shift || true
case "$sub" in
  remote-url) cmd_remote_url "$@" ;;
  verify)     cmd_verify "$@" ;;
  git)        cmd_git "$@" ;;
  gh)         cmd_gh "$@" ;;
  fetch)      cmd_fetch "$@" ;;
  -h|--help|help) _usage; exit 0 ;;
  *) _usage; exit 1 ;;
esac
