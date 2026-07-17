#!/usr/bin/env bash
# acli-create-parent-and-subtasks.sh
#
# Create a Jira parent work item plus N sub-tasks, driven by a manifest.
# Bundled as a reusable form of the "turn a review into tracked sub-tasks"
# pattern used while seeding issues from a skill review.
#
# Reads <PROJECT-KEY> from jira-sdlc-tools.env (team-shared) in the project root
# (override with --project or $PROJECT_KEY). Requires `acli` to be
# authenticated (acli jira auth login — see ../jira-acli-reference.md §0).
#
# subtasks-dir must contain:
#   manifest.tsv   — one row per sub-task: <name>\t<summary>
#   <name>.md      — the sub-task body (one file per manifest row name)
#
# Usage:
#   acli-create-parent-and-subtasks.sh \
#     --parent-summary "..." \
#     --parent-body ./parent.md \
#     --subtasks-dir ./sub \
#     [--parent-type Story] [--subtask-type Subtask] \
#     [--project PROJ] [--keys-out ./keys.tsv] [--dry-run]

set -uo pipefail

PARENT_TYPE="Story"
SUBTASK_TYPE="Subtask"
PROJECT_KEY=""
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
    --parent-body)     PARENT_BODY="$2";     shift 2 ;;
    --subtasks-dir)   SUBTASKS_DIR="$2";    shift 2 ;;
    --parent-type)     PARENT_TYPE="$2";     shift 2 ;;
    --subtask-type)    SUBTASK_TYPE="$2";    shift 2 ;;
    --project)         PROJECT_KEY="$2";     shift 2 ;;
    --keys-out)        KEYS_OUT="$2";        shift 2 ;;
    --dry-run)         DRY_RUN=1;            shift   ;;
    -h|--help)         usage 0 ;;
    *) echo "unknown flag: $1" >&2; usage 1 ;;
  esac
done

# --- resolve project key from jira-sdlc-tools.env (team-shared) if not given ---
if [ -z "$PROJECT_KEY" ]; then
  PROJECT_KEY="${PROJECT_KEY:-}"
  for envfile in ./jira-sdlc-tools.env ../jira-sdlc-tools.env; do
    if [ -f "$envfile" ]; then
      k=$(grep -E '^PROJECT[-_]KEY=' "$envfile" | tail -1 | cut -d= -f2-)
      [ -n "$k" ] && PROJECT_KEY="$k" && break
    fi
  done
fi
if [ -z "$PROJECT_KEY" ]; then
  echo "ERROR: no project key. Pass --project or run from a dir with jira-sdlc-tools.env." >&2
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

# acli create output:  ✓ Work item PROJ-33 created: https://<site>/browse/PROJ-33
extract_key() { sed -nE 's#.*/browse/([A-Z]+-[0-9]+).*#\1#p' | head -1; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then echo "  [dry-run] $*"; return 0; fi
  "$@"
}

echo "Project: $PROJECT_KEY"
echo "Parent type: $PARENT_TYPE   sub-task type: $SUBTASK_TYPE"
[ "$DRY_RUN" -eq 1 ] && echo "(dry run — no issues will be created)"
echo

# --- create parent ---
if [ "$DRY_RUN" -eq 1 ]; then
  PARENT_KEY="<dry-run-parent>"
  echo "[parent] acli jira workitem create --project $PROJECT_KEY --type $PARENT_TYPE --summary \"$PARENT_SUMMARY\" --description-file $PARENT_BODY"
else
  out=$(acli jira workitem create \
    --project "$PROJECT_KEY" --type "$PARENT_TYPE" \
    --summary "$PARENT_SUMMARY" \
    --description-file "$PARENT_BODY" 2>&1)
  echo "$out"
  PARENT_KEY=$(printf '%s\n' "$out" | extract_key)
  if [ -z "$PARENT_KEY" ]; then
    echo "ERROR: could not parse parent key from create output above. Aborting before sub-tasks." >&2
    exit 1
  fi
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
    echo "[subtask] $name -> acli ... --type $SUBTASK_TYPE --parent $PARENT_KEY --summary \"$summary\" --description-file $body"
    printf '%s\t%s\t%s\n' "$name" "<dry-run>" "$summary" >> "$KEYS_OUT"
    continue
  fi

  out=$(acli jira workitem create \
    --project "$PROJECT_KEY" --type "$SUBTASK_TYPE" \
    --parent "$PARENT_KEY" \
    --summary "$summary" \
    --description-file "$body" 2>&1)
  k=$(printf '%s\n' "$out" | extract_key)
  if [ -n "$k" ]; then
    echo "  $name -> $k"
    printf '%s\t%s\t%s\n' "$name" "$k" "$summary" >> "$KEYS_OUT"
    ok=$((ok+1))
  else
    echo "  $name -> FAILED"
    echo "$out" | sed 's/^/      /'
    printf '%s\t%s\t%s\n' "$name" "FAILED" "$summary" >> "$KEYS_OUT"
    fail=$((fail+1))
  fi
done < "$SUBTASKS_DIR/manifest.tsv"

echo
echo "done. parent=$PARENT_KEY  created=$ok  failed=$fail"
echo "keys: $KEYS_OUT"
[ "$DRY_RUN" -eq 0 ] && echo "view: acli jira workitem view $PARENT_KEY --json --fields 'summary,description,issuetype,status,parent,subtasks,comment'"
