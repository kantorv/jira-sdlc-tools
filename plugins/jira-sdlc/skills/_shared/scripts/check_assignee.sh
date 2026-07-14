#!/usr/bin/env bash
# check_assignee.sh — is this issue assigned to the account acli is logged in as?
#
# Usage:  bash check_assignee.sh [ISSUE-KEY]
#         ISSUE-KEY defaults to the key derived from the current branch
#         (feature/<KEY>-<slug> / hotfix/<KEY>-<slug>), as statuscheck.sh does.
#
# Run it AFTER `jira_acli_login.sh <role>` — it checks the issue against whoever
# acli is currently logged in as, so the login is what decides which identity is
# being demanded.
#
# Anything other than "assigned to me" is a halt: unassigned, assigned to someone
# else, an unreadable issue, a hidden assignee email. There is no partial pass.
#
# Exit 0 — the issue is assigned to the logged-in account: CONTINUE.
# Exit 1 — everything else: STOP. The reason, and the command that fixes it, are
#          on stderr; relay them verbatim. Do not transition status, branch,
#          commit, comment, or work the issue.

set -u

die() { printf '%s\n' "$*" >&2; exit 1; }

command -v acli >/dev/null 2>&1 || die "check_assignee: acli is not installed."

TMOUT_CMD=""
command -v timeout >/dev/null 2>&1 && TMOUT_CMD="timeout 30"

# --- who is acli logged in as? ----------------------------------------------
# acli records the active profile here on login and clears it on logout, so this
# is an instant local read — and it reflects the identity that will actually make
# the Jira calls, rather than a second guess from the env files.
ACLI_CFG="$HOME/.config/acli/jira_config.yaml"
[ -f "$ACLI_CFG" ] || die "check_assignee: acli is not logged in (no $ACLI_CFG) — run jira_acli_login.sh <role> first."

_yaml1() {  # first `key: value` from acli's config
  grep -E "^[[:space:]]*-?[[:space:]]*$1:[[:space:]]*" "$ACLI_CFG" 2>/dev/null \
    | head -1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//'
}

ME=$(_yaml1 email)
# accountId is the identifier that actually works. Jira only exposes
# `emailAddress` on the assignee object for YOUR OWN account — for anyone else
# the field is absent entirely (only accountId + displayName come back). So an
# email comparison can confirm a match but can never distinguish "assigned to
# someone else" from "unassigned". acli records our own account_id on login, and
# every assignee object carries accountId, so compare on that.
MY_ID=$(_yaml1 account_id)
[ -n "$MY_ID" ] || die "check_assignee: acli reports no active account — run jira_acli_login.sh <role> first."

SITE=$(_yaml1 site)

# --- which issue? ------------------------------------------------------------
KEY="${1:-}"
if [ -z "$KEY" ]; then
  BR=$(git branch --show-current 2>/dev/null || true)
  BR_TAIL=${BR#*/}
  KEY=$(printf '%s' "$BR_TAIL" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)
  [ -n "$KEY" ] || die "check_assignee: no issue key derivable from branch '${BR:-none}' — expected feature/<KEY>-<slug> or hotfix/<KEY>-<slug>. Run from the issue's worktree, or pass the key."
fi

# --- assigned to me? ---------------------------------------------------------
VIEW=$($TMOUT_CMD acli jira workitem view "$KEY" --json --fields 'assignee' </dev/null 2>&1) \
  || die "check_assignee: cannot read $KEY as $ME — $(printf '%s' "$VIEW" | tail -1). The account may lack access to this project, or the Jira API timed out."

# -> "<accountId>|<displayName>", or empty when unassigned.
ASSIGNEE=$(printf '%s' "$VIEW" | python3 -c '
import sys, json
try:
    a = (json.load(sys.stdin).get("fields") or {}).get("assignee") or {}
except Exception:
    print(""); sys.exit(0)
if a.get("accountId"):
    print("%s|%s" % (a["accountId"], a.get("displayName") or "unknown"))
' 2>/dev/null || true)

FIXUP="Assign it and rerun:
  acli jira workitem assign --key $KEY --assignee \"$ME\" --yes
Or assign it by hand: https://$SITE/browse/$KEY"

if [ -z "$ASSIGNEE" ]; then
  die "check_assignee: $KEY is UNASSIGNED — it must be assigned to $ME. STOP: do not transition, branch, commit, or comment.
$FIXUP"
fi

THEIR_ID=${ASSIGNEE%%|*}
THEIR_NAME=${ASSIGNEE#*|}

if [ "$THEIR_ID" != "$MY_ID" ]; then
  die "check_assignee: $KEY is assigned to someone else — $THEIR_NAME, not $ME. STOP: do not transition, branch, commit, or comment.
$FIXUP"
fi

printf 'check_assignee: OK — %s is assigned to %s. Continue.\n' "$KEY" "$ME"
