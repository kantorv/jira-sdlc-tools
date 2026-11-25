#!/usr/bin/env bash
# statuscheck.sh — jira-sdlc pre-flight healthcheck.
#
# Gathers every environment fact a skill needs before touching anything
# (worktree, branch, issue key, CLI auth, project config) in ONE run and
# prints a markdown table any agent can read, instead of executing each
# check as a separate prose step.
#
# Usage:
#   bash statuscheck.sh --role assigner|executor|reviewer [ISSUE-KEY]
#
#   --role is REQUIRED and names the CALLING skill's role: auth is role-scoped
#   (there is no default credential), so the jira_auth / jira_project rows can
#   only probe a credential once they know whose it is. A missing or unknown
#   role is a usage error (exit 2, no table) rather than a guess at someone
#   else's identity.
#
#   The current issue key is normally derived from the branch name
#   (feature/<KEY>-<slug> / hotfix/<KEY>-<slug>) and reported in the
#   `issue_key` row — the calling agent compares it to the issue it was
#   asked to run. Passing an issue-key-shaped ISSUE-KEY (PROJ-123) explicitly
#   makes the script do that comparison itself instead (`issue_key` FAILs on
#   mismatch). A positional argument that is NOT issue-key-shaped — e.g. a role
#   name passed positionally instead of via --role — is
#   ignored, not compared: the branch-derived key is used exactly as in the
#   no-key case. Neither jira-task-executor
#   nor jira-task-reviewer pass a key — both take no issue-key argument,
#   so the branch is their sole source of truth for the key.
#
# Config: resolves PROJECT-KEY / DEFAULT_BASE_BRANCH itself from
# .jst/jira-sdlc-tools.env + .jst/jira-sdlc-tools.local.env under the repo root
# (local overrides team; see ../project-config.md). The files use
# `NAME = value` lines, so they are parsed, not sourced.
#
# Exit code: 0 = all required checks OK; 1 = at least one FAIL row;
#            2 = usage error (bad/missing --role) — printed on stderr, no table.
# Row statuses:
#   OK   — required and passing
#   FAIL — required and broken; a remedy line is printed under the table
#   WARN — suspicious but not blocking
#   INFO — context only; never affects the exit code
#
# Role-agnostic JUDGEMENT, role-scoped AUTH: --role decides which credential
# the jira rows probe, and nothing else. The `worktree` and `branch` rows stay
# context INFO — the script reports what it sees (linked worktree vs. main
# checkout; base branch vs. feature/hotfix issue branch vs. other) but does
# NOT decide whether that context is right for whoever ran it. Each skill
# judges that in prose after reading the table, so one script serves the
# assigner (main checkout on the base branch), the executor, and the
# reviewer (a linked worktree on an issue branch) with no per-role branching
# beyond the credential. Genuinely role-independent failures (missing git
# repo / env files, wrong-project branch, unauthenticated CLIs, unreachable
# project) still FAIL and set the exit code.
#
# Extending: add a gather block below and end it with one `row` call:
#   row <name> <OK|FAIL|WARN|INFO> <detail> [remedy-shown-on-FAIL]
# Remedies default to re-running the executor; other skills can override
# the rerun hint via the STATUSCHECK_RERUN env var.

set -u

# --- args: required --role, optional ISSUE-KEY -------------------------------
# Same parsing shape as check_assignee.sh, but the role has no default: it
# selects the credential the jira rows authenticate with, and guessing wrong
# would report someone else's identity as if it were the caller's.
ROLE="${JIRA_ROLE:-}"
KEY_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role)   ROLE="${2:-}"; shift 2 ;;
    --role=*) ROLE="${1#--role=}"; shift ;;
    *)        KEY_ARG="$1"; shift ;;
  esac
done
case "$ROLE" in
  assigner|executor|reviewer) ;;
  "") printf '%s\n' "statuscheck: --role is required — one of assigner|executor|reviewer" >&2; exit 2 ;;
  *)  printf '%s\n' "statuscheck: role must be assigner|executor|reviewer (got '$ROLE')" >&2; exit 2 ;;
esac
ROLE_UC=$(printf '%s' "$ROLE" | tr '[:lower:]' '[:upper:]')

# The project root, resolved before anything reads git state, and cd'd into:
# run from inside a member submodule, the branch, worktree and PRs that matter
# are the project's, not the member's (often a detached HEAD). statuscheck takes
# no path arguments, so moving changes nothing else. Its own folder is resolved
# first, because BASH_SOURCE may be a path relative to where it was started.
SC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || printf '%s' "$PWD")
. "$SC_DIR/_jst_root.sh"
WT_ROOT=$(jst_root || true)
[ -n "$WT_ROOT" ] && cd "$WT_ROOT"

# Derive the issue key from the branch up front: branch tail is
# <KEY>-<slug>, so the leading <PROJ>-<n> is the key.
BR=$(git branch --show-current 2>/dev/null || true)
BR_TAIL=${BR#*/}
BR_KEY=$(printf '%s' "$BR_TAIL" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)
# Only honor a positional arg that has the issue-key shape (PROJ-123). Any other
# value — most often a role name passed positionally instead of via --role — is
# NOT an issue key: ignore it and fall
# back to the branch-derived key, exactly as the no-key path does, instead of
# FAILing issue_key against it.
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

# Network-touching calls (gh/jira.sh) get a hard cap so a stalled API call
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

# WT_ROOT is the project root, resolved at the top.
IS_WORKTREE=""
# A linked worktree's .git is a *file* pointing into the main repo's
# .git/worktrees/; the main checkout's .git is a directory. (A submodule's .git
# is a file too, which is why the helper checks where it points.)
if [ -n "$WT_ROOT" ] && jst_is_linked_worktree "$WT_ROOT"; then
  IS_WORKTREE=1
fi

# --- mandatory .jst/ gate (runs before every other check) -------------------
# Both settings files live in <repo-root>/.jst/, and nothing reads a
# root-level copy — so a missing .jst/ means no config at all, for every
# role. Check it before the local.env gate below: that gate copies a file
# *into* .jst/, and without this row a missing folder would surface as a
# confusing "can't copy local.env" instead of the real cause.
if [ -z "$WT_ROOT" ]; then
  # No repo root to look under, so this gate can't run at all. Say that in a
  # row rather than printing nothing: the row map in jst-install lists jst_dir
  # as a section-1 row, and a silently absent row reads like a passing one.
  row jst_dir INFO "skipped — not inside a git repository, so there is no repo root to hold .jst/ (see git_repo)"
else
  if [ -d "$WT_ROOT/.jst" ]; then
    row jst_dir OK "$WT_ROOT/.jst"
  else
    row jst_dir FAIL "settings folder $WT_ROOT/.jst not found — the skills read their config only from there" \
      "create .jst/ in the project root holding jira-sdlc-tools.env (team-shared, tracked) and jira-sdlc-tools.local.env (machine-specific, gitignored) — see skills/_shared/project-config.md — then $RERUN."
    print_report
    exit 1
  fi
fi

# --- mandatory .jst/jira-sdlc-tools.local.env gate (before any other check) -
# .jst/jira-sdlc-tools.local.env is mandatory in every checkout — it holds the
# Jira account URL/email + token the skills depend on. It's gitignored, so
# a linked worktree (which shares tracked files only) is born without it.
# The copy logic itself lives in exactly one place, ensure_local_env.sh —
# every skill already calls it before its first jira.sh call, so by the time
# statuscheck.sh runs here it's normally a no-op; delegate to it (rather
# than duplicating the copy) so a standalone run of this script still
# self-heals the same way. WT_ROOT/IS_WORKTREE computed above are reused by
# the git_repo block below. The main checkout's own missing-file case is
# still handled in the env_local section (FAIL + continue), unchanged.
ENV_LOCAL_COPIED=""
ENV_LOCAL_COPIED_FROM=""
if [ -n "$WT_ROOT" ]; then
  PRE_EXISTED=""
  [ -f "$WT_ROOT/.jst/jira-sdlc-tools.local.env" ] && PRE_EXISTED=1
  SCRIPT_DIR=$SC_DIR
  # Relay its stderr as the remedy rather than asserting a cause. It now fails
  # for three different reasons — nothing to copy, the path isn't ignored here,
  # the credential is tracked — and each needs a different fix, so a hardcoded
  # "missing / not copyable" line would be wrong two times in three (JST-301).
  ELE_ERR=$(bash "$SCRIPT_DIR/ensure_local_env.sh" 2>&1 >/dev/null); ELE_RC=$?
  if [ "$ELE_RC" -ne 0 ]; then
    ELE_ERR=$(printf '%s' "$ELE_ERR" | tr '\n' ' ')
    row env_local FAIL "ensure_local_env could not provision .jst/jira-sdlc-tools.local.env here" \
      "${ELE_ERR:-create .jst/jira-sdlc-tools.local.env in the main checkout first (Jira URL/email/token — see skills/_shared/project-config.md), then $RERUN.}"
    print_report
    exit 1
  fi
  if [ -z "$PRE_EXISTED" ] && [ -n "$IS_WORKTREE" ] && [ -f "$WT_ROOT/.jst/jira-sdlc-tools.local.env" ]; then
    ENV_LOCAL_COPIED=1
    ENV_LOCAL_COPIED_FROM=$(jst_main_checkout "$WT_ROOT")
  fi
fi

# --- git repo / worktree -------------------------------------------------
# WT_ROOT and IS_WORKTREE were set by the mandatory-file gate above.
if [ -z "$WT_ROOT" ]; then
  # Caller-neutral remedy on purpose: all four skills print this row, and a
  # sentence about one role's worktree is wrong for the other three (JST-251).
  row git_repo FAIL "not inside a git repository (cwd: $PWD)" \
    "cd into the project checkout these skills are configured for — its main checkout, or the issue's own worktree when you're running an issue — and $RERUN. If the project has no repository yet, create or clone one (with its GitHub 'origin' remote) first: the skills wire an existing repo up, they don't create it."
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
# path needs: PowerShell 5.1+ (`pwsh` OR `powershell`), gh, and the
# win/*.ps1 ports. Each SKILL.md's dispatch
# convention keys off this row — POSIX runs the bash scripts here, windows runs
# scripts/win/*.ps1 with the same args. STATUSCHECK_FORCE_OS overrides
# detection so the Windows branch can be exercised on Linux/CI (statuscheck.ps1
# honors the same override and emits an identical row).
PLAT_SCRIPT_DIR=$SC_DIR
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
  WIN_DIR="$PLAT_SCRIPT_DIR/../win"
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
  # jira.ps1 uses native Invoke-WebRequest + ConvertFrom-Json, so the Windows
  # path needs only gh (for 'gh pr create') and the ports.
  command -v gh >/dev/null 2>&1 || MISSING="$MISSING gh"
  for s in statuscheck ensure_local_env get_assignee_email check_assignee jira; do
    [ -f "$WIN_DIR/$s.ps1" ] || MISSING="$MISSING win/$s.ps1"
  done
  if [ -n "$MISSING" ]; then
    row platform FAIL "os=windows$OS_FORCED — missing:$MISSING" \
      "on Windows the skills dispatch to pwsh/powershell scripts/win/*.ps1 — install PowerShell 5.1+ + gh and ensure the win/ ports are present, then $RERUN."
  else
    row platform OK "os=windows$OS_FORCED — PowerShell $PS_VER ($PS_RUNTIME) + gh + win/ ports present (Windows dispatch path ready)"
  fi
else
  row platform INFO "os=$OS$OS_FORCED — POSIX path: skills run the bash scripts in _shared/scripts/posix/"
fi

# --- project config ------------------------------------------------------
# Both settings files live in <repo-root>/.jst/ — the only location read.
CFG_ROOT="${WT_ROOT:-$PWD}"
CFG_DIR="$CFG_ROOT/.jst"
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
  # In a worktree the obvious remedy is the wrong one: hand-authoring a copy
  # here clears the row while leaving a second file that drifts from the main
  # checkout's (JST-301). ensure_local_env.sh already syncs this file across,
  # so reaching this row in a worktree means the main checkout hasn't got it
  # either — which is where the fix belongs.
  if [ -n "$IS_WORKTREE" ]; then
    row env_config FAIL "jira-sdlc-tools.env not found in $CFG_DIR" \
      "this is a linked worktree — don't author a copy here, it would silently drift from the main checkout's. Fix it there instead: create .jst/jira-sdlc-tools.env in the main checkout (variables described in skills/_shared/project-config.md) and commit it, so every worktree gets it as a tracked file; while it stays uncommitted, ensure_local_env.sh copies it across. Then $RERUN."
  else
    row env_config FAIL "jira-sdlc-tools.env not found in $CFG_DIR" \
      "create jira-sdlc-tools.env in the project's .jst/ folder (variables described in skills/_shared/project-config.md), then $RERUN."
  fi
elif [ -z "$PROJECT_KEY" ]; then
  row env_config FAIL "jira-sdlc-tools.env found but PROJECT-KEY is unset" \
    "add PROJECT-KEY to .jst/jira-sdlc-tools.env (see skills/_shared/project-config.md), then $RERUN."
else
  row env_config OK "PROJECT-KEY=$PROJECT_KEY"
fi

# .jst/jira-sdlc-tools.local.env — machine-specific, holds the Jira account
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
    row env_local OK ".jst/jira-sdlc-tools.local.env present"
  fi
  # Run git from the repo root and name the path under .jst/ — git resolves a
  # relative pathspec against its working directory, so the two must agree.
  if git -C "$CFG_ROOT" ls-files --error-unmatch .jst/jira-sdlc-tools.local.env >/dev/null 2>&1; then
    row env_local_ignored FAIL ".jst/jira-sdlc-tools.local.env is TRACKED by git — the account email and credential path are in shared history" \
      "git rm --cached .jst/jira-sdlc-tools.local.env, add a line 'jira-sdlc-tools.local.env' to .jst/.gitignore, and rotate the leaked Jira token before anything else."
  elif git -C "$CFG_ROOT" check-ignore -q .jst/jira-sdlc-tools.local.env 2>/dev/null; then
    row env_local_ignored OK "gitignored (never committed)"
  else
    row env_local_ignored FAIL ".jst/jira-sdlc-tools.local.env is NOT gitignored — committing it would leak the account email and credential path" \
      "add a line 'jira-sdlc-tools.local.env' to .jst/.gitignore — the rule belongs inside .jst/, where jst-install puts it, so that copying the folder carries the protection with it — then $RERUN."
  fi
else
  row env_local FAIL "jira-sdlc-tools.local.env not found in $CFG_DIR" \
    "create it in the project's .jst/ folder (Jira URL/email/token — see skills/_shared/project-config.md); don't copy a teammate's, it holds their token and account."
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
  row issue_key OK "$BR_KEY (derived from branch — confirm it matches the issue you were asked to run)${KEY_ARG_IGNORED:+ (ignored non-key argument '$KEY_ARG_IGNORED' — the role goes in --role, and the key comes from the branch)}"
else
  row issue_key WARN "no issue key derivable from branch '${BR:-none}' (see the branch row)${KEY_ARG_IGNORED:+ (ignored non-key argument '$KEY_ARG_IGNORED' — the role goes in --role, and the key comes from the branch)}"
fi

# --- gh auth (needed by every gh call the skills make) ---------------------
# Per-request, like jira_auth (JST-331): gh.sh hands GITHUB_PAT_TOKEN to gh as
# GH_TOKEN for one process, and this row proves the token with GET /user. There
# is no `gh auth login` or `logout` anywhere: the old session login (JST-143/
# 145/290) wrote ~/.config/gh and the keyring — global to the OS user — so the
# developer's own gh ended up holding the last project's PAT, two projects run
# at once raced for the one session, and a failed login left gh logged out.
# Every gh call in the skills and in repos.sh goes through gh.sh, so nothing
# depends on a stored session, and a scheduled statuscheck changes nothing.
# GITHUB_PAT_TOKEN is a secret, machine-specific value → the gitignored
# .jst/jira-sdlc-tools.local.env only, same treatment as the Jira role tokens.
# A missing token or a rejected one FAILs, relaying the wrapper's or gh's first
# stderr line (token redacted) so the actual error is named (JST-145 AC#3).
GH_SH="$SC_DIR/gh.sh"
GH_OK=""
if ! command -v gh >/dev/null 2>&1; then
  row gh_auth FAIL "gh (GitHub CLI) is not installed" \
    "install it (https://cli.github.com), then $RERUN."
else
  GH_ERRF=$(mktemp)
  if GH_LOGIN=$($TMOUT_CMD bash "$GH_SH" api user --jq .login 2>"$GH_ERRF") && [ -n "$GH_LOGIN" ]; then
    GH_OK=1
    row gh_auth OK "GITHUB_PAT_TOKEN authenticates as $GH_LOGIN (GET /user, per request — gh's own login is never read or changed)"
  else
    GH_RC=$?
    # cfg parses rather than sources the env file, so a quoted value keeps its
    # quotes — strip one surrounding pair, as gh.sh does, before redacting it.
    GH_PAT=$(cfg GITHUB_PAT_TOKEN || true)
    GH_PAT=${GH_PAT#\"}; GH_PAT=${GH_PAT%\"}; GH_PAT=${GH_PAT#\'}; GH_PAT=${GH_PAT%\'}
    ERR=$(cat "$GH_ERRF")
    [ -n "$GH_PAT" ] && ERR=${ERR//"$GH_PAT"/[REDACTED]}
    ERR=$(printf '%s' "$ERR" | awk 'NF{sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; exit}')
    if [ "$GH_RC" -eq 4 ] && [ "${ERR#jst-gh: }" != "$ERR" ]; then
      row gh_auth FAIL "${ERR#jst-gh: }" \
        "add GITHUB_PAT_TOKEN to .jst/jira-sdlc-tools.local.env (a fine-grained GitHub PAT; see .jst/jira-sdlc-tools.local.env.example and https://kantorv.github.io/jira-sdlc-tools/docs/gh-pat-session-login), then $RERUN."
    else
      row gh_auth FAIL "GET /user with GITHUB_PAT_TOKEN failed: ${ERR:-(no stderr from gh)}" \
        "a connection or network error is usually transient: $RERUN. Otherwise check that GITHUB_PAT_TOKEN in .jst/jira-sdlc-tools.local.env is a valid, non-expired GitHub PAT."
    fi
  fi
  rm -f "$GH_ERRF"
fi

# --- gh repo access (needed by 'gh pr create', not proved by gh_auth) ------
# gh_auth proves the TOKEN authenticates and nothing more. A fine-grained PAT scoped
# to "only selected repositories" authenticates happily, reads the org and 20 other
# repos, and still cannot see this one — GitHub answers 404, not 403, so it
# looks like a typo rather than a permission (JST-251). With an SSH origin every
# git operation keeps working, and the first thing to break is `gh pr create`
# in the executor, mid-task, after the work is committed. So probe the actual
# repository here. `gh api repos/<OWNER>/<REPO>` is REST; `gh repo view` goes
# through GraphQL and fails with a different, less legible error.
# Role-agnostic like the rest: gh uses one shared PAT, not a per-role identity.
gh_slug() { # gh_slug <remote-url> -> OWNER/REPO ; non-zero when not github.com
  local u="$1" s
  case "$u" in *github.com*) ;; *) return 1 ;; esac
  s=${u#*github.com}          # ":OWNER/REPO.git" (SSH) or "/OWNER/REPO.git" (HTTPS)
  s=${s#:}; s=${s#/}; s=${s%/}; s=${s%.git}
  printf '%s' "$s" | grep -qE '^[^/]+/[^/]+$' || return 1
  printf '%s' "$s"
}
if [ -z "$WT_ROOT" ]; then
  row gh_repo_access WARN "skipped (not in a git repository, so there is no origin to probe — see git_repo)"
elif ! ORIGIN_URL=$(git -C "$WT_ROOT" remote get-url origin 2>/dev/null) || [ -z "$ORIGIN_URL" ]; then
  row gh_repo_access FAIL "this repository has no 'origin' remote — the skills push issue branches to it and open PRs against it" \
    "create the GitHub repository (or find the existing one) and attach it: git remote add origin git@github.com:<OWNER>/<REPO>.git — the skills don't create repositories — then $RERUN."
elif [ -z "$GH_OK" ]; then
  row gh_repo_access WARN "skipped (gh_auth failed — the repo probe needs a working GITHUB_PAT_TOKEN; see rows above)"
elif ! GH_SLUG=$(gh_slug "$ORIGIN_URL"); then
  row gh_repo_access WARN "origin is not a github.com remote ($ORIGIN_URL) — can't probe it with gh, and 'gh pr create' won't work against it"
elif GH_API_ERR=$($TMOUT_CMD bash "$GH_SH" api "repos/$GH_SLUG" 2>&1 >/dev/null); then
  row gh_repo_access OK "$GH_SLUG reachable with this PAT (GET /repos/$GH_SLUG)"
else
  case "$GH_API_ERR" in
    *404*|*"Not Found"*|*"Could not resolve"*)
      row gh_repo_access FAIL "the PAT authenticates but 404s on $GH_SLUG — usually the fine-grained token's 'only selected repositories' list doesn't include this one (GitHub answers 404, not 403, for a repo a token can't see); a renamed or deleted repository looks identical from here" \
        "add $GH_SLUG to GITHUB_PAT_TOKEN's repository access at https://github.com/settings/personal-access-tokens (keep Contents: read/write and Pull requests: read/write) — an org-owned repo may also need an org admin to approve the token — or fix the origin URL if the repository really moved. Then $RERUN." ;;
    *)
      ERR=$(printf '%s' "$GH_API_ERR" | awk 'NF{sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; exit}')
      row gh_repo_access FAIL "GET /repos/$GH_SLUG failed: ${ERR:-(no error output from gh)}" \
        "resolve the error above (permissions, SSO authorization, or a transient network/API problem), then $RERUN." ;;
  esac
fi

# --- repo strategy and member repos (repos.sh) --------------------------------
# Which strategy applies: single, or a parent holding member repos as git
# submodules (JST_MEMBERS). For submodules, one row per member: checked out,
# reachable with the PAT, its base branch on GitHub. repos.sh owns the rules
# (which paths are members, each one's base); these rows only judge its output.
# The branch probe goes through gh like gh_repo_access, not `git ls-remote`, so
# it uses the same PAT and can't stall on an SSH prompt.
if [ -n "$WT_ROOT" ]; then
  RS_OUT=$(bash "$SC_DIR/repos.sh" strategy 2>/dev/null); RS_RC=$?
  rs() { printf '%s\n' "$RS_OUT" | sed -n "s/^$1=//p"; }
  RS_ERR=$(rs error); RS_MEMBERS=$(rs members); RS_PINNED=$(rs pinned)
  if [ "$RS_RC" -eq 2 ] && [ -n "$RS_ERR" ]; then
    row repo_strategy FAIL "$RS_ERR" \
      "fix JST_MEMBERS in .jst/jira-sdlc-tools.env — the submodule paths that take part in issues, space-separated, as 'git submodule status' prints them; leave it empty for a single-repo project (see skills/_shared/project-config.md) — then $RERUN."
  elif [ "$RS_RC" -ne 0 ]; then
    row repo_strategy WARN "repos.sh strategy failed (exit $RS_RC) — the repo set is unknown"
  elif [ "$(rs strategy)" = single ]; then
    if [ -n "$RS_PINNED" ]; then
      row repo_strategy INFO "single ($(printf '%s' "$RS_PINNED" | wc -w | tr -d ' ') submodule(s) present, none in JST_MEMBERS: $RS_PINNED)"
    else
      row repo_strategy INFO "single"
    fi
  else
    row repo_strategy OK "submodules — members: $RS_MEMBERS${RS_PINNED:+ · pinned: $RS_PINNED}"
    while IFS=$'\t' read -r M_PATH M_ROLE M_INIT M_SLUG M_BASE M_BRANCH _ _; do
      [ "$M_ROLE" = member ] || continue
      M_ROW="member_repo[$M_PATH]"
      if [ "$M_INIT" != yes ]; then
        row "$M_ROW" FAIL "not checked out" \
          "run 'git submodule update --init $M_PATH' in the project root, then $RERUN."
      elif [ "$M_BASE" = error ]; then
        row "$M_ROW" FAIL ".gitmodules sets 'branch = .' for $M_PATH — a member's base has to be a real branch name" \
          "name its base explicitly: git submodule set-branch --branch <base> $M_PATH, commit .gitmodules, then $RERUN."
      elif [ "$M_SLUG" = - ]; then
        row "$M_ROW" WARN "origin is not a github.com remote — can't probe it with gh, and 'gh pr create' won't work against it"
      elif [ -z "$GH_OK" ]; then
        row "$M_ROW" WARN "skipped (gh_auth failed — the member probe needs a working GITHUB_PAT_TOKEN; see rows above)"
      elif ! M_ERR=$($TMOUT_CMD bash "$GH_SH" api "repos/$M_SLUG" 2>&1 >/dev/null); then
        case "$M_ERR" in
          *404*|*"Not Found"*|*"Could not resolve"*)
            row "$M_ROW" FAIL "the PAT authenticates but 404s on $M_SLUG — the fine-grained token's 'only selected repositories' list probably doesn't include this member" \
              "add $M_SLUG to GITHUB_PAT_TOKEN's repository access at https://github.com/settings/personal-access-tokens (Contents: read/write, Pull requests: read/write), or remove $M_PATH from JST_MEMBERS if it isn't a member — then $RERUN." ;;
          *)
            M_ERR=$(printf '%s' "$M_ERR" | awk 'NF{sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; exit}')
            row "$M_ROW" FAIL "GET /repos/$M_SLUG failed: ${M_ERR:-(no error output from gh)}" \
              "resolve the error above (permissions, SSO authorization, or a transient network/API problem), then $RERUN." ;;
        esac
      elif ! M_BRANCHES=$($TMOUT_CMD bash "$GH_SH" api --paginate "repos/$M_SLUG/branches" --jq '.[].name' 2>/dev/null); then
        row "$M_ROW" WARN "$M_SLUG reachable, but listing its branches failed — base '$M_BASE' unchecked"
      elif ! printf '%s\n' "$M_BRANCHES" | grep -qxF "$M_BASE"; then
        row "$M_ROW" FAIL "base branch '$M_BASE' isn't on $M_SLUG — issue branches are cut from it and PRs target it" \
          "push '$M_BASE' to $M_SLUG, or set the member's base in .gitmodules (git submodule set-branch --branch <base> $M_PATH), then $RERUN."
      elif [ -n "$PRODUCTION_BRANCH" ] && ! printf '%s\n' "$M_BRANCHES" | grep -qxF "$PRODUCTION_BRANCH"; then
        row "$M_ROW" WARN "$M_SLUG · base $M_BASE · on $M_BRANCH — no '$PRODUCTION_BRANCH' branch there, so a hotfix can't touch this member"
      else
        row "$M_ROW" OK "$M_SLUG · base $M_BASE · on $M_BRANCH"
      fi
    done < <(bash "$SC_DIR/repos.sh" list 2>/dev/null | tail -n +2)
  fi
fi

# --- the current branch's PR(s) ----------------------------------------------
# Answers "which PR does the branch I'm standing on have" once, the same way on
# every run, so no skill hand-types that lookup (JST-310). gh answers a filter
# that misses with [] rather than an error, so every argument is load-bearing:
# --head takes the BARE branch name (owner:branch silently matches nothing),
# --state all keeps a merged/closed PR visible, and there is deliberately no
# --base — a PR opened against an unexpected base must show up (and WARN), not
# read as "none". Never FAILs: whether "no PR" is a problem is the calling
# skill's judgement. Skipped off an issue branch, so the assigner (on the base
# branch) pays no extra API call. PARENT feeds the parent_branch row below too.
PARENT=$(git config "branch.$BR.parentbranch" 2>/dev/null || true)
CP_SLUG=""
[ -n "${ORIGIN_URL:-}" ] && CP_SLUG=$(gh_slug "$ORIGIN_URL" || true)
if [ -z "$GH_OK" ]; then
  row current_pr WARN "skipped (gh_auth failed — the PR lookup needs a working GITHUB_PAT_TOKEN; see rows above)"
elif [ -z "${ORIGIN_URL:-}" ]; then
  row current_pr WARN "skipped (no 'origin' remote to look PRs up on — see gh_repo_access)"
elif [ -z "$CP_SLUG" ]; then
  row current_pr WARN "skipped (origin is not a github.com remote — see gh_repo_access)"
elif [ -z "$BR" ]; then
  row current_pr WARN "skipped (detached HEAD — no branch to look PRs up for)"
elif [ "$BR" = "$BASE_BRANCH" ] || [ "$BR" = "$PRODUCTION_BRANCH" ]; then
  row current_pr WARN "skipped ($BR is a base branch, not an issue branch)"
elif [ -z "$BRANCH_OK" ]; then
  row current_pr WARN "skipped ($BR is not a feature/hotfix issue branch)"
else
  CP_ERRF=$(mktemp)
  if CP_OUT=$($TMOUT_CMD bash "$GH_SH" pr list --repo "$CP_SLUG" --head "$BR" --state all \
        --json number,state,baseRefName,url \
        --jq '.[] | "\(.number)\t\(.state)\t\(.baseRefName)\t\(.url)"' 2>"$CP_ERRF"); then
    if [ -z "$CP_OUT" ]; then
      row current_pr INFO "none on $CP_SLUG (gh pr list --head $BR --state all)"
    else
      CP_LIST=""; CP_OPEN=0; CP_OFF=""
      while IFS=$'\t' read -r n st base url; do
        [ -n "$n" ] || continue
        CP_LIST="${CP_LIST:+$CP_LIST; }#$n $st → $base ($url)"
        if [ "$st" = OPEN ]; then
          CP_OPEN=$((CP_OPEN + 1))
          [ -n "$PARENT" ] && [ "$base" != "$PARENT" ] && CP_OFF="${CP_OFF:+$CP_OFF, }#$n"
        fi
      done <<< "$CP_OUT"
      CP_WHY=""
      [ "$CP_OPEN" -gt 1 ] && CP_WHY="$CP_OPEN PRs are OPEN — expected at most one"
      [ -n "$CP_OFF" ] && CP_WHY="${CP_WHY:+$CP_WHY; }OPEN $CP_OFF targets a base other than parent_branch $PARENT"
      if [ -n "$CP_WHY" ]; then
        row current_pr WARN "$CP_LIST — $CP_WHY"
      else
        row current_pr INFO "$CP_LIST"
      fi
    fi
  else
    ERR=$(awk 'NF{sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; exit}' "$CP_ERRF")
    row current_pr WARN "gh pr list --head $BR --state all failed: ${ERR:-(no error output from gh)} — PRs unknown, not absent"
  fi
  rm -f "$CP_ERRF"
fi

# --- Jira auth (needed by every 'jira.sh …' call) -------------------------
# Per-request Basic auth via `jira.sh --role <caller> whoami` (GET /myself): one
# live call, no global login state and no cache. Auth is role-scoped, so this
# probes the CALLING role's own credential — the identity every later call in
# this run will use. The ownership gate stays in the skill (check_assignee --role).
JIRA_SH="$PLAT_SCRIPT_DIR/jira.sh"
JIRA_OK=""
if ! command -v curl >/dev/null 2>&1; then
  row jira_auth FAIL "curl is required by jira.sh but not installed" \
    "install curl and jq, then $RERUN."
elif ! command -v jq >/dev/null 2>&1; then
  row jira_auth FAIL "jq is required by jira.sh but not installed" \
    "install jq and curl, then $RERUN."
elif WHOAMI_JSON=$($TMOUT_CMD bash "$JIRA_SH" --role "$ROLE" whoami 2>/dev/null) && [ -n "$WHOAMI_JSON" ]; then
  WHO=$(printf '%s' "$WHOAMI_JSON" | jq -r '.emailAddress // .displayName // .accountId // empty' 2>/dev/null)
  JIRA_OK=1
  row jira_auth OK "$ROLE authenticated as ${WHO:-unknown} (GET /myself)"
else
  row jira_auth FAIL "the $ROLE Jira credential doesn't authenticate — 'jira --role $ROLE whoami' failed (unset/stale/invalid pair, or unreachable site)" \
    "set a working JIRA_${ROLE_UC}_EMAIL + JIRA_${ROLE_UC}_TOKEN pair in .jst/jira-sdlc-tools.local.env — see skills/_shared/jira-api-reference.md — then $RERUN."
fi

# --- Jira project reachable ('jira.sh project exists' → GET /project/search) -
if [ -n "$JIRA_OK" ] && [ -n "$PROJECT_KEY" ]; then
  if $TMOUT_CMD bash "$JIRA_SH" --role "$ROLE" project exists "$PROJECT_KEY" >/dev/null 2>&1; then
    row jira_project OK "project $PROJECT_KEY reachable on the authenticated site"
  else
    row jira_project FAIL "project '$PROJECT_KEY' not visible to the $ROLE account via 'jira project exists' (or the call timed out)" \
      "check PROJECT_KEY in .jst/jira-sdlc-tools.env, whether the token is scoped to a different site, and whether this account has access to the project — or retry if Jira was just slow."
  fi
else
  row jira_project WARN "skipped (jira_auth failed or PROJECT-KEY unset — see rows above)"
fi

# --- context rows (never block) -------------------------------------------
row base_branch INFO "DEFAULT_BASE_BRANCH=${BASE_BRANCH:-unset}"
row production_branch INFO "PRODUCTION_BRANCH=${PRODUCTION_BRANCH:-unset}"

# Gitflow needs the two long-lived branches to be DIFFERENT branches. Its own
# row rather than a FAIL state on the pair above, so those two keep printing the
# plain values several skills quote verbatim. FAIL, not WARN: a collapsed pair is
# invalid config, not a judgement call — with one branch every feature PR targets
# production, the assigner's hotfix path (step 5C) resolves to the same branch as
# its planned path, and the release workflows have no branch name left to key the
# version off (docs/SDLC.md §5). Unset is not "equal to unset": mid-install both
# read unset until jst-install writes the file, and that is not a config error.
if [ -z "$BASE_BRANCH" ] || [ -z "$PRODUCTION_BRANCH" ]; then
  row branch_pair INFO "skipped (DEFAULT_BASE_BRANCH or PRODUCTION_BRANCH unset — see the two rows above)"
elif [ "$BASE_BRANCH" = "$PRODUCTION_BRANCH" ]; then
  row branch_pair FAIL "DEFAULT_BASE_BRANCH and PRODUCTION_BRANCH are both '$BASE_BRANCH' — Gitflow needs two distinct long-lived branches, and a single-branch repo isn't a supported configuration" \
    "point DEFAULT_BASE_BRANCH and PRODUCTION_BRANCH at two different branches in .jst/jira-sdlc-tools.env (the documented pair is development / main — any two names work, but create the second branch first), then $RERUN."
else
  row branch_pair OK "$BASE_BRANCH (base) and $PRODUCTION_BRANCH (production) are distinct"
fi

# The Jira site domain, used to build browse links (https://<URL>/browse/<KEY>).
# It lives only in the gitignored .jst/jira-sdlc-tools.local.env — the same file
# as the three role tokens and the GitHub PAT — so a skill that needed it had no
# row to read and reached for the file instead, putting live credentials in the
# transcript (JST-224). Printing the one non-secret value here removes the
# reason to open that file at all. Value only: cfg() returns a single key, never
# a neighbouring line.
JIRA_ACCOUNT_URL=$(cfg JIRA_ACCOUNT_URL || true)
row jira_account_url INFO "JIRA_ACCOUNT_URL=${JIRA_ACCOUNT_URL:-unset} (browse links: https://<JIRA_ACCOUNT_URL>/browse/<KEY>)"

# WORKTREES_DIR is where the assigner creates per-issue worktrees. Context
# for every role (only the assigner acts on it, in prose — it stops on a
# WARN rather than mkdir-ing). The value MUST be absolute, so a relative one
# FAILs here instead of being resolved into agreement: it means a different
# directory depending on which checkout a skill runs from (the main one for
# the assigner, a linked worktree for the executor and reviewer), and the
# assigner writes it verbatim into each leaf's Jira "Worktree: …" comment,
# which the executor then reads from inside a worktree. The remedy prints
# the value resolved from *here* so the fix is a paste — but only when that
# actually names a directory, since a hint resolved against the wrong base
# would be worse than none.
#
# What counts as absolute is OS-dependent, and the POSIX-only /* glob used to
# be the whole test — so on Windows a valid C:\… drive-letter value fell into
# the catch-all and hard-blocked the run, while the PowerShell twin accepted
# it: the two ports disagreed on identical input (JST-308). On os=windows,
# drive-letter and UNC forms count as absolute too. The MSYS form (/c/…) is
# rooted for Git Bash but neither Windows git nor the PowerShell port can
# resolve it, so it WARNs rather than FAILs — a bash-only setup that works
# today isn't hard-blocked, it's just told which form travels. Non-Windows
# behaviour is unchanged: only /* is absolute.

# /c/Users/you → C:\Users\you. Textual on purpose: statuscheck.ps1 does the
# same transform, so both ports print the same string for the same value.
msys_to_drive() {
  case "$1" in
    /[A-Za-z]|/[A-Za-z]/*)
      _wd_rest=$(printf '%s' "$1" | cut -c3- | tr '/' '\\')
      printf '%s:%s' "$(printf '%s' "$1" | cut -c2 | tr '[:lower:]' '[:upper:]')" "${_wd_rest:-\\}"
      ;;
  esac
}

WORKTREES_DIR=$(cfg WORKTREES_DIR || true)
WD_UNC='\\'
WD_ABSOLUTE=no
WD_MSYS=no
case "$WORKTREES_DIR" in /*) WD_ABSOLUTE=yes ;; esac
if [ "$OS" = windows ]; then
  case "$WORKTREES_DIR" in
    /[A-Za-z]|/[A-Za-z]/*)                  WD_MSYS=yes ;;
  esac
  case "$WORKTREES_DIR" in
    [A-Za-z]:|[A-Za-z]:[/\\]*|"$WD_UNC"*)   WD_ABSOLUTE=yes ;;
  esac
fi

if [ -z "$WORKTREES_DIR" ]; then
  row worktrees_dir WARN "WORKTREES_DIR unset in .jst/jira-sdlc-tools(.local).env"
elif [ "$WD_MSYS" = yes ]; then
  row worktrees_dir WARN "$WORKTREES_DIR is MSYS-style — Git Bash resolves it, but Windows git and the PowerShell port don't; set the drive-letter form ($(msys_to_drive "$WORKTREES_DIR")) in .jst/jira-sdlc-tools.local.env so both dispatch paths agree"
elif [ "$WD_ABSOLUTE" = yes ]; then
  if [ -d "$WORKTREES_DIR" ]; then
    row worktrees_dir INFO "$WORKTREES_DIR (present)"
  else
    row worktrees_dir WARN "$WORKTREES_DIR missing — the assigner won't create it; check WORKTREES_DIR in .jst/jira-sdlc-tools.local.env if the convention changed"
  fi
else
  WD_ABS=$(CDPATH= cd -- "$WORKTREES_DIR" 2>/dev/null && pwd)
  WD_EXAMPLE='/home/you/src/myapp-worktrees'
  if [ "$OS" = windows ]; then
    WD_EXAMPLE='C:\Users\you\projects\myapp-worktrees'
    # pwd prints MSYS form under Git Bash, so the old remedy told Windows users
    # to paste /c/… — rooted for .NET, unresolvable for Windows git, i.e. worse
    # than the config it replaced (JST-308). Convert, and offer the result only
    # if it really is drive-letter/UNC: anything else (pwsh on Linux under
    # STATUSCHECK_FORCE_OS) falls back to the example, which is also what keeps
    # the two ports printing the same remedy.
    if [ -n "$WD_ABS" ]; then
      if command -v cygpath >/dev/null 2>&1; then
        WD_ABS=$(cygpath -w -- "$WD_ABS" 2>/dev/null || printf '')
      else
        WD_ABS=$(msys_to_drive "$WD_ABS")
      fi
      case "$WD_ABS" in
        [A-Za-z]:|[A-Za-z]:[/\\]*|"$WD_UNC"*) ;;
        *) WD_ABS="" ;;
      esac
    fi
  fi
  row worktrees_dir FAIL "WORKTREES_DIR=$WORKTREES_DIR is a relative path — it must be absolute (it resolves differently from a linked worktree than from the main checkout)" \
    "$(if [ -n "$WD_ABS" ]; then printf 'set WORKTREES_DIR=%s in .jst/jira-sdlc-tools.local.env' "$WD_ABS"; else printf 'set WORKTREES_DIR in .jst/jira-sdlc-tools.local.env to the absolute path of that directory (e.g. %s)' "$WD_EXAMPLE"; fi), then $RERUN."
fi

# .jst/bootstrap.sh (POSIX) / .jst/bootstrap.ps1 (Windows) is the optional,
# tracked hook a project writes to turn a fresh worktree into a *runnable*
# instance: clone the database, pick per-instance ports, install deps. See
# project-config.md and https://kantorv.github.io/jira-sdlc-tools/docs/running-multiple-copies
# (which carries three worked examples). Optional by design, so
# it is INFO either way — never WARN or FAIL, because most projects won't have
# one. This script only REPORTS it: jira-task-executor step 1 is what runs it,
# which keeps a broken hook visible in that run's transcript instead of
# swallowed in here, and keeps this script side-effect-free and role-agnostic.
# Tracked, so a linked worktree is born with it — resolve against CFG_DIR (this
# checkout's .jst/), not the main checkout.
if [ "$OS" = windows ]; then BOOTSTRAP_FILE=bootstrap.ps1; else BOOTSTRAP_FILE=bootstrap.sh; fi
if [ -f "$CFG_DIR/$BOOTSTRAP_FILE" ]; then
  row bootstrap INFO "$CFG_DIR/$BOOTSTRAP_FILE (present — jira-task-executor runs it in step 1)"
else
  row bootstrap INFO "no .jst/$BOOTSTRAP_FILE (optional — a project adds one to turn a fresh worktree into a runnable instance: clone the database, pick per-instance ports, install deps)"
fi

# The stack (onboarding: jst-survey writes .jst/STACK.md, jst-stack builds ./stack
# against stack contract v1; skills/_shared/stack/). Optional, so INFO — WARN only
# for a contract stack this script can't read, or an instance number another
# checkout holds. Never runs ./stack: reading files and the owner record only.
# A `toolchain` project (a library, CLI or scripts: nothing listening) gets no
# ./stack by design, only the bootstrap hook (jst-stack's STACK SKIPPED), so its
# row says so instead of pointing at jst-stack.
SD_PATTERN=""
if [ -f "$CFG_ROOT/.jst/STACK.md" ]; then
  SD_LAYOUT=$(grep -m1 -E '^\| *Repo layout *\|' "$CFG_ROOT/.jst/STACK.md" | grep -oE '`[a-z-]+`' | head -1 | tr -d '`')
  SD_PATTERN=$(grep -m1 -E '^\| *Run pattern *\|' "$CFG_ROOT/.jst/STACK.md" | grep -oE '`[a-z-]+`' | head -1 | tr -d '`')
  row stack_doc INFO ".jst/STACK.md (layout ${SD_LAYOUT:-?}, pattern ${SD_PATTERN:-?})"
else
  row stack_doc INFO "no .jst/STACK.md (optional — /jira-sdlc:jst-survey writes it, then /jira-sdlc:jst-stack builds the stack from it)"
fi
STACK_CONTRACT=""
if [ -f "$CFG_ROOT/stack" ]; then
  if [ "$(sed -n 2p "$CFG_ROOT/stack")" = "# controlfreak-stack-contract: 1" ]; then
    SC_CONF="$CFG_ROOT/stack.d/resources.conf"
    SC_PREFIX=$(sed -n 's/^NAME_PREFIX=//p' "$SC_CONF" 2>/dev/null | tail -1)
    SC_MIN=$(sed -n 's/^INSTANCE_MIN=//p' "$SC_CONF" 2>/dev/null | tail -1)
    SC_MAX=$(sed -n 's/^INSTANCE_MAX=//p' "$SC_CONF" 2>/dev/null | tail -1)
    if [ -n "$SC_PREFIX" ] && [ -n "$SC_MIN" ] && [ -n "$SC_MAX" ]; then
      STACK_CONTRACT=1
      row stack INFO "./stack (stack contract 1) · NAME_PREFIX=$SC_PREFIX · instances $SC_MIN-$SC_MAX"
    else
      row stack WARN "./stack has the contract marker, but stack.d/resources.conf lacks NAME_PREFIX, INSTANCE_MIN or INSTANCE_MAX" \
        "fix stack.d/resources.conf (or rerun /jira-sdlc:jst-stack), then $RERUN."
    fi
  else
    row stack INFO "./stack without the contract marker (the project's own: the executor starts no instance with it)"
  fi
elif [ "$SD_PATTERN" = toolchain ] && [ -f "$CFG_DIR/$BOOTSTRAP_FILE" ]; then
  row stack INFO "none needed (pattern toolchain: nothing to run; .jst/$BOOTSTRAP_FILE sets up each worktree)"
elif [ "$SD_PATTERN" = toolchain ]; then
  row stack INFO "none needed (pattern toolchain), but no .jst/$BOOTSTRAP_FILE yet — /jira-sdlc:jst-stack writes .jst/bootstrap.sh"
else
  row stack INFO "no ./stack (optional — /jira-sdlc:jst-stack builds one from .jst/STACK.md)"
fi
if [ -n "$STACK_CONTRACT" ] && [ -n "$IS_WORKTREE" ] && [ -n "$BR_KEY" ]; then
  if [ "$OS" = windows ]; then
    row instance INFO "not on Windows (stack contract v1 is bash: run the stack under WSL)"
  else
    IN_N=$(bash "$SC_DIR/instance.sh" number "$BR_KEY" --conf "$SC_CONF" 2>/dev/null | sed -n 's/^instance=//p')
    IN_OWNER=$(cat "$HOME/.local/state/$SC_PREFIX/i$IN_N/owner" 2>/dev/null || true)
    if [ -z "$IN_N" ]; then
      row instance WARN "no instance number for $BR_KEY (instance.sh number failed)" "check stack.d/resources.conf, then $RERUN."
    elif [ -z "$IN_OWNER" ]; then
      row instance INFO "N=$IN_N (from $BR_KEY) · not claimed yet (jira-task-executor claims it in step 1)"
    elif [ "$IN_OWNER" = "$(cd "$CFG_ROOT" && pwd -P)" ]; then
      row instance INFO "N=$IN_N (from $BR_KEY) · this worktree's · ./stack status --instance $IN_N"
    else
      row instance WARN "N=$IN_N (from $BR_KEY) is held by $IN_OWNER" \
        "two issues share N=$IN_N: tear down the other instance (./stack teardown --instance $IN_N there) or widen INSTANCE_MIN..INSTANCE_MAX, then $RERUN."
    fi
  fi
fi

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
