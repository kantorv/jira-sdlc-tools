#!/usr/bin/env bash
# acli-list-subtasks.sh — list a Jira parent's sub-tasks.
#
# NOTE: the name is kept for compatibility, but this no longer uses acli — it
# wraps `jira.sh issue view <KEY> --fields subtasks,issuetype` (REST v3). See
# ../jira-api-reference.md.
#
# `issue view` without an explicit field list omits `subtasks`, so this requests
# just the fields it parses (subtasks,issuetype) and prints every sub-task's
# key + summary. Reusable form of the check run after bulk-seeding sub-tasks.
#
# Requires jira.sh working (curl + jq + a valid credential) and `jq`. Run from
# within the repo/worktree — jira.sh resolves its config from the git top-level.
# Reads <PROJECT-KEY> from jira-sdlc-tools.env (override with --env or $PROJECT_KEY);
# it's printed for confirmation, never sent to the API.
#
# Usage:
#   acli-list-subtasks.sh --parent <PARENT-KEY> [--role <role>] [--env ./jira-sdlc-tools.env] [--json]
#
# Exit 0      — listed sub-tasks (or reported "none").
# Exit 1      — jq missing, --parent missing, or the response wasn't JSON.
# Exit <code> — the `jira.sh issue view` call failed (its stderr is relayed).

set -u

die() { printf '%s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "acli-list-subtasks: jq is required but not installed."
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JIRA_SH="$SCRIPT_DIR/jira.sh"

PARENT=""
ROLE=""
ENV_PATH="./jira-sdlc-tools.env"
JSON_OUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --parent) PARENT="${2:-}"; shift 2 ;;
    --role)   ROLE="${2:-}"; shift 2 ;;
    --env)    ENV_PATH="${2:-}"; shift 2 ;;
    --json)   JSON_OUT=1; shift ;;
    *) die "acli-list-subtasks: unknown argument '$1'
usage: acli-list-subtasks.sh --parent <PARENT-KEY> [--role <role>] [--env ./jira-sdlc-tools.env] [--json]" ;;
  esac
done

[ -n "$PARENT" ] || die "acli-list-subtasks: missing required --parent <PARENT-KEY>
usage: acli-list-subtasks.sh --parent <PARENT-KEY> [--role <role>] [--env ./jira-sdlc-tools.env] [--json]"

# --- resolve PROJECT-KEY (hyphen OR underscore form) ------------------------
# PROJECT-KEY has a hyphen, so `source` can't read it — grep it out. Precedence:
# --env path, then ./jira-sdlc-tools.env, then ../jira-sdlc-tools.env.
resolve_project() {
  local p m
  for p in "$ENV_PATH" "jira-sdlc-tools.env" "../jira-sdlc-tools.env"; do
    [ -f "$p" ] || continue
    m=$(grep -E '^PROJECT[-_]KEY=' "$p" 2>/dev/null | head -1 | sed -E 's/^PROJECT[-_]KEY=//')
    if [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
  done
  printf '%s' "${PROJECT_KEY:-}"
}
PROJECT=$(resolve_project)
PROJ_LABEL=""
[ -n "$PROJECT" ] && PROJ_LABEL="[$PROJECT] "

# --- fetch the parent + its sub-tasks via jira.sh ----------------------------
# jira.sh emits clean JSON (no leading noise, unlike acli), so parse it directly.
ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT
if [ -n "$ROLE" ]; then
  JSON=$(bash "$JIRA_SH" --role "$ROLE" issue view "$PARENT" --fields 'subtasks,issuetype' 2>"$ERR_FILE")
else
  JSON=$(bash "$JIRA_SH" issue view "$PARENT" --fields 'subtasks,issuetype' 2>"$ERR_FILE")
fi
CODE=$?
if [ "$CODE" -ne 0 ]; then
  printf '%s\n' "$(cat "$ERR_FILE")" >&2
  exit "$CODE"
fi
jq -e . >/dev/null 2>&1 <<<"$JSON" || die "acli-list-subtasks: jira.sh issue view output had no JSON object"

if [ "$JSON_OUT" -eq 1 ]; then
  jq --arg parent "$PARENT" '
    (.fields // .) as $f
    | ($f.subtasks // []) as $st
    | {parent: $parent,
       parent_type: ($f.issuetype.name // "?"),
       subtasks: [$st[] | {key: .key, summary: (.fields.summary // null)}]}
  ' <<<"$JSON"
  exit 0
fi

PARENT_TYPE=$(jq -r '(.fields // .).issuetype.name // "?"' <<<"$JSON")
COUNT=$(jq '(.fields // .).subtasks // [] | length' <<<"$JSON")

printf '%sparent %s (%s) — %s sub-task(s):\n' "$PROJ_LABEL" "$PARENT" "$PARENT_TYPE" "$COUNT"
if [ "$COUNT" -eq 0 ]; then
  printf '  (none — not a parent, or no sub-tasks attached)\n'
  exit 0
fi

jq -r '(.fields // .).subtasks[] | "\(.key)\t\(.fields.summary // "")"' <<<"$JSON" \
  | while IFS=$'\t' read -r k summ; do
      printf '  %s  %s\n' "$k" "$summ"
    done
