#!/usr/bin/env bash
# get_assignee_email.sh — print the email every issue should be assigned to.
#
# JIRA_EXECUTOR_EMAIL — required, with no fallback: auth is role-scoped, so the
# executor's own address is the only right answer here.
#
# Exit 0 — the email is on stdout.
# Exit 1 — it isn't set; the reason is on stderr. The caller stops: an issue
#          nobody owns is what this whole mechanism exists to prevent.
#
# No token is resolved or printed here — assigning only needs the address.
# (Authenticating as a role is per-request in jira.sh --role <role>; the
# executor's ownership gate is check_assignee.sh.)
#
# The env-file parser (`cfg`) is copied VERBATIM from statuscheck.sh — same
# `NAME = value` grep, same local-overrides-team precedence. Keep them in sync.

set -u

CFG_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
CFG_DIR="${CFG_DIR:-$PWD}/.jst"

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

EMAIL=$(cfg JIRA_EXECUTOR_EMAIL || true)

if [ -z "$EMAIL" ]; then
  printf '%s\n' "get_assignee_email: no assignee email — set JIRA_EXECUTOR_EMAIL in $CFG_DIR/jira-sdlc-tools.local.env, then rerun." >&2
  exit 1
fi

printf '%s\n' "$EMAIL"
