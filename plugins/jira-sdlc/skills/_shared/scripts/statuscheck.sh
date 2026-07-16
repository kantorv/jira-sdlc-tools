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
#   asked to run. Passing an issue-key-shaped ISSUE-KEY (PROJ-123) explicitly
#   makes the script do that comparison itself instead (`issue_key` FAILs on
#   mismatch). A positional argument that is NOT issue-key-shaped — e.g. a role
#   name like "reviewer" accidentally carried over from jira_acli_login — is
#   ignored, not compared: the branch-derived key is used exactly as in the
#   no-arg case. statuscheck takes no role argument. Neither jira-task-executor
#   nor jira-task-reviewer pass one anymore — both take no issue-key argument,
#   so the branch is their sole source of truth for the key.
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
# Role-agnostic by design: the `worktree` and `branch` rows are context
# INFO — the script reports what it sees (linked worktree vs. main
# checkout; base branch vs. feature/hotfix issue branch vs. other) but does
# NOT decide whether that context is right for whoever ran it. Each skill
# judges that in prose after reading the table, so one script serves the
# assigner (main checkout on the base branch), the executor, and the
# reviewer (a linked worktree on an issue branch) without ever knowing
# which role is calling. Genuinely role-independent failures (missing git
# repo / env files, wrong-project branch, unauthenticated CLIs, unreachable
# project) still FAIL and set the exit code.
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
# Only honor a positional arg that has the issue-key shape (PROJ-123). Any other
# value — most often a role name like "reviewer" carried over by mistake from the
# preceding `jira_acli_login <role>` call — is NOT an issue key: ignore it and fall
# back to the branch-derived key, exactly as the no-arg path does, instead of
# FAILing issue_key against it. statuscheck itself takes no role argument.
KEY_ARG_IGNORED=""
if [ -n "$KEY_ARG" ] && ! printf '%s' "$KEY_ARG" | grep -qE '^[A-Za-z][A-Za-z0-9]*-[0-9]+$'; then
  KEY_ARG_IGNORED="$KEY_ARG"
  KEY_ARG=""
fi
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

# Print the accumulated table (+ remedies); the caller chooses the exit
# code. Called both at the end and from the mandatory-file gate below
# when it halts before any other check runs.
print_report() {
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
}

# --- mandatory jira-sdlc-tools.local.env gate (runs before any other check) -
# jira-sdlc-tools.local.env is mandatory in every checkout — it holds the
# Jira account URL/email + token the skills depend on. It's gitignored, so
# a linked worktree (which shares tracked files only) is born without it.
# The copy logic itself lives in exactly one place, ensure_local_env.sh —
# every skill already calls it before jira_acli_login.sh, so by the time
# statuscheck.sh runs here it's normally a no-op; delegate to it (rather
# than duplicating the copy) so a standalone run of this script still
# self-heals the same way. WT_ROOT/IS_WORKTREE computed here are reused by
# the git_repo block below. The main checkout's own missing-file case is
# still handled in the env_local section (FAIL + continue), unchanged.
WT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
IS_WORKTREE=""
# A linked worktree's .git is a *file* (pointer into the main repo's
# .git/worktrees/); the main checkout's .git is a directory.
if [ -n "$WT_ROOT" ] && [ -f "$WT_ROOT/.git" ]; then
  IS_WORKTREE=1
fi
ENV_LOCAL_COPIED=""
ENV_LOCAL_COPIED_FROM=""
if [ -n "$WT_ROOT" ]; then
  PRE_EXISTED=""
  [ -f "$WT_ROOT/jira-sdlc-tools.local.env" ] && PRE_EXISTED=1
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if ! bash "$SCRIPT_DIR/ensure_local_env.sh" >/dev/null 2>&1; then
    row env_local FAIL "mandatory jira-sdlc-tools.local.env missing — not in this worktree and not copyable from the main repo" \
      "create jira-sdlc-tools.local.env in the main checkout first (Jira URL/email/token — see skills/_shared/project-config.md), then $RERUN."
    print_report
    exit 1
  fi
  if [ -z "$PRE_EXISTED" ] && [ -n "$IS_WORKTREE" ] && [ -f "$WT_ROOT/jira-sdlc-tools.local.env" ]; then
    ENV_LOCAL_COPIED=1
    GITDIR=$(sed -n 's/^gitdir: //p' "$WT_ROOT/.git" 2>/dev/null || true)
    ENV_LOCAL_COPIED_FROM=$(dirname "$(dirname "$(dirname "$GITDIR")")" 2>/dev/null || true)
  fi
fi

# --- git repo / worktree -------------------------------------------------
# WT_ROOT and IS_WORKTREE were set by the mandatory-file gate above.
if [ -z "$WT_ROOT" ]; then
  row git_repo FAIL "not inside a git repository (cwd: $PWD)" \
    "cd into the per-issue worktree jira-task-assigner created (worktree-${KEY:-<KEY>}) and $RERUN."
else
  row git_repo OK "root: $WT_ROOT"
  # Context only — the caller decides if this is the right place for its
  # role (executor/reviewer want a linked worktree; the assigner wants the
  # main checkout). Never a FAIL.
  if [ -n "$IS_WORKTREE" ]; then
    row worktree INFO "linked worktree: $(basename "$WT_ROOT") (.git is a file)"
  else
    row worktree INFO "main repo checkout (.git is a directory)"
  fi
fi

# --- platform (single source of truth for "am I on Windows") --------------
# Reports the OS and, on Windows, verifies the runtime the Windows dispatch
# path needs: PowerShell 5.1+ (`pwsh` OR `powershell`), acli/gh, and the
# win/*.ps1 ports. Each SKILL.md's dispatch
# convention keys off this row — POSIX runs the bash scripts here, windows runs
# scripts/win/*.ps1 with the same args. STATUSCHECK_FORCE_OS overrides
# detection so the Windows branch can be exercised on Linux/CI (statuscheck.ps1
# honors the same override and emits an identical row).
PLAT_SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || printf '%s' "$PWD")
_detect_os() {
  case "$(uname -s 2>/dev/null)" in
    Linux)                OS=linux ;;
    Darwin)               OS=darwin ;;
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;
    *)                    OS=unknown ;;
  esac
}
case "${STATUSCHECK_FORCE_OS:-}" in
  linux|darwin|windows) OS="$STATUSCHECK_FORCE_OS"; OS_FORCED=" (forced via STATUSCHECK_FORCE_OS)" ;;
  "")                   OS_FORCED=""; _detect_os ;;
  *)                    OS_FORCED=" (STATUSCHECK_FORCE_OS='${STATUSCHECK_FORCE_OS}' invalid — ignored)"; _detect_os ;;
esac
if [ "$OS" = "windows" ]; then
  WIN_DIR="$PLAT_SCRIPT_DIR/win"
  MISSING=""
  PS_RUNTIME="" PS_VER=""
  if command -v pwsh >/dev/null 2>&1; then
    PS_RUNTIME="pwsh"
    PS_VER=$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.Major' 2>/dev/null | tr -d '[:space:]')
  elif command -v powershell >/dev/null 2>&1; then
    PS_RUNTIME="powershell"
    PS_VER=$(powershell -NoProfile -Command '$PSVersionTable.PSVersion.Major' 2>/dev/null | tr -d '[:space:]')
  fi
  if [ -z "$PS_RUNTIME" ]; then
    MISSING="$MISSING PowerShell"
  else
    case "$PS_VER" in
      ''|*[!0-9]*) MISSING="$MISSING PowerShell(version?)" ;;
      *) [ "$PS_VER" -ge 5 ] || MISSING="$MISSING PowerShell(v$PS_VER<5)" ;;
    esac
  fi
  command -v acli >/dev/null 2>&1 || MISSING="$MISSING acli"
  command -v gh   >/dev/null 2>&1 || MISSING="$MISSING gh"
  for s in statuscheck ensure_local_env jira_acli_login get_assignee_email check_assignee; do
    [ -f "$WIN_DIR/$s.ps1" ] || MISSING="$MISSING win/$s.ps1"
  done
  if [ -n "$MISSING" ]; then
    row platform FAIL "os=windows$OS_FORCED — missing:$MISSING" \
      "on Windows the skills dispatch to pwsh/powershell scripts/win/*.ps1 — install PowerShell 5.1+ + acli + gh and ensure the win/ ports are present, then $RERUN."
  else
    row platform OK "os=windows$OS_FORCED — PowerShell $PS_VER ($PS_RUNTIME) + acli + gh + win/ ports present (Windows dispatch path ready)"
  fi
else
  row platform INFO "os=$OS$OS_FORCED — POSIX path: skills run the bash scripts in _shared/scripts/"
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
PRODUCTION_BRANCH=$(cfg PRODUCTION_BRANCH || true)
if [ ! -f "$CFG_DIR/jira-sdlc-tools.env" ]; then
  row env_config FAIL "jira-sdlc-tools.env not found in $CFG_DIR" \
    "create jira-sdlc-tools.env in the project root (variables described in skills/_shared/project-config.md), then $RERUN."
elif [ -z "$PROJECT_KEY" ]; then
  row env_config FAIL "jira-sdlc-tools.env found but PROJECT-KEY is unset" \
    "add PROJECT-KEY to jira-sdlc-tools.env (see skills/_shared/project-config.md), then $RERUN."
else
  row env_config OK "PROJECT-KEY=$PROJECT_KEY"
fi

# jira-sdlc-tools.local.env — machine-specific, holds the Jira account
# URL/email + token the skills depend on. It is mandatory in every
# checkout and gitignored (it points at secrets). Gitignored files aren't
# shared with linked worktrees, so the gate above auto-copies it into a
# worktree from the main checkout when missing — by the time we reach here
# the file is present (or the gate has already halted on a worktree that
# can't recover it). The main-checkout-missing path below still FAILs and
# continues to the rest of the checks, unchanged from before the gate.
if [ -f "$CFG_DIR/jira-sdlc-tools.local.env" ]; then
  if [ -n "$ENV_LOCAL_COPIED" ]; then
    row env_local OK "auto-copied from main repo ($ENV_LOCAL_COPIED_FROM)"
  else
    row env_local OK "jira-sdlc-tools.local.env present"
  fi
  if git -C "$CFG_DIR" ls-files --error-unmatch jira-sdlc-tools.local.env >/dev/null 2>&1; then
    row env_local_ignored FAIL "jira-sdlc-tools.local.env is TRACKED by git — the account email and credential path are in shared history" \
      "git rm --cached jira-sdlc-tools.local.env, add it to .gitignore, and rotate the leaked Jira token before anything else."
  elif git -C "$CFG_DIR" check-ignore -q jira-sdlc-tools.local.env 2>/dev/null; then
    row env_local_ignored OK "gitignored (never committed)"
  else
    row env_local_ignored FAIL "jira-sdlc-tools.local.env is NOT gitignored — committing it would leak the account email and credential path" \
      "add jira-sdlc-tools.local.env to .gitignore first, then $RERUN."
  fi
else
  row env_local FAIL "jira-sdlc-tools.local.env not found in $CFG_DIR" \
    "create it in the project root (Jira URL/email/token — see skills/_shared/project-config.md); don't copy a teammate's, it holds their token and account."
  row env_local_ignored INFO "skipped (file absent)"
fi

# --- current branch (BR/BR_TAIL/BR_KEY parsed at the top) ------------------
# Context only — report which kind of branch this is; the caller decides
# whether it's the right one for its role (executor/reviewer want a
# feature/hotfix issue branch; the assigner wants the base branch). Never a
# FAIL. BRANCH_OK stays set for a feature/hotfix branch so branch_project
# below can still validate the project prefix (a wrong-project worktree is
# a role-independent error and does FAIL).
BRANCH_OK=""
if [ -z "$BR" ]; then
  row branch INFO "detached HEAD or no current branch"
elif [ -n "$BASE_BRANCH" ] && [ "$BR" = "$BASE_BRANCH" ]; then
  row branch INFO "$BR (base branch — matches DEFAULT_BASE_BRANCH)"
else
  case "$BR" in
    feature/*|hotfix/*)
      BRANCH_OK=1
      row branch INFO "$BR (feature/hotfix issue branch)" ;;
    *)
      row branch INFO "$BR (neither DEFAULT_BASE_BRANCH nor a feature/hotfix issue branch)" ;;
  esac
fi

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
  row issue_key OK "$BR_KEY (derived from branch — confirm it matches the issue you were asked to run)${KEY_ARG_IGNORED:+ (ignored non-key argument '$KEY_ARG_IGNORED' — statuscheck takes no role/issue-key argument)}"
else
  row issue_key WARN "no issue key derivable from branch '${BR:-none}' (see the branch row)${KEY_ARG_IGNORED:+ (ignored non-key argument '$KEY_ARG_IGNORED' — statuscheck takes no role/issue-key argument)}"
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
    row acli_auth OK "$ACLI_LINE (cached status — real reachability is the jira_project row below)"
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
      "if acli_auth is OK but this FAILs, the stored credential is stale (auth status caches) — 'acli jira auth logout' then re-login per §0; else check PROJECT_KEY in jira-sdlc-tools.env, whether the token is scoped to a different site/board, whether this account was granted access to the board — or retry if Jira was just slow."
  fi
else
  row jira_project WARN "skipped (acli not authenticated or PROJECT-KEY unset — see rows above)"
fi

# --- context rows (never block) -------------------------------------------
row base_branch INFO "DEFAULT_BASE_BRANCH=${BASE_BRANCH:-unset}"
row production_branch INFO "PRODUCTION_BRANCH=${PRODUCTION_BRANCH:-unset}"

# WORKTREES_DIR is where the assigner creates per-issue worktrees. Context
# for every role (only the assigner acts on it, in prose — it stops on a
# WARN rather than mkdir-ing); a relative value is relative to the MAIN
# checkout root (see project-config.md), not to a linked worktree that may
# itself live inside that directory.
WORKTREES_DIR=$(cfg WORKTREES_DIR || true)
if [ -z "$WORKTREES_DIR" ]; then
  row worktrees_dir WARN "WORKTREES_DIR unset in jira-sdlc-tools(.local).env"
else
  WD_BASE="${WT_ROOT:-$PWD}"
  if [ -n "$IS_WORKTREE" ]; then
    WD_GITDIR=$(sed -n 's/^gitdir: //p' "$WT_ROOT/.git" 2>/dev/null || true)
    [ -n "$WD_GITDIR" ] && WD_BASE=$(dirname "$(dirname "$(dirname "$WD_GITDIR")")")
  fi
  case "$WORKTREES_DIR" in
    /*) WD_PATH="$WORKTREES_DIR" ;;
    *)  WD_PATH="$WD_BASE/$WORKTREES_DIR" ;;
  esac
  if [ -d "$WD_PATH" ]; then
    row worktrees_dir INFO "$WD_PATH (present)"
  else
    row worktrees_dir WARN "$WD_PATH missing — the assigner won't create it; check WORKTREES_DIR in jira-sdlc-tools.env if the convention changed"
  fi
fi

PARENT=$(git config "branch.$BR.parentbranch" 2>/dev/null || true)
row parent_branch INFO "${PARENT:-unset} (PR base; unset → fall back to Jira 'PR target branch' comment, then DEFAULT_BASE_BRANCH)"

DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
if [ "${DIRTY:-0}" -gt 0 ]; then
  row working_tree WARN "$DIRTY uncommitted change(s) present before this run started"
else
  row working_tree INFO "clean"
fi

# --- report ---------------------------------------------------------------
print_report
exit "$FAILED"
