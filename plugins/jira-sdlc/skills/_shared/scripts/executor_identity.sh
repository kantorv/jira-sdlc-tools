#!/usr/bin/env bash
# executor_identity.sh — become the executor, then verify this issue is theirs.
#
# Run FIRST, before statuscheck.sh, so every Jira write in the run (transitions,
# comments) is attributed to the executor account rather than to whoever happened
# to be logged in.
#
# Usage:  bash executor_identity.sh [ISSUE-KEY]
#         ISSUE-KEY defaults to the key derived from the current branch
#         (feature/<KEY>-<slug> / hotfix/<KEY>-<slug>), as statuscheck.sh does.
#
# The login half is jira_acli_login.sh (shared with the assigner and reviewer,
# and idempotent — a no-op when acli is already the executor). What's left here
# is the part only the executor needs: the ownership gate.
#
# Exit 0 — you are the executor and the issue is assigned to you: CONTINUE.
# Exit 1 — anything else: STOP. The reason, and the exact command to fix it, are
#          on stderr; relay them verbatim. Do not transition status, branch,
#          commit, comment, or work the issue.

set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=jira_acli_login.sh
. "$HERE/jira_acli_login.sh"

die() { printf '%s\n' "$*" >&2; exit 1; }

TMOUT_CMD=""
command -v timeout >/dev/null 2>&1 && TMOUT_CMD="timeout 30"

# --- 1. be the executor (idempotent; resolves the identity + fallbacks) ------
jira_acli_login executor || exit 1

# The email jira_acli_login just logged in as — read back from acli's own config
# so the gate compares against the identity that is actually active, not a second
# resolution of the env files.
EMAIL=$(grep -E '^[[:space:]]*email:[[:space:]]*' "$HOME/.config/acli/jira_config.yaml" 2>/dev/null \
        | head -1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//')
[ -n "$EMAIL" ] || die "executor_identity: acli reports no active account after login — cannot verify ownership."

SITE=$(grep -E '^[[:space:]]*-?[[:space:]]*site:[[:space:]]*' "$HOME/.config/acli/jira_config.yaml" 2>/dev/null \
       | head -1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//')

# --- 2. which issue? --------------------------------------------------------
KEY="${1:-}"
if [ -z "$KEY" ]; then
  BR=$(git branch --show-current 2>/dev/null || true)
  BR_TAIL=${BR#*/}
  KEY=$(printf '%s' "$BR_TAIL" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)
  [ -n "$KEY" ] || die "executor_identity: no issue key derivable from branch '${BR:-none}' — expected feature/<KEY>-<slug> or hotfix/<KEY>-<slug>. Run this from the issue's own worktree, or pass the key explicitly."
fi

# --- 3. is it assigned to the executor? -------------------------------------
VIEW=$($TMOUT_CMD acli jira workitem view "$KEY" --json --fields 'assignee' </dev/null 2>&1) \
  || die "executor_identity: cannot read $KEY as $EMAIL — $(printf '%s' "$VIEW" | tail -1). The account may lack access to this project, or the Jira API timed out."

ASSIGNEE=$(printf '%s' "$VIEW" | python3 -c '
import sys, json
try:
    a = (json.load(sys.stdin).get("fields") or {}).get("assignee") or {}
except Exception:
    print(""); sys.exit(0)
print(a.get("emailAddress") or "")
' 2>/dev/null || true)

lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

if [ -z "$ASSIGNEE" ]; then
  die "executor_identity: $KEY is NOT assigned to the executor ($EMAIL) — it is unassigned (or its assignee's email is hidden by site privacy settings). STOP: do not transition, branch, commit, or comment.
Assign it and rerun:
  acli jira workitem assign --key $KEY --assignee \"$EMAIL\" --yes
Or assign it by hand: https://$SITE/browse/$KEY"
fi

if [ "$(lc "$ASSIGNEE")" != "$(lc "$EMAIL")" ]; then
  die "executor_identity: $KEY is assigned to $ASSIGNEE, not to the executor ($EMAIL). STOP: do not transition, branch, commit, or comment.
Reassign it and rerun:
  acli jira workitem assign --key $KEY --assignee \"$EMAIL\" --yes
Or reassign by hand: https://$SITE/browse/$KEY"
fi

printf 'executor_identity: OK — acli is %s and %s is assigned to it. Continue.\n' "$EMAIL" "$KEY"
