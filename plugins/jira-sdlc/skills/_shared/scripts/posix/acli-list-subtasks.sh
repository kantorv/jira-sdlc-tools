#!/usr/bin/env bash
# acli-list-subtasks.sh — list a Jira parent's sub-tasks.
#
# `acli jira workitem view <KEY> --json` omits `subtasks` by default, so a
# naive JSON parse finds nothing. This script requests just the fields it
# parses (--fields 'subtasks,issuetype' — narrower than the canonical
# issue-fetch lists in ../jira-acli-reference.md §3, which exist for the
# skills' own fetches) and prints every sub-task's key + summary. Reusable
# form of the check run after bulk-seeding sub-tasks.
#
# Unlike this directory's other helpers, this one requires `jq` rather than
# grep/sed: the payload is an array of N sub-task objects, each carrying its
# own nested fields.summary AND nested status/priority objects that also
# have a "key" (e.g. statusCategory.key: "new"/"done") — a whole-file grep
# for "key"/"summary" collects those too, with no reliable way to zip the
# matches back to the right sub-task by position. jq's per-object addressing
# sidesteps that.
#
# Requires `acli` authenticated (see ../jira-acli-reference.md §0) and `jq`.
# Reads <PROJECT-KEY> from jira-sdlc-tools.env (override with --env or
# $PROJECT_KEY); the project isn't passed to acli view but is printed for
# confirmation.
#
# Usage:
#   acli-list-subtasks.sh --parent <PARENT-KEY> [--env ./jira-sdlc-tools.env] [--json]
#
# Exit 0      — listed sub-tasks (or reported "none").
# Exit 1      — jq missing, --parent missing, or acli's --json output had no JSON.
# Exit <code> — the `acli jira workitem view` call failed (its stderr is relayed).

set -u

die() { printf '%s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "acli-list-subtasks: jq is required but not installed."

PARENT=""
ENV_PATH="./jira-sdlc-tools.env"
JSON_OUT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --parent) PARENT="${2:-}"; shift 2 ;;
    --env) ENV_PATH="${2:-}"; shift 2 ;;
    --json) JSON_OUT=1; shift ;;
    *) die "acli-list-subtasks: unknown argument '$1'
usage: acli-list-subtasks.sh --parent <PARENT-KEY> [--env ./jira-sdlc-tools.env] [--json]" ;;
  esac
done

[ -n "$PARENT" ] || die "acli-list-subtasks: missing required --parent <PARENT-KEY>
usage: acli-list-subtasks.sh --parent <PARENT-KEY> [--env ./jira-sdlc-tools.env] [--json]"

# --- resolve PROJECT-KEY (hyphen OR underscore form) ------------------------
# PROJECT-KEY has a hyphen, so `source` can't read it — grep it out. Same
# precedence as the original: --env path, then ./jira-sdlc-tools.env, then
# ../jira-sdlc-tools.env; first file carrying PROJECT-KEY wins.
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

# --- fetch the parent + its sub-tasks via acli -------------------------------
ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT

RAW=$(acli jira workitem view "$PARENT" --json --fields 'subtasks,issuetype' 2>"$ERR_FILE")
CODE=$?
ERR=$(cat "$ERR_FILE")
if [ "$CODE" -ne 0 ]; then
  printf '%s\n' "${ERR:-$RAW}" >&2
  exit "$CODE"
fi

# acli may print leading non-JSON lines; jump to the first '{'.
case "$RAW" in
  *"{"*) JSON="{${RAW#*\{}" ;;
  *) die "acli-list-subtasks: acli --json output had no JSON object" ;;
esac
jq -e . >/dev/null 2>&1 <<<"$JSON" || die "acli-list-subtasks: acli --json output had no JSON object"

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
