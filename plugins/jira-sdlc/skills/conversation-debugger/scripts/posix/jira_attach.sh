#!/usr/bin/env bash
# jira_attach.sh [--dry-run] <ISSUE-KEY> <file> [<file> ...]
#
# Upload one or more files to a Jira issue as attachments. --dry-run reports the
# upload/skip decision for each file without POSTing anything.
#
# `acli jira workitem attachment` only supports list/delete — it can't upload —
# so this goes through Jira Cloud's REST API on the api.atlassian.com gateway
# with the executor's basic auth (email:token), the same identity
# jira_acli_login.sh logs in as. (The keyring acli uses isn't reusable for raw
# REST, so we read the credentials straight from the env files here.)
#
# Reads, with the same `NAME = value` parser + local-overrides-team precedence
# as the other scripts: JIRA_ACCOUNT_URL and JIRA_EXECUTOR_EMAIL /
# JIRA_EXECUTOR_TOKEN (each falling back to JIRA_ACCOUNT_EMAIL / JIRA_TOKEN).
#
# Exit 0 if every file uploaded; exit 1 on any usage/auth/upload failure.

set -u

DRYRUN=""
[ "${1:-}" = "--dry-run" ] && { DRYRUN=1; shift; }
KEY="${1:-}"; shift 2>/dev/null || true
{ [ -n "$KEY" ] && [ "$#" -gt 0 ]; } || { echo "usage: jira_attach.sh [--dry-run] <ISSUE-KEY> <file> [<file> ...]" >&2; exit 1; }

cfg_dir=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")
_cfg() {
  local f v
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$cfg_dir/$f" ] || continue
    v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$cfg_dir/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}

SITE=$(_cfg JIRA_ACCOUNT_URL || true)
EMAIL=$(_cfg JIRA_EXECUTOR_EMAIL || true); [ -z "$EMAIL" ] && EMAIL=$(_cfg JIRA_ACCOUNT_EMAIL || true)
TOKEN=$(_cfg JIRA_EXECUTOR_TOKEN || true); [ -z "$TOKEN" ] && TOKEN=$(_cfg JIRA_TOKEN || true)
{ [ -n "$SITE" ] && [ -n "$EMAIL" ] && [ -n "$TOKEN" ]; } || {
  echo "jira_attach: missing JIRA_ACCOUNT_URL / executor email / token in $cfg_dir/jira-sdlc-tools.local.env" >&2; exit 1; }

# JIRA_ACCOUNT_URL is stored WITHOUT a scheme (and maybe a trailing slash) —
# normalize before building URLs, or tenant_info 404s.
SITE="${SITE#http://}"; SITE="${SITE#https://}"; SITE="${SITE%/}"

# Cloud id for the api.atlassian.com gateway path — the tenant_info edge
# endpoint redirects, so follow with -L.
CLOUD=$(curl -sL "https://$SITE/_edge/tenant_info" \
  | python3 -c 'import sys,json;print((json.load(sys.stdin) or {}).get("cloudId",""))' 2>/dev/null)
[ -n "$CLOUD" ] || { echo "jira_attach: could not resolve cloudId from https://$SITE/_edge/tenant_info" >&2; exit 1; }

ISSUE_API="https://api.atlassian.com/ex/jira/$CLOUD/rest/api/3/issue/$KEY"

# Idempotent by filename: fetch the issue's current attachments so a re-run
# uploads only what's missing (Jira does NOT dedupe — the same name uploaded
# twice yields two copies). We match on basename, which is what the upload sets
# as the attachment's filename. A failed listing is fatal rather than silently
# risking duplicates.
EXISTING=$(curl -s -u "$EMAIL:$TOKEN" -H "Accept: application/json" \
  "$ISSUE_API?fields=attachment" \
  | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(3)
for a in (d.get("fields") or {}).get("attachment") or []:
    n=a.get("filename")
    if n: print(n)' 2>/dev/null) || {
  echo "jira_attach: could not read existing attachments on $KEY — aborting to avoid duplicates" >&2; exit 1; }

is_attached() {  # exact basename already on the issue?
  local name="$1" line
  while IFS= read -r line; do [ "$line" = "$name" ] && return 0; done <<EOF
$EXISTING
EOF
  return 1
}

rc=0; n_up=0; n_skip=0
for f in "$@"; do
  [ -f "$f" ] || { echo "jira_attach: no such file: $f" >&2; rc=1; continue; }
  base=$(basename "$f")
  if is_attached "$base"; then
    echo "already attached, skipped: $base"
    n_skip=$((n_skip + 1))
    continue
  fi
  if [ -n "$DRYRUN" ]; then
    echo "would upload: $base → $KEY"
    n_up=$((n_up + 1))
    continue
  fi
  out=$(curl -s -w '\n%{http_code}' -u "$EMAIL:$TOKEN" \
    -H "X-Atlassian-Token: no-check" -F "file=@$f" "$ISSUE_API/attachments")
  code=$(printf '%s' "$out" | tail -1)
  case "$code" in
    200|201) echo "attached: $base → $KEY"; n_up=$((n_up + 1)) ;;
    *) echo "jira_attach: FAILED (HTTP $code) for $f" >&2
       printf '%s\n' "$out" | sed '$d' >&2
       rc=1 ;;
  esac
done
verb="uploaded"; [ -n "$DRYRUN" ] && verb="would upload"
echo "jira_attach: $verb $n_up, $n_skip already present$([ $rc -ne 0 ] && echo ', some failed')"
exit $rc
