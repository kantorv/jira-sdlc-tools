#!/usr/bin/env bash
# jira_acli_login.sh — log acli in as a role's Jira identity, idempotently.
#
# Usage:  bash jira_acli_login.sh <role>        # executor | assigner | reviewer
#         source jira_acli_login.sh && jira_acli_login <role>
#
# Each role has an optional dedicated account; all three fall back to the
# default one, so a project that configures none of them keeps working:
#
#   executor  ->  JIRA_EXECUTOR_EMAIL  / JIRA_EXECUTOR_TOKEN
#   assigner  ->  JIRA_ASSIGNER_EMAIL  / JIRA_ASSIGNER_TOKEN
#   reviewer  ->  JIRA_REVIEWER_EMAIL  / JIRA_REVIEWER_TOKEN
#   (any)     ->  JIRA_ACCOUNT_EMAIL   / JIRA_TOKEN          [fallback]
#
# Email and token fall back INDEPENDENTLY: a role that sets only <ROLE>_EMAIL
# (sharing the default token) works, as does one that sets only <ROLE>_TOKEN.
#
# ALWAYS LOGOUT, THEN LOGIN — no idempotency no-op. This script used to peek at
# ~/.config/acli/jira_config.yaml and skip logout+login when the active
# site+email already matched the role. That was unsafe: a revoked or rotated
# token silently survived, because a config-peek only compares identity, not
# validity — and `acli jira auth status` keeps reporting "✓ Authenticated" from
# cache while real calls fail (reference §0 warns exactly this). So we now run
# `acli jira auth logout` and then `auth login` on every call, unconditionally.
# The logout is mandatory, not hygiene: a second `auth login` does NOT overwrite
# an existing stored credential — acli keeps the old one — so without the logout
# a stale credential would never be replaced. Re-login is cheap insurance
# against a silently-dead token; the extra ~seconds are worth a solid login.
# (`acli jira auth status` is still NOT used here: ~20s per call, cache-only.)
#
# TIMEOUTS: login is capped at 180s and logout at 60s (aligned with the .ps1
# twin). Login gets the longer cap because `acli jira auth login` can take 2-3
# minutes against a real Jira instance; now that login is always-on (no no-op
# fast path to skip it), the old 60s login cap would fail on a slow instance.
#
# ⚠️ acli's credential store is machine-global and single-account: switching
# roles switches the active account for every other shell on this machine.
#
# Tokens: the raw API token VALUE, never a path to a file. Piped to acli on
# stdin — never printed, never on a command line.
#
# Exit 0 — acli is now logged in as <role>'s identity.
# Exit 1 — anything else, with the reason on stderr.

set -u

jira_acli_login() {
  local role="${1:-}"
  local prefix cfg_dir email token site tmout_login tmout_logout

  case "$role" in
    executor) prefix=JIRA_EXECUTOR ;;
    assigner) prefix=JIRA_ASSIGNER ;;
    reviewer) prefix=JIRA_REVIEWER ;;
    *) printf '%s\n' "jira_acli_login: role must be executor|assigner|reviewer (got '${role:-<none>}')." >&2; return 1 ;;
  esac

  command -v acli >/dev/null 2>&1 || {
    printf '%s\n' "jira_acli_login: acli is not installed." >&2; return 1; }

  cfg_dir=$(git rev-parse --show-toplevel 2>/dev/null || true)
  cfg_dir="${cfg_dir:-$PWD}"

  # Same `NAME = value` parser and local-overrides-team precedence as
  # statuscheck.sh. Keep them in sync; don't invent a second parser.
  _cfg() {
    local f v
    for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
      [ -f "$cfg_dir/$f" ] || continue
      v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$cfg_dir/$f" 2>/dev/null \
          | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
      if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    done
    return 1
  }

  email=$(_cfg "${prefix}_EMAIL" || true)
  [ -z "$email" ] && email=$(_cfg JIRA_ACCOUNT_EMAIL || true)
  [ -n "$email" ] || {
    printf '%s\n' "jira_acli_login: no email for role '$role' — set ${prefix}_EMAIL (or JIRA_ACCOUNT_EMAIL) in $cfg_dir/jira-sdlc-tools.local.env." >&2
    return 1; }

  site=$(_cfg JIRA_ACCOUNT_URL || true)
  [ -n "$site" ] || {
    printf '%s\n' "jira_acli_login: JIRA_ACCOUNT_URL is unset in $cfg_dir/jira-sdlc-tools.local.env." >&2
    return 1; }

  # No idempotency short-circuit: we ALWAYS logout+login (see header). A
  # config-peek would only confirm identity, never token validity, so a stale
  # or revoked token would survive it — the exact failure this script now
  # prevents by re-logging in unconditionally.

  token=$(_cfg "${prefix}_TOKEN" || true)
  [ -z "$token" ] && token=$(_cfg JIRA_TOKEN || true)
  [ -n "$token" ] || {
    printf '%s\n' "jira_acli_login: no token for role '$role' ($email) — set ${prefix}_TOKEN (or JIRA_TOKEN) in $cfg_dir/jira-sdlc-tools.local.env. It must be the raw API token value, not a path to a file." >&2
    unset -f _cfg; return 1; }

  # Cap the network calls so a stalled Jira API can't hang a run (as statuscheck.sh
  # does). Aligned with the .ps1 twin: login 180s (acli login can take 2-3 min on a
  # real instance, and it always runs now), logout 60s. No-op where coreutils
  # timeout is missing (stock macOS).
  tmout_login=""
  tmout_logout=""
  if command -v timeout >/dev/null 2>&1; then
    tmout_login="timeout 180"
    tmout_logout="timeout 60"
  fi

  # logout FIRST — login does not overwrite an existing credential (see header).
  $tmout_logout acli jira auth logout </dev/null >/dev/null 2>&1 || true

  if ! printf '%s' "$token" | $tmout_login acli jira auth login --site "$site" --email "$email" --token >/dev/null 2>&1; then
    printf '%s\n' "jira_acli_login: 'acli jira auth login' failed for $role ($email) at $site — check ${prefix}_TOKEN / JIRA_TOKEN in $cfg_dir/jira-sdlc-tools.local.env (raw API token value, not a path). acli is now logged OUT." >&2
    unset -f _cfg; return 1
  fi

  printf 'jira_acli_login: acli is now %s (%s).\n' "$role" "$email"
  unset -f _cfg
  return 0
}

# Executed directly (not sourced) → run it with the CLI argument.
# ${BASH_SOURCE[0]} != $0 when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  jira_acli_login "${1:-}"
fi
