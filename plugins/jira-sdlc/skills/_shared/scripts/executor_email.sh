#!/usr/bin/env bash
# executor_email.sh — print the Jira "executor" worker email, nothing else.
#
# The executor identity is JIRA_EXECUTOR_EMAIL, falling back to
# JIRA_ACCOUNT_EMAIL when it is unset or empty. jira-task-assigner uses this to
# assign every issue it creates (`--assignee "$(bash executor_email.sh)"`); it
# never needs the token, so no token is ever resolved or printed here.
#
# The executor's own re-login + ownership gate is executor_identity.sh.
#
# Exit 0 — the email is on stdout.
# Exit 1 — no email configured; the reason is on stderr.
#
# The env-file parser (`cfg`) is copied VERBATIM from statuscheck.sh — same
# `NAME = value` grep, same local-overrides-team precedence. Keep them in sync.

set -u

CFG_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
CFG_DIR="${CFG_DIR:-$PWD}"

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
[ -z "$EMAIL" ] && EMAIL=$(cfg JIRA_ACCOUNT_EMAIL || true)

if [ -z "$EMAIL" ]; then
  printf '%s\n' "executor_email: no executor email — set JIRA_EXECUTOR_EMAIL (or JIRA_ACCOUNT_EMAIL) in $CFG_DIR/jira-sdlc-tools.local.env." >&2
  exit 1
fi

printf '%s\n' "$EMAIL"
