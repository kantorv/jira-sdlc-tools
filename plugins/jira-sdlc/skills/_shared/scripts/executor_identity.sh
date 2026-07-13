#!/usr/bin/env bash
# executor_identity.sh — become the Jira "executor" worker identity, then verify
# this issue belongs to it. Run FIRST, before statuscheck.sh, so every Jira write
# in the run (transitions, comments) is attributed to the executor account.
#
# Usage:  bash executor_identity.sh [ISSUE-KEY]
#         ISSUE-KEY defaults to the key derived from the current branch
#         (feature/<KEY>-<slug> / hotfix/<KEY>-<slug>), same derivation as
#         statuscheck.sh.
#
# It does the whole gate itself — the caller needs no logic beyond the exit code:
#   1. resolve the executor identity: JIRA_EXECUTOR_EMAIL/JIRA_EXECUTOR_TOKEN,
#      falling back to JIRA_ACCOUNT_EMAIL/JIRA_TOKEN when unset/empty
#   2. `acli jira auth logout` then log in as it — logout FIRST, because a second
#      `auth login` does NOT overwrite acli's stored credential (it keeps the old
#      one) while `auth status` still reports Authenticated from cache
#   3. read the issue's assignee and compare it to the executor email
#
# Exit 0 — you are the executor and the issue is assigned to you: CONTINUE.
# Exit 1 — anything else: STOP. The reason, and the exact command to fix it, are
#          printed to stderr; relay them to the user verbatim. Do not transition
#          status, branch, commit, comment, or work the issue.
#
# Tokens are never printed: the token goes into acli via a stdin pipe, never onto
# a command line or into the output.
#
# The env-file parser (`cfg`) is copied VERBATIM from statuscheck.sh — same
# `NAME = value` grep, same local-overrides-team precedence. Keep them in sync;
# do not invent a second parser.

set -u

CFG_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
CFG_DIR="${CFG_DIR:-$PWD}"

die() { printf '%s\n' "$*" >&2; exit 1; }

# cfg <NAME> -> value; jira-sdlc-tools.local.env overrides jira-sdlc-tools.env.
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

command -v acli >/dev/null 2>&1 || die "executor_identity: acli is not installed — install it and rerun."

# Network-touching acli calls get a hard cap so a stalled Jira API call can't
# hang the run (same guard as statuscheck.sh). No-op where coreutils timeout is
# missing (stock macOS).
TMOUT_CMD=""
command -v timeout >/dev/null 2>&1 && TMOUT_CMD="timeout 30"

# --- 1. resolve the executor identity ---------------------------------------
EMAIL=$(cfg JIRA_EXECUTOR_EMAIL || true)
FALLBACK=0
if [ -z "$EMAIL" ]; then
  FALLBACK=1
  EMAIL=$(cfg JIRA_ACCOUNT_EMAIL || true)
fi
[ -n "$EMAIL" ] || die "executor_identity: no executor email — set JIRA_EXECUTOR_EMAIL (or JIRA_ACCOUNT_EMAIL) in $CFG_DIR/jira-sdlc-tools.local.env."

# Token is the raw API token VALUE — never a path to a token file (acli reads it
# from stdin and cannot tell the two apart, so a path would be stored as if it
# were the credential and fail later, opaquely).
TOKEN=$(cfg JIRA_EXECUTOR_TOKEN || true)
[ -z "$TOKEN" ] && TOKEN=$(cfg JIRA_TOKEN || true)
[ -n "$TOKEN" ] || die "executor_identity: no token for $EMAIL — set JIRA_EXECUTOR_TOKEN (or JIRA_TOKEN) in $CFG_DIR/jira-sdlc-tools.local.env."

SITE=$(cfg JIRA_ACCOUNT_URL || true)
[ -n "$SITE" ] || die "executor_identity: JIRA_ACCOUNT_URL is unset in $CFG_DIR/jira-sdlc-tools.local.env — needed for 'acli jira auth login --site'."

# --- 2. become the executor (logout FIRST — login does not overwrite) --------
$TMOUT_CMD acli jira auth logout </dev/null >/dev/null 2>&1 || true
if ! printf '%s' "$TOKEN" | $TMOUT_CMD acli jira auth login --site "$SITE" --email "$EMAIL" --token >/dev/null 2>&1; then
  die "executor_identity: 'acli jira auth login' failed for $EMAIL at $SITE — check the token value in $CFG_DIR/jira-sdlc-tools.local.env (it must be the raw API token, not a path to a file). acli is now logged OUT."
fi

# --- 3. is this issue assigned to the executor? ------------------------------
KEY="${1:-}"
if [ -z "$KEY" ]; then
  BR=$(git branch --show-current 2>/dev/null || true)
  BR_TAIL=${BR#*/}
  KEY=$(printf '%s' "$BR_TAIL" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)
  [ -n "$KEY" ] || die "executor_identity: no issue key derivable from branch '${BR:-none}' — expected feature/<KEY>-<slug> or hotfix/<KEY>-<slug>. Run this from the issue's own worktree, or pass the key explicitly."
fi

VIEW=$($TMOUT_CMD acli jira workitem view "$KEY" --json --fields 'assignee' </dev/null 2>&1) \
  || die "executor_identity: cannot read $KEY as $EMAIL — $(printf '%s' "$VIEW" | tail -1). The account may lack access to this project, the token may be invalid, or the Jira API timed out."

ASSIGNEE=$(printf '%s' "$VIEW" | python3 -c '
import sys, json
try:
    a = (json.load(sys.stdin).get("fields") or {}).get("assignee") or {}
except Exception:
    print(""); sys.exit(0)
print(a.get("emailAddress") or "")
' 2>/dev/null || true)

# Compare case-insensitively — Jira treats addresses case-insensitively.
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

# --- pass --------------------------------------------------------------------
printf 'executor_identity: OK — acli is now %s and %s is assigned to it. Continue.\n' "$EMAIL" "$KEY"
if [ "$FALLBACK" = 1 ]; then
  printf 'executor_identity: note — JIRA_EXECUTOR_EMAIL is unset, so the executor is the default account (JIRA_ACCOUNT_EMAIL).\n'
fi
printf 'executor_identity: note — acli auth is machine-global and single-account: every other shell on this machine is now %s until re-logged.\n' "$EMAIL"
