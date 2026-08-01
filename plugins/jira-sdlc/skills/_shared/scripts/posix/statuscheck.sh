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

WT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
IS_WORKTREE=""
# A linked worktree's .git is a *file* (pointer into the main repo's
# .git/worktrees/); the main checkout's .git is a directory.
if [ -n "$WT_ROOT" ] && [ -f "$WT_ROOT/.git" ]; then
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
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  if ! bash "$SCRIPT_DIR/ensure_local_env.sh" >/dev/null 2>&1; then
    row env_local FAIL "mandatory .jst/jira-sdlc-tools.local.env missing — not in this worktree and not copyable from the main repo" \
      "create .jst/jira-sdlc-tools.local.env in the main checkout first (Jira URL/email/token — see skills/_shared/project-config.md), then $RERUN."
    print_report
    exit 1
  fi
  if [ -z "$PRE_EXISTED" ] && [ -n "$IS_WORKTREE" ] && [ -f "$WT_ROOT/.jst/jira-sdlc-tools.local.env" ]; then
    ENV_LOCAL_COPIED=1
    GITDIR=$(sed -n 's/^gitdir: //p' "$WT_ROOT/.git" 2>/dev/null || true)
    ENV_LOCAL_COPIED_FROM=$(dirname "$(dirname "$(dirname "$GITDIR")")" 2>/dev/null || true)
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
  row env_config FAIL "jira-sdlc-tools.env not found in $CFG_DIR" \
    "create jira-sdlc-tools.env in the project's .jst/ folder (variables described in skills/_shared/project-config.md), then $RERUN."
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
      "git rm --cached .jst/jira-sdlc-tools.local.env, add it to .gitignore, and rotate the leaked Jira token before anything else."
  elif git -C "$CFG_ROOT" check-ignore -q .jst/jira-sdlc-tools.local.env 2>/dev/null; then
    row env_local_ignored OK "gitignored (never committed)"
  else
    row env_local_ignored FAIL ".jst/jira-sdlc-tools.local.env is NOT gitignored — committing it would leak the account email and credential path" \
      "add .jst/jira-sdlc-tools.local.env to .gitignore first, then $RERUN."
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

# --- gh auth (needed by 'gh pr create') ----------------------------------
# Log gh in from a persistent PAT session at the very start of the run — logout
# FIRST, then login — so the whole conversation holds a KNOWN-GOOD session. The
# logout is load-bearing: a bare `gh auth login` does not reliably replace an
# already-stored keyring token, so a stale PR-read-only PAT from the developer's
# own session could otherwise survive and 403 at `gh pr create` mid-run, after
# the work is done (JST-143). gh uses ONE shared PAT (not a per-role Jira
# identity), so this
# role-agnostic healthcheck — which every skill already runs before any work — is
# the right home for it: no per-skill wiring needed. GITHUB_PAT_TOKEN is a secret,
# machine-specific value → gitignored .jst/jira-sdlc-tools.local.env only (never
# the tracked .jst/jira-sdlc-tools.env), same treatment as the Jira role tokens. Missing token →
# FAIL with a remedy, and the skill stops like any other FAIL row. A login that
# runs but FAILs (non-zero exit — an expired or revoked PAT, etc.) also FAILs,
# relaying gh's first stderr line (token redacted) rather than falling through to
# a generic "no session" — so the actual auth error is named (JST-145 AC#3).
# Accepted tradeoff: this writes ~/.config/gh/hosts.yml, global to the OS user,
# so it overwrites the developer's own gh session and is not restored afterward —
# see plugins/jira-sdlc/docs/github/ (JST-126/145).
GH_OK=""
if ! command -v gh >/dev/null 2>&1; then
  row gh_auth FAIL "gh (GitHub CLI) is not installed" \
    "install it (https://cli.github.com), then $RERUN."
else
  GH_PAT=$(cfg GITHUB_PAT_TOKEN || true)
  # cfg parses rather than sources the env file, so a quoted value keeps its
  # quotes — strip one surrounding pair before handing the token to gh.
  GH_PAT=${GH_PAT#\"}; GH_PAT=${GH_PAT%\"}
  GH_PAT=${GH_PAT#\'}; GH_PAT=${GH_PAT%\'}
  if [ -z "$GH_PAT" ]; then
    row gh_auth FAIL "GITHUB_PAT_TOKEN is unset — gh can't be logged in for this session" \
      "add GITHUB_PAT_TOKEN to .jst/jira-sdlc-tools.local.env (a fine-grained GitHub PAT; see .jst/jira-sdlc-tools.local.env.example and plugins/jira-sdlc/docs/github/), then $RERUN."
  else
    # logout FIRST — see header; non-fatal if there's nothing to log out.
    $TMOUT_CMD gh auth logout --hostname github.com >/dev/null 2>&1 || true
    # Login: capture gh's stderr separately. gh never echoes the token on error,
    # but we redact it anyway (issue NOTES) before relaying. A FAILED login now
    # FAILs the row with gh's own first error line instead of falling through to
    # the generic "no session" FAIL — so a real auth failure (expired/revoked
    # PAT, etc.) is named, not buried (JST-145 AC#3). Success exits 0 with no
    # stderr; only then do we run 'gh auth status' for the account line.
    if LOGIN_ERR=$(printf '%s\n' "$GH_PAT" | $TMOUT_CMD gh auth login --with-token 2>&1 >/dev/null); then
      GH_LINE=$($TMOUT_CMD gh auth status 2>&1 | grep -m1 'Logged in to' | sed 's/^[^L]*//' || true)
      if [ -n "$GH_LINE" ]; then
        GH_OK=1
        row gh_auth OK "$GH_LINE (PAT session login)"
      else
        row gh_auth FAIL "gh auth login succeeded but 'gh auth status' reports no logged-in account" \
          "gh reported a successful login but no active session — inspect 'gh auth status' by hand, then $RERUN."
      fi
    else
      ERR=$(printf '%s' "${LOGIN_ERR//"$GH_PAT"/[REDACTED]}" \
        | awk 'NF{sub(/^[[:space:]]+/,""); sub(/[[:space:]]+$/,""); print; exit}')
      [ "${ERR:-}" ] || ERR='(no stderr from gh)'
      row gh_auth FAIL "gh auth login --with-token failed: $ERR" \
        "check that GITHUB_PAT_TOKEN in .jst/jira-sdlc-tools.local.env is a valid, non-expired GitHub PAT (gh error above); then $RERUN."
    fi
  fi
fi

# --- gh repo access (needed by 'gh pr create', not proved by gh_auth) ------
# gh_auth proves a LOGIN succeeded and nothing more. A fine-grained PAT scoped
# to "only selected repositories" logs in happily, reads the org and 20 other
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
  row gh_repo_access WARN "skipped (gh_auth failed — the repo probe needs a logged-in gh; see rows above)"
elif ! GH_SLUG=$(gh_slug "$ORIGIN_URL"); then
  row gh_repo_access WARN "origin is not a github.com remote ($ORIGIN_URL) — can't probe it with gh, and 'gh pr create' won't work against it"
elif GH_API_ERR=$($TMOUT_CMD gh api "repos/$GH_SLUG" 2>&1 >/dev/null); then
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
# WARN rather than mkdir-ing); a relative value is relative to the MAIN
# checkout root (see project-config.md), not to a linked worktree that may
# itself live inside that directory.
WORKTREES_DIR=$(cfg WORKTREES_DIR || true)
if [ -z "$WORKTREES_DIR" ]; then
  row worktrees_dir WARN "WORKTREES_DIR unset in .jst/jira-sdlc-tools(.local).env"
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
    row worktrees_dir WARN "$WD_PATH missing — the assigner won't create it; check WORKTREES_DIR in .jst/jira-sdlc-tools.env if the convention changed"
  fi
fi

# .jst/bootstrap.sh (POSIX) / .jst/bootstrap.ps1 (Windows) is the optional,
# tracked hook a project writes to turn a fresh worktree into a *runnable*
# instance: clone the database, pick per-instance ports, install deps. See
# project-config.md and docs/RUNNING-MULTIPLE-COPIES.md. Optional by design, so
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
