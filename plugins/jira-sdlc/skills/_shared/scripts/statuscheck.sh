#!/usr/bin/env bash
# statuscheck.sh — jira-sdlc pre-flight healthcheck.
#
# Gathers every environment fact a skill needs before touching anything
# (worktree, branch, issue key, CLI auth, project config) in ONE run and
# prints a markdown table any agent can read, instead of executing each
# check as a separate prose step.
#
# Usage:
#   bash statuscheck.sh [ISSUE-KEY]
#
#   The current issue key is normally derived from the branch name
#   (feature/<KEY>-<slug> / hotfix/<KEY>-<slug>) and reported in the
#   `issue_key` row — the calling agent compares it to the issue it was
#   asked to run. Passing ISSUE-KEY explicitly makes the script do that
#   comparison itself instead (`issue_key` FAILs on mismatch). Neither
#   jira-task-executor nor jira-task-reviewer pass one anymore — both
#   take no issue-key argument, so the branch is their sole source of
#   truth for the key.
#
# Config: resolves PROJECT-KEY / DEFAULT_BASE_BRANCH itself from
# jira-sdlc-tools.env + jira-sdlc-tools.local.env in the repo root
# (local overrides team; see ../project-config.md). The files use
# `NAME = value` lines, so they are parsed, not sourced.
#
# Exit code: 0 = all required checks OK; 1 = at least one FAIL row.
# Row statuses:
#   OK   — required and passing
#   FAIL — required and broken; a remedy line is printed under the table
#   WARN — suspicious but not blocking
#   INFO — context only; never affects the exit code
#
# Extending: add a gather block below and end it with one `row` call:
#   row <name> <OK|FAIL|WARN|INFO> <detail> [remedy-shown-on-FAIL]
# Remedies default to re-running the executor; other skills can override
# the rerun hint via the STATUSCHECK_RERUN env var.

set -u

KEY_ARG="${1:-}"
# Derive the issue key from the branch up front: branch tail is
# <KEY>-<slug>, so the leading <PROJ>-<n> is the key.
BR=$(git branch --show-current 2>/dev/null || true)
BR_TAIL=${BR#*/}
BR_KEY=$(printf '%s' "$BR_TAIL" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)
KEY="${KEY_ARG:-$BR_KEY}"   # best known key, for remedy messages
RERUN="${STATUSCHECK_RERUN:-rerun /jira-sdlc:jira-task-executor}"

ROWS=()
REMEDIES=()
FAILED=0

# Network-touching calls (gh/acli) get a hard cap so a stalled API call
# can't hang the whole healthcheck. No-op where coreutils timeout is
# missing (stock macOS).
TMOUT_CMD=""
command -v timeout >/dev/null 2>&1 && TMOUT_CMD="timeout 30"

row() { # row <name> <status> <detail> [remedy]
  local detail="${3//|/\/}"   # keep the table parseable
  ROWS+=("| $1 | $2 | ${detail:-—} |")
  if [ "$2" = "FAIL" ]; then
    FAILED=1
    [ -n "${4:-}" ] && REMEDIES+=("- \`$1\`: $4")
  fi
}

# --- git repo / worktree -------------------------------------------------
WT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
IS_WORKTREE=""
if [ -z "$WT_ROOT" ]; then
  row git_repo FAIL "not inside a git repository (cwd: $PWD)" \
    "cd into the per-issue worktree jira-task-assigner created (worktree-${KEY:-<KEY>}) and $RERUN."
else
  row git_repo OK "root: $WT_ROOT"
  # A linked worktree's root has a .git *file* (pointer into the main
  # repo's .git/worktrees/); the main checkout's .git is a directory.
  if [ -f "$WT_ROOT/.git" ]; then
    IS_WORKTREE=1
    row worktree OK "linked worktree: $(basename "$WT_ROOT")"
  else
    row worktree FAIL "this is the main checkout (.git is a directory) — the executor never runs here" \
      "cd into the worktree jira-task-assigner created for the issue (worktree-${KEY:-<KEY>}) and $RERUN."
  fi
fi

# --- project config ------------------------------------------------------
CFG_DIR="${WT_ROOT:-$PWD}"
cfg() { # cfg <NAME-PATTERN> -> value; jira-sdlc-tools.local.env overrides .env
  local f v
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$CFG_DIR/$f" ] || continue
    v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$CFG_DIR/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}

# both spellings occur in the wild: PROJECT_KEY (shell-sourceable env
# files) and PROJECT-KEY (the token name in project-config.md's tables)
PROJECT_KEY=$(cfg 'PROJECT[-_]KEY' || true)
BASE_BRANCH=$(cfg DEFAULT_BASE_BRANCH || true)
if [ ! -f "$CFG_DIR/jira-sdlc-tools.env" ]; then
  row env_config FAIL "jira-sdlc-tools.env not found in $CFG_DIR" \
    "create jira-sdlc-tools.env in the project root (variables described in skills/_shared/project-config.md), then $RERUN."
elif [ -z "$PROJECT_KEY" ]; then
  row env_config FAIL "jira-sdlc-tools.env found but PROJECT-KEY is unset" \
    "add PROJECT-KEY to jira-sdlc-tools.env (see skills/_shared/project-config.md), then $RERUN."
else
  row env_config OK "PROJECT-KEY=$PROJECT_KEY"
fi

# jira-sdlc-tools.local.env — machine-specific, points at secrets (Jira
# account URL/email + token value or path). Gitignored, so a linked
# worktree legitimately lacks it (acli's keyring credentials still work
# there); in the main checkout it must exist and must never be tracked.
if [ -f "$CFG_DIR/jira-sdlc-tools.local.env" ]; then
  row env_local OK "jira-sdlc-tools.local.env present"
  if git -C "$CFG_DIR" ls-files --error-unmatch jira-sdlc-tools.local.env >/dev/null 2>&1; then
    row env_local_ignored FAIL "jira-sdlc-tools.local.env is TRACKED by git — the account email and credential path are in shared history" \
      "git rm --cached jira-sdlc-tools.local.env, add it to .gitignore, and rotate the leaked Jira token before anything else."
  elif git -C "$CFG_DIR" check-ignore -q jira-sdlc-tools.local.env 2>/dev/null; then
    row env_local_ignored OK "gitignored (never committed)"
  else
    row env_local_ignored FAIL "jira-sdlc-tools.local.env is NOT gitignored — committing it would leak the account email and credential path" \
      "add jira-sdlc-tools.local.env to .gitignore first, then $RERUN."
  fi
elif [ -n "$IS_WORKTREE" ]; then
  row env_local INFO "absent — expected in a linked worktree (gitignored files aren't copied; acli keyring credentials still apply)"
  row env_local_ignored INFO "skipped (file absent)"
else
  row env_local FAIL "jira-sdlc-tools.local.env not found in $CFG_DIR" \
    "create it in the project root (Jira URL/email/token — see skills/_shared/project-config.md); don't copy a teammate's, it holds their token and account."
  row env_local_ignored INFO "skipped (file absent)"
fi

# --- current branch (BR/BR_TAIL/BR_KEY parsed at the top) ------------------
BRANCH_OK=""
case "$BR" in
  feature/*|hotfix/*)
    BRANCH_OK=1
    row branch OK "$BR" ;;
  "")
    row branch FAIL "detached HEAD or no current branch" \
      "check out the issue's feature/<KEY>-<slug> or hotfix/<KEY>-<slug> branch, then $RERUN." ;;
  *)
    row branch FAIL "'$BR' is not a feature/* or hotfix/* branch" \
      "switch to the issue's own feature/<KEY>-<slug> or hotfix/<KEY>-<slug> branch in its worktree (or rerun jira-task-assigner to provision it), then $RERUN." ;;
esac

# Branch tail is <KEY>-<slug>; its prefix must be this project's key,
# otherwise the worktree was set up for a different project's issue.
if [ -n "$BRANCH_OK" ] && [ -n "$PROJECT_KEY" ]; then
  case "$BR_TAIL" in
    "$PROJECT_KEY"-*)
      row branch_project OK "branch belongs to project $PROJECT_KEY" ;;
    *)
      row branch_project FAIL "'$BR' doesn't start with $PROJECT_KEY- — this worktree was set up for another project's issue" \
        "switch to the branch for ${KEY:-<KEY>} in this project's worktree, then $RERUN." ;;
  esac
else
  row branch_project WARN "skipped (branch or PROJECT-KEY unavailable — see rows above)"
fi

# --- issue key (derived from branch; compared only if one was passed) ------
if [ -n "$KEY_ARG" ]; then
  if [ "$BR_KEY" = "$KEY_ARG" ]; then
    row issue_key OK "branch is $KEY_ARG's own"
  else
    row issue_key FAIL "branch key '${BR_KEY:-none}' != requested '$KEY_ARG' — this worktree wasn't set up for this issue" \
      "cd into $KEY_ARG's own worktree/branch and $RERUN — or get explicit user confirmation before proceeding here."
  fi
elif [ -n "$BR_KEY" ]; then
  row issue_key OK "$BR_KEY (derived from branch — confirm it matches the issue you were asked to run)"
else
  row issue_key WARN "no issue key derivable from branch '${BR:-none}' (see the branch row)"
fi

# --- gh auth (needed by 'gh pr create') ----------------------------------
if ! command -v gh >/dev/null 2>&1; then
  row gh_auth FAIL "gh (GitHub CLI) is not installed" \
    "install it (https://cli.github.com) and run 'gh auth login', then $RERUN."
else
  GH_LINE=$($TMOUT_CMD gh auth status 2>&1 | grep -m1 'Logged in to' | sed 's/^[^L]*//' || true)
  if [ -n "$GH_LINE" ]; then
    row gh_auth OK "$GH_LINE"
  else
    row gh_auth FAIL "gh is installed but not authenticated" \
      "run 'gh auth login', then $RERUN."
  fi
fi

# --- acli auth (needed by every 'acli jira ...' call) ---------------------
ACLI_OK=""
if ! command -v acli >/dev/null 2>&1; then
  row acli_auth FAIL "acli (Atlassian CLI) is not installed" \
    "install acli and run the one-time login (skills/_shared/jira-acli-reference.md §0, using the jira-sdlc-tools.local.env values), then $RERUN."
else
  ACLI_LINE=$($TMOUT_CMD acli jira auth status 2>&1 | grep -m1 '✓ Authenticated' || true)
  if [ -n "$ACLI_LINE" ]; then
    ACLI_OK=1
    row acli_auth OK "$ACLI_LINE"
  else
    row acli_auth FAIL "acli is installed but not authenticated with Jira" \
      "run the one-time acli login (skills/_shared/jira-acli-reference.md §0, using the jira-sdlc-tools.local.env values), then $RERUN."
  fi
fi

# --- Jira project reachable (whole-word match avoids PROJ matching PROJ2;
# a pagination flag is required — bare --json errors) -----------------------
if [ -n "$ACLI_OK" ] && [ -n "$PROJECT_KEY" ]; then
  if $TMOUT_CMD acli jira project list --paginate --json 2>/dev/null | grep -qw "$PROJECT_KEY"; then
    row jira_project OK "project $PROJECT_KEY reachable on the authenticated site"
  else
    row jira_project FAIL "project '$PROJECT_KEY' not found via 'acli jira project list' (or the call timed out)" \
      "check PROJECT_KEY in jira-sdlc-tools.env, whether the token is scoped to a different site/board, whether this account was granted access to the board — or retry if Jira was just slow."
  fi
else
  row jira_project WARN "skipped (acli not authenticated or PROJECT-KEY unset — see rows above)"
fi

# --- context rows (never block) -------------------------------------------
row base_branch INFO "DEFAULT_BASE_BRANCH=${BASE_BRANCH:-unset}"

PARENT=$(git config "branch.$BR.parentbranch" 2>/dev/null || true)
row parent_branch INFO "${PARENT:-unset} (PR base; unset → fall back to Jira 'PR target branch' comment, then DEFAULT_BASE_BRANCH)"

DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [ "${DIRTY:-0}" -gt 0 ]; then
  row working_tree WARN "$DIRTY uncommitted change(s) present before this run started"
else
  row working_tree INFO "clean"
fi

# --- report ---------------------------------------------------------------
echo "## jira-sdlc statuscheck — ${KEY:-no issue key}"
echo
echo "| check | status | detail |"
echo "|---|---|---|"
printf '%s\n' "${ROWS[@]}"
if [ "$FAILED" -ne 0 ]; then
  echo
  echo "Remedies for FAIL rows (relay these to the user — don't self-repair):"
  printf '%s\n' "${REMEDIES[@]}"
fi

exit "$FAILED"
