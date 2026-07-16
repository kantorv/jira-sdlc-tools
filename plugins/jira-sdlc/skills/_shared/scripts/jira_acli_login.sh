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
# IDEMPOTENT: acli records the active account in ~/.config/acli/jira_config.yaml.
# If it already matches the role's site+email, this is a no-op and returns 0
# without touching the network — so every skill can call it unconditionally on
# every run. (`acli jira auth status` is NOT used for this: it takes ~20s per
# call, and it reports from cache anyway.)
#
# Otherwise it runs `acli jira auth logout` and then logs in. The logout is
# mandatory, not hygiene: a second `auth login` does NOT overwrite an existing
# stored credential — acli keeps the old one — while `auth status` still says
# "✓ Authenticated" from cache, so the old account silently stays active.
#
# ⚠️ acli's credential store is machine-global and single-account: switching
# roles switches the active account for every other shell on this machine.
#
# Tokens: the raw API token VALUE, never a path to a file. Piped to acli on
# stdin — never printed, never on a command line.
#
# Exit 0 — acli is now (or already was) logged in as <role>'s identity.
# Exit 1 — anything else, with the reason on stderr.

set -u

jira_acli_login() {
  local role="${1:-}"
  local prefix cfg_dir email token site active_email active_site tmout

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

  # --- idempotency: already this identity? then do nothing. -----------------
  # acli records the active account here as `current_profile`, and on logout it
  # blanks `current_profile` but LEAVES the profile entry (site/email) behind. So
  # the profile's email/site is NOT proof of being logged in — only a non-empty
  # `current_profile` is. Gate on it, or a logged-out stale profile reads as
  # "already logged in" and the script skips the real login while acli stays
  # unauthorized.
  if [ -f "$HOME/.config/acli/jira_config.yaml" ]; then
    active_profile=$(grep -E '^[[:space:]]*current_profile:[[:space:]]*' "$HOME/.config/acli/jira_config.yaml" 2>/dev/null \
                     | head -1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
    active_email=$(grep -E '^[[:space:]]*email:[[:space:]]*' "$HOME/.config/acli/jira_config.yaml" 2>/dev/null \
                   | head -1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//')
    active_site=$(grep -E '^[[:space:]]*-?[[:space:]]*site:[[:space:]]*' "$HOME/.config/acli/jira_config.yaml" 2>/dev/null \
                  | head -1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$active_profile" ] && [ -n "$active_email" ] \
       && [ "$(printf '%s' "$active_email" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$email" | tr '[:upper:]' '[:lower:]')" ] \
       && [ "$(printf '%s' "$active_site"  | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$site"  | tr '[:upper:]' '[:lower:]')" ]; then
      printf 'jira_acli_login: already %s (%s) — no re-login needed.\n' "$role" "$email"
      unset -f _cfg
      return 0
    fi
  fi

  token=$(_cfg "${prefix}_TOKEN" || true)
  [ -z "$token" ] && token=$(_cfg JIRA_TOKEN || true)
  [ -n "$token" ] || {
    printf '%s\n' "jira_acli_login: no token for role '$role' ($email) — set ${prefix}_TOKEN (or JIRA_TOKEN) in $cfg_dir/jira-sdlc-tools.local.env. It must be the raw API token value, not a path to a file." >&2
    unset -f _cfg; return 1; }

  # Cap the network calls so a stalled Jira API can't hang a run (as statuscheck.sh does).
  tmout=""
  command -v timeout >/dev/null 2>&1 && tmout="timeout 60"

  # logout FIRST — login does not overwrite an existing credential (see header).
  $tmout acli jira auth logout </dev/null >/dev/null 2>&1 || true

  if ! printf '%s' "$token" | $tmout acli jira auth login --site "$site" --email "$email" --token >/dev/null 2>&1; then
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
