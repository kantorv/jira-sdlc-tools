#!/usr/bin/env bash
# statusboard.sh — jira-sdlc cross-worktree status dashboard.
#
# Answers "where is everything?" for one person running multiple tasks in
# multiple terminals: walks every git worktree of this repo, derives each
# one's issue key from its branch (feature/<KEY>-<slug> / hotfix/<KEY>-<slug>),
# and prints ONE markdown table with the Jira status, PR state, review
# verdict, and a deterministic next-action hint per worktree.
#
# Read-only by design: never transitions, comments, pushes, or merges —
# purely a render of state that already lives in git, Jira, and GitHub.
# Run it from anywhere inside the repo (main checkout or any worktree).
#
# Usage:
#   bash statusboard.sh
#
# Config: resolves PROJECT-KEY / DEFAULT_BASE_BRANCH / STATUS_* from
# jira-sdlc-tools.env + jira-sdlc-tools.local.env in the MAIN checkout root
# (local overrides team; `NAME = value` lines are parsed, not sourced) —
# same convention as statuscheck.sh.
#
# Degrades instead of blocking: a missing or unauthenticated CLI turns its
# columns into "n/a" with a warning printed under the table. Gating
# preconditions is statuscheck.sh's job; this board renders what it can see.
#
# Verdict column: mirrors the reviewer's 3a idempotency contract — review
# comments left by THIS gh identity whose body starts `APPROVED — ` /
# `CHANGES REQUESTED — ` (byte-exact prefixes; APPROVED wins). It reads that
# contract, it never writes it.
#
# Cost note: one acli view + one or two gh calls per issue worktree, run
# sequentially — fine for the handful of parallel tasks this plugin manages.

set -u

# Network-touching calls (gh/acli) get a hard cap so one stalled API call
# can't hang the whole board. No-op where coreutils timeout is missing.
TMOUT_CMD=""
command -v timeout >/dev/null 2>&1 && TMOUT_CMD="timeout 30"

WARNINGS=()
warn() { WARNINGS+=("$1"); }

git rev-parse --show-toplevel >/dev/null 2>&1 || {
  echo "statusboard: not inside a git repository (cwd: $PWD)" >&2
  exit 1
}

# --- enumerate worktrees (the main checkout is always listed first) --------
WT_PATHS=()
WT_BRANCHES=()
cur=""
while IFS= read -r line; do
  case "$line" in
    worktree\ *) cur="${line#worktree }" ;;
    branch\ *)   WT_PATHS+=("$cur"); WT_BRANCHES+=("${line#branch refs/heads/}") ;;
    detached)    WT_PATHS+=("$cur"); WT_BRANCHES+=("(detached)") ;;
  esac
done < <(git worktree list --porcelain)
MAIN_ROOT="${WT_PATHS[0]}"

# --- project config (same parse convention as statuscheck.sh) --------------
cfg() { # cfg <NAME-PATTERN> -> value; jira-sdlc-tools.local.env overrides .env
  local f v
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$MAIN_ROOT/$f" ] || continue
    v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$MAIN_ROOT/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}
PROJECT_KEY=$(cfg 'PROJECT[-_]KEY' || true)
BASE_BRANCH=$(cfg DEFAULT_BASE_BRANCH || true)
S_PROG=$(cfg STATUS_IN_PROGRESS || true)
S_REV=$(cfg STATUS_IN_REVIEW || true)
S_DONE=$(cfg STATUS_DONE || true)
[ -z "$PROJECT_KEY" ] && warn "PROJECT-KEY unset in jira-sdlc-tools(.local).env — project-mismatch checks skipped"

# --- CLI availability (degrade, don't gate) --------------------------------
HAVE_PY=""
command -v python3 >/dev/null 2>&1 && HAVE_PY=1
[ -z "$HAVE_PY" ] && warn "python3 not found — Jira/verdict columns are n/a"

HAVE_ACLI=""
if command -v acli >/dev/null 2>&1; then
  HAVE_ACLI=1
else
  warn "acli not installed — Jira status column is n/a"
fi

HAVE_GH=""
SELF=""
if command -v gh >/dev/null 2>&1; then
  SELF=$($TMOUT_CMD gh api user --jq .login 2>/dev/null || true)
  if [ -n "$SELF" ]; then
    HAVE_GH=1
  else
    warn "gh installed but not authenticated — PR/verdict columns are n/a (run 'gh auth login')"
  fi
else
  warn "gh not installed — PR/verdict columns are n/a"
fi

# --- per-issue fetch helpers ------------------------------------------------
jira_info() { # <KEY> -> "status<TAB>type<TAB>n_subtasks" (never fails the board)
  [ -n "$HAVE_ACLI" ] && [ -n "$HAVE_PY" ] || { printf 'n/a\tn/a\t0'; return; }
  $TMOUT_CMD acli jira workitem view "$1" --json --fields 'status,issuetype,subtasks' 2>/dev/null \
  | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("?\t?\t0"); raise SystemExit
f = d.get("fields") or {}
st = (f.get("status") or {}).get("name", "?")
ty = (f.get("issuetype") or {}).get("name", "?")
ns = len(f.get("subtasks") or [])
print(f"{st}\t{ty}\t{ns}")' \
  || printf '?\t?\t0'
}

pr_lookup() { # <branch> -> "num<TAB>state<TAB>base" or nothing; prefers an open PR
  local out
  out=$($TMOUT_CMD gh pr list --head "$1" --state open --limit 1 \
    --json number,state,baseRefName \
    --jq 'if length==0 then empty else .[0] | [(.number|tostring), .state, .baseRefName] | @tsv end' \
    2>/dev/null || true)
  [ -z "$out" ] && out=$($TMOUT_CMD gh pr list --head "$1" --state all --limit 1 \
    --json number,state,baseRefName \
    --jq 'if length==0 then empty else .[0] | [(.number|tostring), .state, .baseRefName] | @tsv end' \
    2>/dev/null || true)
  printf '%s' "$out"
}

pr_details() { # <num> -> "verdict<TAB>mergeable" (verdict per the reviewer 3a contract)
  [ -n "$HAVE_PY" ] || { printf '—\t?'; return; }
  $TMOUT_CMD gh pr view "$1" --json mergeable,reviews 2>/dev/null \
  | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("?\t?"); raise SystemExit
self_login = sys.argv[1]
bodies = [r.get("body") or "" for r in d.get("reviews") or []
          if (r.get("author") or {}).get("login") == self_login]
v = "—"
if any(b.startswith("CHANGES REQUESTED — ") for b in bodies): v = "❌ changes requested"
if any(b.startswith("APPROVED — ") for b in bodies): v = "✅ approved"   # approval is terminal (3a)
m = d.get("mergeable") or "?"
print(f"{v}\t{m}")' "$SELF" \
  || printf '?\t?'
}

# --- walk the worktrees, build rows -----------------------------------------
ROWS=()
N_MERGE=0   # approved, awaiting manual merge
N_BLOCKED=0 # changes requested
N_WORK=0    # issue worktrees without an open PR yet
N_DONE=0    # PR merged

i=0
while [ "$i" -lt "${#WT_PATHS[@]}" ]; do
  path="${WT_PATHS[$i]}"
  br="${WT_BRANCHES[$i]}"
  i=$((i + 1))

  name=$(basename "$path")
  [ "$path" = "$MAIN_ROOT" ] && name="(main) $name"

  key="—"; type_cell="—"; jstatus="—"; pr_cell="—"; verdict="—"; hint="—"

  if [ "$br" = "(detached)" ]; then
    hint="detached HEAD — check manually"
  elif [ -n "$BASE_BRANCH" ] && [ "$br" = "$BASE_BRANCH" ]; then
    type_cell="base branch"
    hint="run the assigner from here to plan new work"
  else
    case "$br" in
      feature/*|hotfix/*)
        tail=${br#*/}
        key=$(printf '%s' "$tail" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)
        if [ -z "$key" ]; then
          key="—"
          hint="issue branch without a parseable key — check the branch name"
        elif [ -n "$PROJECT_KEY" ] && [ "${key%%-*}" != "$PROJECT_KEY" ]; then
          hint="belongs to project ${key%%-*}, not $PROJECT_KEY — skipped"
        else
          # Jira side
          IFS=$'\t' read -r jstatus jtype nsub <<<"$(jira_info "$key")"
          jira_note=""
          [ "$jstatus" = "?" ] && jira_note=" ⚠ Jira fetch failed — does $key exist?"
          is_parent=""
          [ "${nsub:-0}" -gt 0 ] 2>/dev/null && is_parent=1
          type_cell="$jtype"
          [ -n "$is_parent" ] && type_cell="$jtype (parent, $nsub sub)"

          # GitHub side
          pr_state="NONE"; pr_num=""; pr_base=""; mergeable="?"
          if [ -n "$HAVE_GH" ]; then
            pr_line=$(pr_lookup "$br")
            if [ -n "$pr_line" ]; then
              IFS=$'\t' read -r pr_num pr_state pr_base <<<"$pr_line"
              IFS=$'\t' read -r verdict mergeable <<<"$(pr_details "$pr_num")"
              pr_cell="#$pr_num $(printf '%s' "$pr_state" | tr '[:upper:]' '[:lower:]') → $pr_base"
              [ "$pr_state" = "OPEN" ] && [ "$mergeable" = "CONFLICTING" ] \
                && pr_cell="$pr_cell ⚠ conflicts"
            else
              pr_cell="none"
            fi
          else
            pr_cell="n/a"
          fi

          # Deterministic next-action hint
          if [ -n "$is_parent" ]; then
            case "$pr_state" in
              NONE)   hint="run the reviewer from here"; N_WORK=$((N_WORK + 1)) ;;
              OPEN)   case "$verdict" in
                        "✅ approved")           hint="parent PR approved — merge it manually"; N_MERGE=$((N_MERGE + 1)) ;;
                        "❌ changes requested")  hint="fix integration findings on the parent branch, re-run the reviewer"; N_BLOCKED=$((N_BLOCKED + 1)) ;;
                        *)                       hint="parent PR open — run the reviewer from here" ;;
                      esac ;;
              MERGED) hint="complete — worktrees can be removed"; N_DONE=$((N_DONE + 1)) ;;
              CLOSED) hint="parent PR closed unmerged — decide manually" ;;
            esac
          else
            case "$pr_state" in
              NONE)   if [ -n "$S_REV" ] && [ "$jstatus" = "$S_REV" ]; then
                        hint="status '$S_REV' but no PR found — check the executor run"
                      else
                        hint="run the executor from here"
                      fi
                      N_WORK=$((N_WORK + 1)) ;;
              OPEN)   case "$verdict" in
                        "✅ approved")           hint="approved — merge the PR manually"; N_MERGE=$((N_MERGE + 1)) ;;
                        "❌ changes requested")  hint="fix the findings here, re-run the executor"; N_BLOCKED=$((N_BLOCKED + 1)) ;;
                        *)                       hint="PR open — run the reviewer from the parent worktree" ;;
                      esac ;;
              MERGED) hint="merged — this worktree can be removed"; N_DONE=$((N_DONE + 1)) ;;
              CLOSED) hint="PR closed unmerged — decide manually" ;;
            esac
            # Board-consistency check: a merged leaf whose issue never reached Done.
            if [ "$pr_state" = "MERGED" ] && [ -n "$S_DONE" ] \
               && [ "$jstatus" != "$S_DONE" ] && [ "$jstatus" != "?" ] && [ "$jstatus" != "n/a" ]; then
              hint="$hint ⚠ Jira still '$jstatus' (expected '$S_DONE')"
            fi
          fi
        fi
        ;;
      *)
        hint="branch '$br' is neither the base branch nor a feature/hotfix issue branch"
        ;;
    esac
  fi

  # keep the markdown table parseable
  hint="$hint${jira_note:-}"
  jira_note=""
  hint="${hint//|/\/}"
  ROWS+=("| $name | $key | $type_cell | $jstatus | $pr_cell | $verdict | $hint |")
done

# --- report ------------------------------------------------------------------
echo "## jira-sdlc statusboard — ${PROJECT_KEY:-project key unset}"
echo
echo "| worktree | key | type | jira status | PR | verdict | next action |"
echo "|---|---|---|---|---|---|---|"
printf '%s\n' "${ROWS[@]}"
echo
echo "${#WT_PATHS[@]} worktree(s): $N_WORK in work · $N_BLOCKED blocked · $N_MERGE awaiting manual merge · $N_DONE merged"
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo
  echo "Warnings:"
  printf -- '- %s\n' "${WARNINGS[@]}"
fi
exit 0
