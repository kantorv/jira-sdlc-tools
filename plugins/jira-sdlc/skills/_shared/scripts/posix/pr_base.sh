#!/usr/bin/env bash
# pr_base.sh — resolve the PR base branch for the leaf issue this branch belongs to.
#
# Usage:  bash pr_base.sh --role <role> [--branch <BRANCH>]
#                         [--parent-key <PARENT-KEY>] [ISSUE-KEY]
#         --role        executor|assigner|reviewer. Required — jira.sh has no
#                       default credential (jira-api-reference.md §9) — and also
#                       read from $JIRA_ROLE when the flag is absent.
#         --branch      resolve the base for THIS branch instead of the one
#                       checked out. The reviewer needs it: from a sub-task's
#                       worktree it resolves <PARENT-BRANCH>'s base, and the
#                       checked-out branch is the sub-task's, whose parentbranch
#                       is <PARENT-BRANCH> — not the base. Branch config lives
#                       in the shared .git/config, so this works from any
#                       worktree. Defaults to the current branch.
#         --parent-key  the leaf's fields.parent.key from the issue fetch (§10).
#                       Absent/empty means a top-level issue, which is the only
#                       thing that makes the env default reachable.
#         ISSUE-KEY     defaults to the key derived from --branch (or, absent
#                       that, the current branch): feature/<KEY>-<slug> /
#                       hotfix/<KEY>-<slug>, as statuscheck.sh and
#                       check_assignee.sh do.
#
# The implementation of jira-api-reference.md §13 — that section documents this
# script rather than restating it, so a fix lands in one place instead of in
# every skill that hand-copied the resolver. Sources, in order:
#   1. git config branch.<branch>.parentbranch — set by the assigner, local to
#      this clone.
#   2. the issue's `PR target branch: …` Jira comment (§11) — the durable
#      fallback, survives a fresh clone.
#   3. a search for the parent's branch — SUB-TASKS ONLY, and only decisive when
#      it matches exactly one branch.
#   4. DEFAULT_BASE_BRANCH from .jst/jira-sdlc-tools.env — TOP-LEVEL ISSUES ONLY.
#      A sub-task's base is its parent's branch, never the env default; that is
#      the mistake this resolver exists to prevent.
#
# stdout — always exactly two lines, so the caller can read both facts:
#   base=<branch>   (empty when unresolved)
#   source=git-config|jira-comment|branch-search|env-default|unresolved
#
# Exit 0 — resolved. The caller still decides what to do with it: a branch-search
#          or env-default win is worth naming in the run report, and the
#          prefix/base sanity check (§13) is the caller's, not this script's.
# Exit 1 — unresolved: a sub-task whose parent-branch search matched zero or
#          several branches. STOP, ask the user, do not open the PR.
# Exit 2 — usage or environment error (no --role, not a git repo, no issue key).

set -u

die() { printf '%s\n' "$*" >&2; exit 2; }
warn() { printf '%s\n' "$*" >&2; }

# --- args: --role, optional --branch/--parent-key, optional ISSUE-KEY --------
ROLE="${JIRA_ROLE:-}"
PARENT_KEY=""
KEY=""
BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role)         ROLE="${2:-}"; shift 2 ;;
    --role=*)       ROLE="${1#--role=}"; shift ;;
    --branch)       BRANCH="${2:-}"; shift 2 ;;
    --branch=*)     BRANCH="${1#--branch=}"; shift ;;
    --parent-key)   PARENT_KEY="${2:-}"; shift 2 ;;
    --parent-key=*) PARENT_KEY="${1#--parent-key=}"; shift ;;
    *)              KEY="$1"; shift ;;
  esac
done
[ -n "$ROLE" ] || die "pr_base: --role is required (executor|assigner|reviewer) — jira.sh has no default credential."

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JIRA_SH="$SCRIPT_DIR/jira.sh"

if [ -n "$BRANCH" ]; then
  CUR="$BRANCH"
else
  CUR=$(git branch --show-current 2>/dev/null || true)
  [ -n "$CUR" ] || die "pr_base: not on a branch in a git repo — run this from the issue's worktree, or name one with --branch."
fi

if [ -z "$KEY" ]; then
  BR_TAIL=${CUR#*/}
  KEY=$(printf '%s' "$BR_TAIL" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)
  [ -n "$KEY" ] || die "pr_base: no issue key derivable from branch '$CUR' — expected feature/<KEY>-<slug> or hotfix/<KEY>-<slug>. Run from the issue's worktree, or pass the key."
fi

emit() { printf 'base=%s\nsource=%s\n' "$1" "$2"; }

# --- 1. git config -----------------------------------------------------------
PR_BASE=$(git config branch."$CUR".parentbranch 2>/dev/null || true)
if [ -n "$PR_BASE" ]; then emit "$PR_BASE" git-config; exit 0; fi

# --- 2. the durable `PR target branch: …` Jira comment (§11) -----------------
COMMENTS=$(bash "$JIRA_SH" --role "$ROLE" issue comment list "$KEY" 2>/dev/null) \
  || warn "pr_base: could not read $KEY's comments as role '$ROLE' — skipping the 'PR target branch:' fallback."
PR_BASE=$(printf '%s' "$COMMENTS" \
  | grep -oE 'PR target branch: [^" ]+' | head -1 \
  | sed -e 's/PR target branch: //' -e 's/\.$//')
if [ -n "$PR_BASE" ]; then emit "$PR_BASE" jira-comment; exit 0; fi

# --- 3. parent-branch search — a leaf that HAS a parent, i.e. a sub-task -----
# Normalize before counting, or one branch reads as several and looks "ambiguous":
# strip BOTH markers `git branch -a` emits — `*` (checked out here) and `+`
# (checked out in another linked worktree, the normal state of a parent branch
# while a sub-task's worktree runs this search) — and fold the remotes/origin/
# copy of a pushed branch into its local name (§12).
if [ -n "$PARENT_KEY" ]; then
  CANDIDATES=$(git branch -a --list "*feature/$PARENT_KEY-*" "*hotfix/$PARENT_KEY-*" 2>/dev/null \
    | sed -E 's#^[+* ]+##; s#^remotes/origin/##' | sort -u)
  MATCHES=$(printf '%s' "$CANDIDATES" | grep -c . || true)
  if [ "$MATCHES" -eq 1 ]; then emit "$CANDIDATES" branch-search; exit 0; fi
  emit "" unresolved
  warn "pr_base: $KEY is a sub-task of $PARENT_KEY and the parent-branch search matched $MATCHES branches, not 1. STOP and ask the user which branch is the base — a sub-task's base is its parent's branch, never the env default."
  exit 1
fi

# --- 4. the env default — top-level issues only ------------------------------
CFG_DIR=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")/.jst
cfg() {
  local f v
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$CFG_DIR/$f" ] || continue
    v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$CFG_DIR/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}
PR_BASE=$(cfg DEFAULT_BASE_BRANCH || true)
if [ -n "$PR_BASE" ]; then emit "$PR_BASE" env-default; exit 0; fi

emit "" unresolved
warn "pr_base: no base resolved for $KEY and DEFAULT_BASE_BRANCH is unset in .jst/jira-sdlc-tools.env. STOP and ask the user which branch is the base."
exit 1
