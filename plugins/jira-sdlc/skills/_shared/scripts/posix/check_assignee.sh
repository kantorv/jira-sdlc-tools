#!/usr/bin/env bash
# check_assignee.sh — is this issue assigned to the given role's account?
#
# Usage:  bash check_assignee.sh [--role <role>] [ISSUE-KEY]
#         --role   executor|assigner|reviewer. Defaults to executor — its sole
#                  caller is the executor's ownership gate — and is also read
#                  from $JIRA_ROLE when the flag is absent.
#         ISSUE-KEY defaults to the key derived from the current branch
#         (feature/<KEY>-<slug> / hotfix/<KEY>-<slug>), as statuscheck.sh does.
#
# Identity comes from `jira.sh --role <role> whoami` (GET /myself) — per-request
# Basic auth, no stored login, no config file to parse. Because the account is
# chosen by --role rather than by switching a stored profile, there is no
# multi-profile state to fall out of sync (JST-146): "who am I" is now the
# token in hand.
#
# Anything other than "assigned to me" is a halt: unassigned, assigned to someone
# else, an unreadable issue. There is no partial pass.
#
# Exit 0 — the issue is assigned to the role's account: CONTINUE.
# Exit 1 — everything else: STOP. The reason, and the command that fixes it, are
#          on stderr; relay them verbatim. Do not transition status, branch,
#          commit, comment, or work the issue.

set -u

die() { printf '%s\n' "$*" >&2; exit 1; }

# --- args: optional --role, optional ISSUE-KEY -------------------------------
ROLE="${JIRA_ROLE:-}"
KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role)   ROLE="${2:-}"; shift 2 ;;
    --role=*) ROLE="${1#--role=}"; shift ;;
    *)        KEY="$1"; shift ;;
  esac
done
ROLE="${ROLE:-executor}"

command -v jq >/dev/null 2>&1 || die "check_assignee: jq is required but not installed."
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JIRA_SH="$SCRIPT_DIR/jira.sh"

# --- config (site for the fixup URL) -----------------------------------------
CFG_DIR=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")/.jst
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
SITE=$(cfg JIRA_ACCOUNT_URL || true); SITE="${SITE#*://}"

# --- who is this role? (GET /myself via jira.sh) -----------------------------
# accountId is the identifier that actually works: Jira exposes `emailAddress` on
# an assignee only for YOUR OWN account, so an email comparison can confirm a
# match but never distinguish "assigned to someone else" from "unassigned".
# Every assignee object carries accountId, so compare on that.
WHOAMI=$(bash "$JIRA_SH" --role "$ROLE" whoami 2>/dev/null) \
  || die "check_assignee: could not authenticate as role '$ROLE' — check JIRA_$(printf '%s' "$ROLE" | tr '[:lower:]' '[:upper:]')_EMAIL + _TOKEN in .jst/jira-sdlc-tools.local.env."
MY_ID=$(printf '%s' "$WHOAMI" | jq -r '.accountId // empty')
ME=$(printf '%s' "$WHOAMI"   | jq -r '.emailAddress // .displayName // empty')
[ -n "$MY_ID" ] || die "check_assignee: jira whoami returned no accountId for role '$ROLE'."
[ -n "$ME" ] || ME="role '$ROLE'"

# --- which issue? ------------------------------------------------------------
if [ -z "$KEY" ]; then
  BR=$(git branch --show-current 2>/dev/null || true)
  BR_TAIL=${BR#*/}
  KEY=$(printf '%s' "$BR_TAIL" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)
  [ -n "$KEY" ] || die "check_assignee: no issue key derivable from branch '${BR:-none}' — expected feature/<KEY>-<slug> or hotfix/<KEY>-<slug>. Run from the issue's worktree, or pass the key."
fi

# --- assigned to me? ---------------------------------------------------------
VIEW=$(bash "$JIRA_SH" --role "$ROLE" issue view "$KEY" --fields assignee 2>&1) \
  || die "check_assignee: cannot read $KEY as $ME — $(printf '%s' "$VIEW" | tail -1). The account may lack access to this project, or the Jira API timed out."

# -> "<accountId>|<displayName>", or empty when unassigned. With --fields
# assignee the only accountId/displayName in the payload is the assignee's.
ASSIGNEE=$(printf '%s' "$VIEW" | jq -r '
  (.fields.assignee // {})
  | (if .accountId then "\(.accountId)|\(.displayName // "unknown")" else empty end)
' 2>/dev/null || true)

FIXUP="Assign it and rerun:
  jira issue assign $KEY --to \"$ME\"   (--role $ROLE; jira.sh on POSIX / jira.ps1 on Windows)
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
