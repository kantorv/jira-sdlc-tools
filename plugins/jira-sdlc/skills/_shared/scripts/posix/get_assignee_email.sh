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
# Config through _jst_config.sh, the one reader: JIRA_EXECUTOR_EMAIL is a key
# of the credential group, so it comes from the project's .jst/ or its profile.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_jst_root.sh"   # jst_root: the project root, even from inside a member submodule

. "$(dirname "${BASH_SOURCE[0]}")/_jst_config.sh"
jst_config_init

if ! jst_cred_resolve; then
  printf '%s\n' "get_assignee_email: $JST_CRED_ERR — $JST_CRED_FIX, then rerun." >&2
  exit 1
fi
EMAIL=$(jst_cred JIRA_EXECUTOR_EMAIL || true)

if [ -z "$EMAIL" ]; then
  printf '%s\n' "get_assignee_email: no assignee email — set JIRA_EXECUTOR_EMAIL in $JST_CRED_WHERE, then rerun." >&2
  exit 1
fi

printf '%s\n' "$EMAIL"
