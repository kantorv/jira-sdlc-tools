#!/usr/bin/env bash
# jira.test.sh — live end-to-end smoke test for jira.sh.
#
# Creates a throwaway parent + sub-task, exercises EVERY jira.sh subcommand
# (including the negative cases), asserts the result, then deletes the issues.
# An EXIT trap deletes anything created even if an assertion aborts midway.
#
# This is an INTEGRATION test: it hits a real Jira instance and creates/deletes
# real issues, so it is NOT a CI test — it needs live credentials in
# jira-sdlc-tools.local.env. It runs as the `assigner` role (which can create);
# override with JIRA_TEST_ROLE.
#
# Usage:  bash jira.test.sh
# Exit 0 — all checks passed.   Exit 1 — one or more checks failed.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
JIRA_SH="$HERE/jira.sh"
ROLE="${JIRA_TEST_ROLE:-assigner}"
J() { bash "$JIRA_SH" --role "$ROLE" "$@"; }

# --- resolve config the same way jira.sh does (local overrides team) ---------
cfg_dir=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cfg() {
  local f v
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$cfg_dir/$f" ] || continue
    v=$(grep -E "^[[:space:]]*$1[[:space:]]*=" "$cfg_dir/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  done
}
PROJECT_KEY=$(cfg PROJECT_KEY)
IN_PROGRESS=$(cfg STATUS_IN_PROGRESS); IN_PROGRESS="${IN_PROGRESS:-In Progress}"
ASSIGN_EMAIL=$(cfg JIRA_EXECUTOR_EMAIL); [ -z "$ASSIGN_EMAIL" ] && ASSIGN_EMAIL=$(cfg JIRA_ACCOUNT_EMAIL)
[ -n "$PROJECT_KEY" ]  || { echo "test: PROJECT_KEY not set in jira-sdlc-tools.env" >&2; exit 1; }
[ -n "$ASSIGN_EMAIL" ] || { echo "test: no executor/account email to assign to" >&2; exit 1; }

# --- tiny assertion framework ------------------------------------------------
PASS=0; FAIL=0
_c() { case "$1" in ok) PASS=$((PASS+1)); printf '  PASS  %s\n' "$2";; no) FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$2";; esac; }
eq()  { [ "$2" = "$3" ] && _c ok "$1" || _c no "$1 (expected '$2', got '$3')"; }
rc()  { [ "$2" = "$3" ] && _c ok "$1" || _c no "$1 (expected rc $2, got rc $3)"; }
ne()  { [ -n "$2" ] && [ "$2" != null ] && _c ok "$1" || _c no "$1 (got empty/null)"; }

# --- cleanup: delete created issues in REVERSE order (sub before parent) -----
CREATED=()
cleanup() {
  [ "${#CREATED[@]}" -eq 0 ] && return
  echo "--- cleanup: deleting ${CREATED[*]} ---"
  local i
  for (( i=${#CREATED[@]}-1; i>=0; i-- )); do
    if J issue delete "${CREATED[$i]}" >/dev/null 2>&1; then echo "  deleted ${CREATED[$i]}"
    else echo "  WARN could not delete ${CREATED[$i]} — remove it manually"; fi
  done
}
trap cleanup EXIT

TMP=$(mktemp -d "${TMPDIR:-/tmp}/jira-test.XXXXXX"); trap 'rm -rf "$TMP"; cleanup' EXIT

echo "== jira.sh live test (role=$ROLE, project=$PROJECT_KEY) =="

# 1. whoami ------------------------------------------------------------------
out=$(J whoami); r=$?
rc "whoami exits 0" 0 $r
ne "whoami returns an accountId" "$(jq -r '.accountId // empty' <<<"$out" 2>/dev/null)"

# 2/3. project exists (positive + negative) ----------------------------------
out=$(J project exists "$PROJECT_KEY"); rc "project exists $PROJECT_KEY -> 0" 0 $?
eq "project exists prints the key" "$PROJECT_KEY" "$out"
J project exists __NO_SUCH_PROJ__ >/dev/null 2>&1; rc "project exists (missing) -> 4" 4 $?

# 4. create parent (plain-text description + assignee) -----------------------
printf 'Live test parent for jira.sh.\n\nSecond paragraph — safe to delete.\n' > "$TMP/desc.txt"
PARENT=$(J issue create --project "$PROJECT_KEY" --type Task \
  --summary "jira.sh live test (parent)" \
  --assignee "$ASSIGN_EMAIL" --desc-file "$TMP/desc.txt"); r=$?
rc "create parent -> 0" 0 $r
[ -n "$PARENT" ] && CREATED+=("$PARENT")
eq "created key is in project $PROJECT_KEY" "$PROJECT_KEY" "${PARENT%%-*}"

# 5. create sub-task (--parent) ----------------------------------------------
SUB=$(J issue create --project "$PROJECT_KEY" --type Subtask --parent "$PARENT" \
  --summary "jira.sh live test (sub-task)"); r=$?
rc "create sub-task -> 0" 0 $r
[ -n "$SUB" ] && CREATED+=("$SUB")

# 6. view: sub-task shows under parent's subtasks -----------------------------
subs=$(J issue view "$PARENT" --fields subtasks | jq -rc '[.fields.subtasks[].key]')
eq "parent lists the sub-task" "[\"$SUB\"]" "$subs"

# 7. view: description ADF landed --------------------------------------------
dtext=$(J issue view "$PARENT" --fields description | jq -r '.fields.description.content[0].content[0].text // empty')
eq "description first paragraph stored" "Live test parent for jira.sh." "$dtext"

# 8/9. comments: plain-text + raw ADF ----------------------------------------
printf 'PR target branch: development.\nSecond line of the note.\n' > "$TMP/cmt.txt"
J issue comment add "$PARENT" --body-file "$TMP/cmt.txt" >/dev/null; rc "comment add (--body-file) -> 0" 0 $?
cat > "$TMP/rich.adf.json" <<'EOF'
{"type":"doc","version":1,"content":[
  {"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"Rich heading"}]}
]}
EOF
J issue comment add "$PARENT" --adf-file "$TMP/rich.adf.json" >/dev/null; rc "comment add (--adf-file) -> 0" 0 $?

# 10. comment list: both are present -----------------------------------------
clist=$(J issue comment list "$PARENT")
eq "comment count is 2" 2 "$(jq -r '.total' <<<"$clist")"
eq "marker comment present" "yes" \
  "$(jq -r 'any(.comments[].body.content[].content[]?.text; startswith("PR target branch:")) | if . then "yes" else "no" end' <<<"$clist")"

# 11/12/13. assign by email -> @me -> remove ---------------------------------
J issue assign "$PARENT" --to "$ASSIGN_EMAIL" >/dev/null; rc "assign by email -> 0" 0 $?
ne "assignee is set" "$(J issue view "$PARENT" --fields assignee | jq -r '.fields.assignee.accountId // empty')"
J issue assign "$PARENT" --to @me >/dev/null; rc "assign @me -> 0" 0 $?
J issue assign "$PARENT" --remove >/dev/null; rc "assign --remove -> 0" 0 $?
eq "assignee cleared" "null" "$(J issue view "$PARENT" --fields assignee | jq -r '.fields.assignee')"

# 14. transition by status name ----------------------------------------------
J issue transition "$PARENT" --to "$IN_PROGRESS" >/dev/null; rc "transition -> $IN_PROGRESS -> 0" 0 $?
eq "status is now $IN_PROGRESS" "$IN_PROGRESS" "$(J issue view "$PARENT" --fields status | jq -r '.fields.status.name')"

# 15. transition to a bogus status -> exit 8 ---------------------------------
J issue transition "$PARENT" --to "__nope__" >/dev/null 2>&1; rc "transition (bad status) -> 8" 8 $?

# 16. raw escape hatch --------------------------------------------------------
eq "raw GET /myself returns identity" "$(J whoami | jq -r .accountId)" "$(J raw GET /myself | jq -r .accountId)"

# 17/18/19. delete sub, delete parent, confirm gone --------------------------
J issue delete "$SUB" >/dev/null; r=$?; rc "delete sub-task -> 0" 0 $r
[ $r -eq 0 ] && CREATED=("$PARENT")           # sub gone; leave only parent for the trap
J issue delete "$PARENT" >/dev/null; r=$?; rc "delete parent -> 0" 0 $r
[ $r -eq 0 ] && CREATED=()                     # both gone; trap has nothing to do
J issue view "$PARENT" >/dev/null 2>&1; rc "view deleted issue -> 4" 4 $?

# --- summary -----------------------------------------------------------------
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
