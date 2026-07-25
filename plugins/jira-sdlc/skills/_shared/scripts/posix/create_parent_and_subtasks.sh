#!/usr/bin/env bash
# create_parent_and_subtasks.sh
#
# Wraps `jira.sh issue create` (REST v3). See ../jira-api-reference.md.
#
# Create a Jira parent work item plus N sub-tasks, driven by a manifest.
# Bundled as a reusable form of the "turn a review into tracked sub-tasks"
# pattern used while seeding issues from a skill review.
#
# Reads <PROJECT-KEY> from .jst/jira-sdlc-tools.env (team-shared) in the project root
# (override with --project or $PROJECT_KEY). Requires jira.sh working (curl + jq
# + a valid credential); run from within the repo/worktree — jira.sh resolves its
# config from the git top-level. Creates as --role (default assigner) so the created
# issues' creator/reporter is that role's account.
#
# subtasks-dir must contain:
#   manifest.tsv   — one row per sub-task: <name>\t<summary>
#   <name>.md      — the sub-task body (one file per manifest row name)
#
# Usage:
#   create_parent_and_subtasks.sh \
#     --parent-summary "..." \
#     --parent-body ./parent.md \
#     --subtasks-dir ./sub \
#     [--parent-type Story] [--subtask-type Subtask] \
#     [--project PROJ] [--role assigner] [--keys-out ./keys.tsv] [--dry-run]

set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JIRA_SH="$SCRIPT_DIR/jira.sh"

PARENT_TYPE="Story"
SUBTASK_TYPE="Subtask"
PROJECT_KEY=""
ROLE="assigner"
PARENT_SUMMARY=""
PARENT_BODY=""
SUBTASKS_DIR=""
KEYS_OUT=""
DRY_RUN=0

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-1}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --parent-summary) PARENT_SUMMARY="$2"; shift 2 ;;
    --parent-body)    PARENT_BODY="$2";    shift 2 ;;
    --subtasks-dir)   SUBTASKS_DIR="$2";   shift 2 ;;
    --parent-type)    PARENT_TYPE="$2";    shift 2 ;;
    --subtask-type)   SUBTASK_TYPE="$2";   shift 2 ;;
    --project)        PROJECT_KEY="$2";    shift 2 ;;
    --role)           ROLE="$2";           shift 2 ;;
    --keys-out)       KEYS_OUT="$2";       shift 2 ;;
    --dry-run)        DRY_RUN=1;           shift   ;;
    -h|--help)        usage 0 ;;
    *) echo "unknown flag: $1" >&2; usage 1 ;;
  esac
done

# --- resolve project key from .jst/jira-sdlc-tools.env (team-shared) if not given ---
# Anchored at the git top-level (like jira.sh) rather than walked up from cwd,
# so it resolves the same from any subdirectory.
if [ -z "$PROJECT_KEY" ]; then
  CFG_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")
  envfile="$CFG_ROOT/.jst/jira-sdlc-tools.env"
  if [ -f "$envfile" ]; then
    k=$(grep -E '^PROJECT[-_]KEY=' "$envfile" | tail -1 | cut -d= -f2-)
    [ -n "$k" ] && PROJECT_KEY="$k"
  fi
fi
if [ -z "$PROJECT_KEY" ]; then
  echo "ERROR: no project key. Pass --project or run inside a repo with .jst/jira-sdlc-tools.env." >&2
  exit 1
fi

# --- validate args ---
miss=0
[ -z "$PARENT_SUMMARY" ] && { echo "ERROR: --parent-summary is required" >&2; miss=1; }
[ -z "$PARENT_BODY" ]     && { echo "ERROR: --parent-body is required" >&2;     miss=1; }
[ -z "$SUBTASKS_DIR" ]   && { echo "ERROR: --subtasks-dir is required" >&2;    miss=1; }
[ "$miss" -eq 1 ] && exit 1
[ -f "$PARENT_BODY" ]        || { echo "ERROR: parent body not found: $PARENT_BODY" >&2;        exit 1; }
[ -d "$SUBTASKS_DIR" ]       || { echo "ERROR: subtasks dir not found: $SUBTASKS_DIR" >&2;     exit 1; }
[ -f "$SUBTASKS_DIR/manifest.tsv" ] || { echo "ERROR: no manifest.tsv in $SUBTASKS_DIR" >&2;    exit 1; }
[ -z "$KEYS_OUT" ] && KEYS_OUT="$SUBTASKS_DIR/created-keys.tsv"

is_key() { printf '%s' "$1" | grep -qE '^[A-Za-z][A-Za-z0-9]*-[0-9]+$'; }

# jira.sh issue create prints the new key directly on success — no
# "✓ … /browse/PROJ-N" line to parse. Errors go to stderr + a non-zero exit.
create_issue() {  # create_issue <type> <summary> <body> [parent-key]
  local type="$1" summary="$2" body="$3" parent="${4:-}"
  if [ -n "$parent" ]; then
    bash "$JIRA_SH" --role "$ROLE" issue create --project "$PROJECT_KEY" --type "$type" \
      --parent "$parent" --summary "$summary" --desc-file "$body"
  else
    bash "$JIRA_SH" --role "$ROLE" issue create --project "$PROJECT_KEY" --type "$type" \
      --summary "$summary" --desc-file "$body"
  fi
}

echo "Project: $PROJECT_KEY"
echo "Parent type: $PARENT_TYPE   sub-task type: $SUBTASK_TYPE   role: $ROLE"
[ "$DRY_RUN" -eq 1 ] && echo "(dry run — no issues will be created)"
echo

# --- create parent ---
if [ "$DRY_RUN" -eq 1 ]; then
  PARENT_KEY="<dry-run-parent>"
  echo "[parent] jira.sh --role $ROLE issue create --project $PROJECT_KEY --type $PARENT_TYPE --summary \"$PARENT_SUMMARY\" --desc-file $PARENT_BODY"
else
  out=$(create_issue "$PARENT_TYPE" "$PARENT_SUMMARY" "$PARENT_BODY" 2>&1); rc=$?
  if [ "$rc" -ne 0 ] || ! is_key "$out"; then
    echo "ERROR: could not create the parent. jira.sh said:" >&2
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    exit 1
  fi
  PARENT_KEY="$out"
fi
echo "parent -> $PARENT_KEY"
echo

# --- create sub-tasks from manifest.tsv ---
: > "$KEYS_OUT"
ok=0; fail=0
# skip blank lines and comments (#)
while IFS=$'\t' read -r name summary || [ -n "$name" ]; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue;; esac
  [ -z "$summary" ] && { echo "WARN: manifest row '$name' has no summary; skipping" >&2; continue; }

  body="$SUBTASKS_DIR/$name.md"
  if [ ! -f "$body" ]; then
    echo "WARN: body file not found for '$name' ($body); skipping" >&2
    printf '%s\t%s\t%s\n' "$name" "MISSING" "-" >> "$KEYS_OUT"
    fail=$((fail+1)); continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[subtask] $name -> jira.sh ... --type $SUBTASK_TYPE --parent $PARENT_KEY --summary \"$summary\" --desc-file $body"
    printf '%s\t%s\t%s\n' "$name" "<dry-run>" "$summary" >> "$KEYS_OUT"
    continue
  fi

  out=$(create_issue "$SUBTASK_TYPE" "$summary" "$body" "$PARENT_KEY" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && is_key "$out"; then
    echo "  $name -> $out"
    printf '%s\t%s\t%s\n' "$name" "$out" "$summary" >> "$KEYS_OUT"
    ok=$((ok+1))
  else
    echo "  $name -> FAILED"
    printf '%s\n' "$out" | sed 's/^/      /'
    printf '%s\t%s\t%s\n' "$name" "FAILED" "$summary" >> "$KEYS_OUT"
    fail=$((fail+1))
  fi
done < "$SUBTASKS_DIR/manifest.tsv"

echo
echo "done. parent=$PARENT_KEY  created=$ok  failed=$fail"
echo "keys: $KEYS_OUT"
[ "$DRY_RUN" -eq 0 ] && echo "view: jira.sh issue view $PARENT_KEY --fields 'summary,description,issuetype,status,parent,subtasks,comment'"
