#!/usr/bin/env bash
# jira.sh — direct Jira Cloud REST v3 client; the acli replacement.
#
# Design & rationale:  ../../../../docs/rest-client-design.md
# Live-verified call shapes + status codes:  ../../../../docs/acli-to-rest-api-migration.md
#
# Four layers (see the design doc):
#   L1 config    — env files, --role→credential, cloud-id (cached), ADF encode, email→accountId
#   L2 transport — _request(): the single curl choke point; HTTP status → semantic exit code
#   L3 ops       — issue_view / issue_create / transition_to / …  (extend HERE)
#   L4 dispatch  — arg parsing + subcommand routing (bottom of file)
#
# Auth is per-request Basic (no login, no stored credential, no global state):
# --role picks which <ROLE>_EMAIL/<ROLE>_TOKEN pair the call uses, falling back
# to JIRA_ACCOUNT_EMAIL / JIRA_TOKEN. This replaces the whole jira_acli_login layer.
#
# Output contract:  read ops print raw JSON on stdout (caller jq's it); write ops
# print nothing on success (REST returns 204, empty). Errors → stderr.
# Exit codes:  0 ok · 1 transport · 2 usage · 3 auth(401) · 4 not-found/perm(404)
#              · 5 validation(400) · 6 forbidden(403) · 7 unexpected · 8 no such transition
#
# PowerShell twin: ../win/jira.ps1 (contract pair — same args/output/exit codes;
# edit one, edit the other). Live smoke tests: jira.test.sh / ../win/jira.test.ps1.

set -u

EX_OK=0; EX_ERR=1; EX_USAGE=2; EX_AUTH=3; EX_NOTFOUND=4
EX_VALIDATION=5; EX_FORBIDDEN=6; EX_UNEXPECTED=7; EX_NOTRANSITION=8

# Globals populated by _ready (L1).
_ROLE="${JIRA_ROLE:-}"; _CRED=""; _SITE=""; _CLOUD_ID=""; _BASE=""; RESP_FILE=""

die() { local code=$1; shift; printf 'jira: %s\n' "$*" >&2; exit "$code"; }

usage() {
  cat >&2 <<'EOF'
usage: jira.sh [--role executor|assigner|reviewer] <command>

  whoami                                         who this credential authenticates as
  project exists  <KEY>                          is the project visible to this account?
  issue view      <KEY> [--fields a,b,c]         get an issue (raw JSON on stdout)
  issue create    --project K --type T --summary S
                  [--parent K] [--assignee email|@me]
                  [--desc-file FILE | --adf-file FILE]   -> prints the new key
  issue transition <KEY> --to "In Review"        transition by target status name
  issue assign     <KEY> (--to email|@me | --remove)
  issue comment add  <KEY> (--body-file FILE | --adf-file FILE)
  issue comment list <KEY>                       raw JSON on stdout
  issue delete     <KEY> [--with-subtasks]
  raw <METHOD> </PATH> [--data-file FILE]        escape hatch; PATH is under /rest/api/3 (e.g. /myself)

--desc-file/--body-file take PLAIN TEXT (one ADF paragraph per non-blank line).
--adf-file takes a bare ADF "doc" object (rich formatting you built yourself).
EOF
  exit "$EX_USAGE"
}

# ─── Layer 1: config resolution ─────────────────────────────────────────────

# Same `NAME = value` parser + local-overrides-team precedence as
# jira_acli_login.sh / statuscheck.sh. Keep in sync; don't invent a second one.
_cfg_dir=""
_cfg() {
  local f v
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$_cfg_dir/$f" ] || continue
    v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$_cfg_dir/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}

_urlenc() { jq -rn --arg v "$1" '$v|@uri'; }

# Resolve the <role> credential pair. Email and token fall back to the default
# account INDEPENDENTLY (a role may set only its email, sharing the default token).
_resolve_cred() {
  local prefix="" email="" token=""
  case "$_ROLE" in
    executor) prefix=JIRA_EXECUTOR ;;
    assigner) prefix=JIRA_ASSIGNER ;;
    reviewer) prefix=JIRA_REVIEWER ;;
    "")       prefix="" ;;
    *) die "$EX_USAGE" "role must be executor|assigner|reviewer (got '$_ROLE')" ;;
  esac
  if [ -n "$prefix" ]; then
    email=$(_cfg "${prefix}_EMAIL" || true)
    token=$(_cfg "${prefix}_TOKEN" || true)
  fi
  [ -z "$email" ] && email=$(_cfg JIRA_ACCOUNT_EMAIL || true)
  [ -z "$token" ] && token=$(_cfg JIRA_TOKEN || true)
  [ -n "$email" ] || die "$EX_ERR" "no email for role '${_ROLE:-default}' — set ${prefix:-JIRA_ACCOUNT}_EMAIL in jira-sdlc-tools.local.env."
  [ -n "$token" ] || die "$EX_ERR" "no token for role '${_ROLE:-default}' — set ${prefix:-JIRA}_TOKEN in jira-sdlc-tools.local.env (raw API token value, not a path)."
  _CRED="$email:$token"
}

# Cloud id never changes per site but _edge/tenant_info is a network hop, so cache it.
_resolve_cloud_id() {
  local dir file
  dir="${XDG_CACHE_HOME:-$HOME/.cache}/jira-sdlc"
  file="$dir/$_SITE.cloudid"
  if [ -s "$file" ]; then _CLOUD_ID=$(cat "$file"); return 0; fi
  _CLOUD_ID=$(curl -fsSL --max-time 30 "https://$_SITE/_edge/tenant_info" 2>/dev/null | jq -r '.cloudId // empty') \
    || die "$EX_ERR" "could not reach https://$_SITE/_edge/tenant_info to resolve the cloud id."
  [ -n "$_CLOUD_ID" ] || die "$EX_ERR" "cloud id not found for site '$_SITE'."
  mkdir -p "$dir" 2>/dev/null && printf '%s' "$_CLOUD_ID" > "$file" 2>/dev/null || true
}

_ready() {
  command -v curl >/dev/null 2>&1 || die "$EX_ERR" "curl is required but not installed."
  command -v jq   >/dev/null 2>&1 || die "$EX_ERR" "jq is required but not installed."
  _cfg_dir=$(git rev-parse --show-toplevel 2>/dev/null || true); _cfg_dir="${_cfg_dir:-$PWD}"
  _SITE=$(_cfg JIRA_ACCOUNT_URL || true); _SITE="${_SITE#*://}"
  [ -n "$_SITE" ] || die "$EX_ERR" "JIRA_ACCOUNT_URL is unset in jira-sdlc-tools.local.env."
  _resolve_cred
  _resolve_cloud_id
  _BASE="https://api.atlassian.com/ex/jira/$_CLOUD_ID/rest/api/3"
  RESP_FILE=$(mktemp "${TMPDIR:-/tmp}/jira-resp.XXXXXX"); trap 'rm -f "$RESP_FILE"' EXIT
}

# Plain-text FILE → a bare ADF "doc" object on stdout (one paragraph per non-blank line).
_text_to_adf_doc() {
  jq -Rs '{type:"doc",version:1,content:[splits("\n")|select(length>0)
          |{type:"paragraph",content:[{type:"text",text:.}]}]}' "$1"
}

# email → accountId (stdout). '@me' short-circuits to the caller's own id.
_account_id_for() {
  if [ "$1" = "@me" ]; then
    _request GET "/myself" || return
    jq -r '.accountId' "$RESP_FILE"; return
  fi
  _request GET "/user/search?query=$(_urlenc "$1")" || return
  local id; id=$(jq -r '.[0].accountId // empty' "$RESP_FILE")
  [ -n "$id" ] || { printf 'jira: no Jira account found for "%s"\n' "$1" >&2; return "$EX_NOTFOUND"; }
  printf '%s' "$id"
}

# ─── Layer 2: transport core (the single curl choke point) ──────────────────

# _request METHOD PATH [JSON_BODY]   body → $RESP_FILE; returns a semantic exit code.
_request() {
  local method=$1 path=$2 body=${3-} code
  local -a c=(curl -sS --max-time 60 -u "$_CRED" -H "Accept: application/json"
              -X "$method" -o "$RESP_FILE" -w '%{http_code}')
  [ -n "$body" ] && c+=(-H "Content-Type: application/json" --data "$body")
  code=$("${c[@]}" "$_BASE$path") || { echo "jira: transport error (curl failed) on $method $path" >&2; return "$EX_ERR"; }
  case "$code" in
    2??) return "$EX_OK" ;;
    400) _fail "$EX_VALIDATION" "$code" "validation — bad body / unknown field or issue type" ;;
    401) _fail "$EX_AUTH"       "$code" "unauthorized — token stale/invalid for role '${_ROLE:-default}'" ;;
    403) _fail "$EX_FORBIDDEN"  "$code" "forbidden — permission" ;;
    404) _fail "$EX_NOTFOUND"   "$code" "not found (or no permission — Jira masks 403 as 404)" ;;
    *)   _fail "$EX_UNEXPECTED" "$code" "unexpected status" ;;
  esac
}
_fail() {
  printf 'jira: HTTP %s — %s: %s\n' "$2" "$3" \
    "$(jq -rc '.errors // .errorMessages // .message // empty' "$RESP_FILE" 2>/dev/null)" >&2
  return "$1"
}

# ─── Layer 3: typed operations ──────────────────────────────────────────────

op_whoami() { _request GET "/myself" && cat "$RESP_FILE"; }

op_project_exists() {
  local key="$1"
  _request GET "/project/search?query=$(_urlenc "$key")" || return
  jq -e --arg k "$key" 'any(.values[]; .key == $k)' "$RESP_FILE" >/dev/null 2>&1 \
    || { printf 'jira: project "%s" not visible to this account\n' "$key" >&2; return "$EX_NOTFOUND"; }
  printf '%s\n' "$key"
}

op_issue_view() {   # KEY [FIELDS]
  local key="$1" fields="${2-}" path="/issue/$1"
  [ -n "$fields" ] && path="$path?fields=$(_urlenc "$fields")"
  _request GET "$path" && cat "$RESP_FILE"
}

op_issue_create() { _request POST "/issue" "$1" && jq -r '.key' "$RESP_FILE"; }  # $1 = {"fields":…}

op_transition_to() {   # KEY STATUS_NAME
  _request GET "/issue/$1/transitions" || return
  local tid
  tid=$(jq -r --arg t "$2" 'first(.transitions[] | select(.to.name == $t) | .id) // empty' "$RESP_FILE")
  [ -n "$tid" ] || { printf 'jira: no transition to "%s" from %s'"'"'s current status\n' "$2" "$1" >&2; return "$EX_NOTRANSITION"; }
  _request POST "/issue/$1/transitions" "{\"transition\":{\"id\":\"$tid\"}}"
}

op_assign() {   # KEY <email|@me|--remove>
  local key="$1" who="$2" acct
  if [ "$who" = "--remove" ]; then
    acct=null
  else
    acct="\"$(_account_id_for "$who")\"" || return
  fi
  _request PUT "/issue/$key/assignee" "{\"accountId\":$acct}"
}

op_comment_add()  { _request POST "/issue/$1/comment" "$2"; }   # $2 = {"body":…ADF…}
op_comment_list() { _request GET  "/issue/$1/comment" && cat "$RESP_FILE"; }

op_issue_delete() {   # KEY [with_subtasks]
  local path="/issue/$1"; [ "${2-}" = "1" ] && path="$path?deleteSubtasks=true"
  _request DELETE "$path"
}

op_raw() {   # METHOD PATH [BODY]
  _request "$1" "$2" "${3-}" || return
  [ -s "$RESP_FILE" ] && cat "$RESP_FILE" || true
}

# ─── Layer 4: dispatch ──────────────────────────────────────────────────────

# Pull the global --role out of the arg list wherever it appears.
_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --role)   _ROLE="${2-}"; shift 2 ;;
    --role=*) _ROLE="${1#--role=}"; shift ;;
    *)        _args+=("$1"); shift ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}

[ $# -ge 1 ] || usage
group="$1"; shift

case "$group" in
  help|-h|--help) usage ;;

  whoami) _ready; op_whoami ;;

  project)
    verb="${1-}"; shift || true
    case "$verb" in
      exists) [ $# -eq 1 ] || usage; _ready; op_project_exists "$1" ;;
      *) usage ;;
    esac ;;

  raw)
    # raw METHOD PATH [--data-file FILE]
    [ $# -ge 2 ] || usage
    method="$1"; path="$2"; shift 2
    case "$path" in /*) : ;; *) die "$EX_USAGE" "raw PATH must start with '/' (got '$path')";; esac
    body=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --data-file) body=$(cat "$2"); shift 2 ;;
        *) usage ;;
      esac
    done
    _ready; op_raw "$method" "$path" "$body" ;;

  issue)
    verb="${1-}"; shift || true
    case "$verb" in
      view)
        [ $# -ge 1 ] || usage; key="$1"; shift; fields=""
        while [ $# -gt 0 ]; do case "$1" in --fields) fields="$2"; shift 2 ;; *) usage ;; esac; done
        _ready; op_issue_view "$key" "$fields" ;;

      transition)
        [ $# -ge 1 ] || usage; key="$1"; shift; to=""
        while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; *) usage ;; esac; done
        [ -n "$to" ] || usage
        _ready; op_transition_to "$key" "$to" ;;

      assign)
        [ $# -ge 1 ] || usage; key="$1"; shift; who=""
        while [ $# -gt 0 ]; do
          case "$1" in --to) who="$2"; shift 2 ;; --remove) who="--remove"; shift ;; *) usage ;; esac
        done
        [ -n "$who" ] || usage
        _ready; op_assign "$key" "$who" ;;

      delete)
        [ $# -ge 1 ] || usage; key="$1"; shift; subs=0
        while [ $# -gt 0 ]; do case "$1" in --with-subtasks) subs=1; shift ;; *) usage ;; esac; done
        _ready; op_issue_delete "$key" "$subs" ;;

      create)
        project=""; type=""; summary=""; parent=""; assignee=""; desc_file=""; adf_file=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --project)  project="$2";  shift 2 ;;
            --type)     type="$2";     shift 2 ;;
            --summary)  summary="$2";  shift 2 ;;
            --parent)   parent="$2";   shift 2 ;;
            --assignee) assignee="$2"; shift 2 ;;
            --desc-file) desc_file="$2"; shift 2 ;;
            --adf-file)  adf_file="$2";  shift 2 ;;
            *) usage ;;
          esac
        done
        { [ -n "$project" ] && [ -n "$type" ] && [ -n "$summary" ]; } || usage
        [ -n "$desc_file" ] && [ -n "$adf_file" ] && die "$EX_USAGE" "give --desc-file OR --adf-file, not both."
        _ready
        fields=$(jq -n --arg p "$project" --arg t "$type" --arg s "$summary" \
                   '{project:{key:$p},issuetype:{name:$t},summary:$s}')
        [ -n "$parent" ] && fields=$(jq --arg k "$parent" '. + {parent:{key:$k}}' <<<"$fields")
        if [ -n "$assignee" ]; then
          acct=$(_account_id_for "$assignee") || exit $?
          fields=$(jq --arg a "$acct" '. + {assignee:{accountId:$a}}' <<<"$fields")
        fi
        if [ -n "$desc_file" ]; then
          doc=$(_text_to_adf_doc "$desc_file")
          fields=$(jq --argjson d "$doc" '. + {description:$d}' <<<"$fields")
        elif [ -n "$adf_file" ]; then
          fields=$(jq --slurpfile d "$adf_file" '. + {description:$d[0]}' <<<"$fields")
        fi
        op_issue_create "$(jq -n --argjson f "$fields" '{fields:$f}')" ;;

      comment)
        sub="${1-}"; shift || true
        case "$sub" in
          list) [ $# -eq 1 ] || usage; _ready; op_comment_list "$1" ;;
          add)
            [ $# -ge 1 ] || usage; key="$1"; shift; body_file=""; adf_file=""
            while [ $# -gt 0 ]; do
              case "$1" in
                --body-file) body_file="$2"; shift 2 ;;
                --adf-file)  adf_file="$2";  shift 2 ;;
                *) usage ;;
              esac
            done
            { [ -n "$body_file" ] || [ -n "$adf_file" ]; } || usage
            [ -n "$body_file" ] && [ -n "$adf_file" ] && die "$EX_USAGE" "give --body-file OR --adf-file, not both."
            _ready
            if [ -n "$body_file" ]; then doc=$(_text_to_adf_doc "$body_file"); else doc=$(cat "$adf_file"); fi
            op_comment_add "$key" "$(jq -n --argjson d "$doc" '{body:$d}')" ;;
          *) usage ;;
        esac ;;

      *) usage ;;
    esac ;;

  *) usage ;;
esac
