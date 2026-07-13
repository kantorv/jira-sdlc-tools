#!/usr/bin/env bash
# cleanup.sh — jira-sdlc post-merge cleanup.
#
# Per-issue worktrees and their local branches outlive the PRs they were
# created for: after a merged single-step PR or a fully-merged parent set,
# nothing removes them, and `git worktree list` slowly becomes an
# archaeology site. This script finds every worktree/branch whose work is
# *really* merged and prints ready-to-paste removal commands for each.
#
# It deletes NOTHING by default — that is the plugin's never-auto-delete
# policy, same as merging and issue deletion:
#   - default (dry-run) mode only detects and prints; `--apply` is the
#     single opt-in, and it must run from the MAIN checkout (never from a
#     linked worktree it might be about to remove). Dry-run works anywhere.
#   - only `git branch -d` semantics — never -D. A branch whose PR was
#     squash/rebase-merged (commits unreachable from any base) is reported
#     for manual review, not deleted.
#   - dirty worktrees (modified or untracked files) are skipped with the
#     reason, in both modes.
#   - the current branch, DEFAULT_BASE_BRANCH and PRODUCTION_BRANCH are
#     never candidates.
#   - remote branches are never deleted; merged ones get a
#     `git push origin --delete` suggestion to paste, which --apply
#     deliberately does not execute.
#   - a branch other work still builds on is protected even when merged:
#     skipped while it is the recorded parentbranch of an unmerged local
#     branch, or while any open PR on origin targets it as its base.
#   - a merged-looking *local* tip is not trusted on its own: skipped when
#     origin/<branch> has commits the base lacks (the local ref is merely
#     stale), and — when gh is available — when no PR exists at all (bare
#     ancestry can't tell finished work from a freshly provisioned branch).
#
# Detection keys on real merge state, never on branch names alone:
#   1. PR state via `gh pr view <branch> --json state,number` (when the
#      GitHub CLI is available and authenticated) — an OPEN PR always
#      disqualifies the branch;
#   2. git ancestry via `git merge-base --is-ancestor <branch> <base>`,
#      where <base> is tried as the recorded parentbranch
#      (`git config branch.<branch>.parentbranch` — what the assigner
#      stamps at worktree creation), then DEFAULT_BASE_BRANCH, then
#      PRODUCTION_BRANCH, preferring each one's origin/* ref so state
#      that only landed upstream still counts.
#
# Usage:
#   bash cleanup.sh            # dry run (default): detect + print commands
#   bash cleanup.sh --apply    # execute the safe removals (main checkout only)
#
# Config: resolves PROJECT-KEY / DEFAULT_BASE_BRANCH / PRODUCTION_BRANCH
# from jira-sdlc-tools.env + jira-sdlc-tools.local.env in the repo root
# (local overrides team; see ../project-config.md). The files use
# `NAME = value` lines, so they are parsed, not sourced. Only branches
# named feature/<PROJECT-KEY>-* or hotfix/<PROJECT-KEY>-* are considered.
#
# Exit code: 0 = ran to completion (candidates found or not); 1 = a
# precondition failed, or an --apply removal command failed.

set -u

MODE=detect
for arg in "$@"; do
  case "$arg" in
    --apply) MODE=apply ;;
    -h|--help)
      awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
      exit 0 ;;
    *)
      echo "cleanup.sh: unknown argument '$arg' (only --apply is accepted)" >&2
      exit 1 ;;
  esac
done

die() { echo "cleanup.sh: $1" >&2; exit 1; }

WT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "not inside a git repository (cwd: $PWD)"
# A linked worktree's .git is a *file* (pointer into the main repo's
# .git/worktrees/); the main checkout's .git is a directory.
IS_WORKTREE=""
[ -f "$WT_ROOT/.git" ] && IS_WORKTREE=1
if [ "$MODE" = apply ] && [ -n "$IS_WORKTREE" ]; then
  die "--apply must run from the MAIN checkout, not a linked worktree (it may be about to remove the very worktree you're standing in). Dry-run works from anywhere."
fi

# --- project config (same parse-not-source convention as statuscheck.sh) ---
CFG_DIR="$WT_ROOT"
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

PROJECT_KEY=$(cfg 'PROJECT[-_]KEY' || true)
BASE_BRANCH=$(cfg DEFAULT_BASE_BRANCH || true)
PROD_BRANCH=$(cfg PRODUCTION_BRANCH || true)
[ -n "$PROJECT_KEY" ] \
  || die "PROJECT-KEY unset — check jira-sdlc-tools.env in the project root (see skills/_shared/project-config.md)"

CUR_BRANCH=$(git branch --show-current 2>/dev/null || true)

# Fresh origin refs make the ancestry checks trustworthy; a failed fetch
# (offline) degrades to possibly-stale local refs, flagged in the header.
FETCH_NOTE=""
git fetch --quiet origin 2>/dev/null || FETCH_NOTE="(offline? 'git fetch origin' failed — merge state may be stale)"

GH_OK=""
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && GH_OK=1

# Base branches of PRs still open on origin — one call, consulted per
# candidate so a parent branch with live child PRs is never suggested.
OPEN_PR_BASES=" "
[ -n "$GH_OK" ] && OPEN_PR_BASES=" $(gh pr list --state open --json baseRefName --jq '.[].baseRefName' 2>/dev/null | tr '\n' ' ') "

# branch.<child>.parentbranch pairs, for the local child-protection guard.
PARENT_PAIRS=$(git config --get-regexp '^branch\..*\.parentbranch$' 2>/dev/null || true)

# --- classification --------------------------------------------------------
# merged_ref <branch> — set MERGED_REF to the first base ref the branch tip
# is an ancestor of (recorded parentbranch, then DEFAULT_BASE_BRANCH, then
# PRODUCTION_BRANCH; origin/* preferred) and return 0, or return 1 if none.
# Also sets BASES_TRIED to the ref list consulted, for skip messages.
merged_ref() {
  local br="$1" parent cand seen ref refs=()
  parent=$(git config "branch.$br.parentbranch" 2>/dev/null || true)
  seen=" "
  for cand in $parent $BASE_BRANCH $PROD_BRANCH; do
    case "$seen" in *" $cand "*) continue ;; esac
    seen="$seen$cand "
    for ref in "origin/$cand" "$cand"; do
      git rev-parse -q --verify "refs/remotes/$ref" >/dev/null 2>&1 \
        || git rev-parse -q --verify "refs/heads/$ref" >/dev/null 2>&1 \
        || continue
      refs+=("$ref")
    done
  done
  BASES_TRIED="${refs[*]:-}"
  MERGED_REF=""
  for ref in ${refs[@]+"${refs[@]}"}; do
    if git merge-base --is-ancestor "$br" "$ref" 2>/dev/null; then
      MERGED_REF="$ref"
      return 0
    fi
  done
  return 1
}

# classify <branch> sets:
#   VERDICT  ready | skip
#   NOTE     for ready: what proved the merge; for skip: the reason
classify() {
  local br="$1" pr_state="" pr_num="" pr_json ckey cparent child

  if [ "$br" = "$CUR_BRANCH" ]; then
    VERDICT=skip NOTE="currently checked-out branch here"; return
  fi
  if [ -n "$BASE_BRANCH" ] && [ "$br" = "$BASE_BRANCH" ]; then
    VERDICT=skip NOTE="is DEFAULT_BASE_BRANCH"; return
  fi
  if [ -n "$PROD_BRANCH" ] && [ "$br" = "$PROD_BRANCH" ]; then
    VERDICT=skip NOTE="is PRODUCTION_BRANCH"; return
  fi

  if [ -n "$GH_OK" ]; then
    pr_json=$(gh pr view "$br" --json state,number 2>/dev/null || true)
    if [ -n "$pr_json" ]; then
      pr_state=$(printf '%s' "$pr_json" | grep -oE '"state":[[:space:]]*"[A-Z]+"' | grep -oE '[A-Z]+' | tail -1 || true)
      pr_num=$(printf '%s' "$pr_json" | grep -oE '"number":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | tail -1 || true)
    fi
  fi
  if [ "$pr_state" = "OPEN" ]; then
    VERDICT=skip NOTE="PR #${pr_num} is still OPEN"; return
  fi

  # Other work may still build on this branch — protect it even if merged.
  case "$OPEN_PR_BASES" in *" $br "*)
    VERDICT=skip NOTE="open PR(s) on origin still target this branch as their base"; return ;;
  esac
  while read -r ckey cparent; do
    [ "$cparent" = "$br" ] || continue
    child=${ckey#branch.}; child=${child%.parentbranch}
    [ "$child" = "$br" ] && continue
    git rev-parse -q --verify "refs/heads/$child" >/dev/null 2>&1 || continue
    if ! merged_ref "$child"; then
      VERDICT=skip NOTE="still the recorded parentbranch of unmerged local branch $child"; return
    fi
  done <<EOF
$PARENT_PAIRS
EOF

  if merged_ref "$br"; then
    if git rev-parse -q --verify "refs/remotes/origin/$br" >/dev/null 2>&1 \
       && ! git merge-base --is-ancestor "refs/remotes/origin/$br" "$MERGED_REF" 2>/dev/null; then
      VERDICT=skip NOTE="local tip is in $MERGED_REF, but origin/$br has newer commits that aren't — the local ref is just stale, the branch isn't finished"
    elif [ -n "$GH_OK" ] && [ -z "$pr_num" ]; then
      VERDICT=skip NOTE="tip is in $MERGED_REF but no PR exists for this branch — can't tell finished work from a freshly provisioned branch; remove manually if you know it shipped"
    else
      VERDICT=ready NOTE="merged into $MERGED_REF${pr_num:+; PR #$pr_num $pr_state}"
    fi
  elif [ "$pr_state" = "MERGED" ]; then
    VERDICT=skip NOTE="PR #${pr_num} MERGED but commits unreachable from ${BASES_TRIED:-any base} (squash/rebase merge?) — verify by hand; removal needs -D, which this script never uses"
  else
    VERDICT=skip NOTE="not merged into ${BASES_TRIED:-any base}${pr_num:+ (PR #$pr_num $pr_state)}"
  fi
}

# --- gather: linked worktrees on this project's issue branches --------------
READY_WT=()      # path<TAB>branch<TAB>note
READY_BR=()      # branch<TAB>note
SKIPPED=()       # display lines
PRUNABLE=0
SCANNED_WT=0
SCANNED_BR=0
WT_BRANCHES=" "  # branches already handled via a worktree

wt_path="" wt_branch=""
finish_wt() {
  [ -n "$wt_path" ] || return 0
  if [ "$wt_path" = "$WT_ROOT" ]; then                       # this checkout
    case "$wt_branch" in
      feature/"$PROJECT_KEY"-*|hotfix/"$PROJECT_KEY"-*)
        WT_BRANCHES="$WT_BRANCHES$wt_branch "
        SKIPPED+=("$wt_path ($wt_branch): the checkout this run is executing from") ;;
    esac
    wt_path=""; return 0
  fi
  [ -f "$wt_path/.git" ] || { wt_path=""; return 0; }        # main checkout seen from a worktree
  case "$wt_branch" in
    feature/"$PROJECT_KEY"-*|hotfix/"$PROJECT_KEY"-*) ;;
    "") SKIPPED+=("$wt_path: detached HEAD — not an issue-branch worktree"); wt_path=""; return 0 ;;
    *)  wt_path=""; return 0 ;;                              # not this project's
  esac
  SCANNED_WT=$((SCANNED_WT + 1))
  WT_BRANCHES="$WT_BRANCHES$wt_branch "
  local dirty
  dirty=$(git -C "$wt_path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  classify "$wt_branch"
  if [ "$VERDICT" = ready ] && [ "${dirty:-0}" -gt 0 ]; then
    VERDICT=skip NOTE="merged, but the worktree has $dirty uncommitted change(s) — inspect it before removing anything"
  fi
  if [ "$VERDICT" = ready ]; then
    READY_WT+=("$wt_path	$wt_branch	$NOTE")
  else
    SKIPPED+=("$wt_path ($wt_branch): $NOTE")
  fi
  wt_path=""
}

while IFS= read -r line; do
  case "$line" in
    worktree\ *) finish_wt; wt_path=${line#worktree }; wt_branch="" ;;
    branch\ refs/heads/*) wt_branch=${line#branch refs/heads/} ;;
    prunable*) PRUNABLE=$((PRUNABLE + 1)); wt_path="" ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null)
finish_wt

# --- gather: issue branches with no worktree --------------------------------
while IFS= read -r br; do
  case "$WT_BRANCHES" in *" $br "*) continue ;; esac
  SCANNED_BR=$((SCANNED_BR + 1))
  classify "$br"
  if [ "$VERDICT" = ready ]; then
    READY_BR+=("$br	$NOTE")
  else
    SKIPPED+=("branch $br (no worktree): $NOTE")
  fi
done < <(git for-each-ref --format='%(refname:short)' \
           "refs/heads/feature/$PROJECT_KEY-*" "refs/heads/hotfix/$PROJECT_KEY-*" 2>/dev/null)

# --- report ------------------------------------------------------------------
if [ "$MODE" = apply ]; then
  echo "## jira-sdlc cleanup — APPLY (removing safely-merged worktrees/branches)"
else
  echo "## jira-sdlc cleanup — dry run (nothing deleted)"
fi
echo
echo "Scanned $SCANNED_WT linked worktree(s) and $SCANNED_BR loose local branch(es) matching feature/$PROJECT_KEY-* or hotfix/$PROJECT_KEY-*. $FETCH_NOTE"
[ -z "$GH_OK" ] && echo "Note: gh unavailable/unauthenticated — PR state not consulted; detection used git ancestry only."

APPLY_FAILED=0
run_or_print() { # run_or_print <description> <cmd...>
  local desc="$1"; shift
  if [ "$MODE" = apply ]; then
    if "$@"; then
      echo "✓ $desc"
    else
      echo "✗ FAILED: $desc — left as-is (fix by hand; this script never escalates to --force/-D)"
      APPLY_FAILED=1
    fi
  fi
}

if [ ${#READY_WT[@]} -eq 0 ] && [ ${#READY_BR[@]} -eq 0 ]; then
  echo
  echo "### Nothing is safely removable right now"
else
  echo
  if [ "$MODE" = apply ]; then
    echo "### Removing (merged, clean)"
  else
    echo "### Merged — safe to remove (paste from the main checkout)"
  fi
  echo
  REMOTE_SUGGEST=()
  for entry in ${READY_WT[@]+"${READY_WT[@]}"}; do
    p=${entry%%	*}; rest=${entry#*	}; b=${rest%%	*}; n=${rest#*	}
    echo "# $(basename "$p") — $b ($n)"
    echo "git worktree remove '$p' && git branch -d '$b'"
    run_or_print "worktree $p removed" git worktree remove "$p" \
      && run_or_print "branch $b deleted" git branch -d "$b"
    git rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1 \
      && REMOTE_SUGGEST+=("$b")
    echo
  done
  for entry in ${READY_BR[@]+"${READY_BR[@]}"}; do
    b=${entry%%	*}; n=${entry#*	}
    echo "# $b — no worktree ($n)"
    echo "git branch -d '$b'"
    run_or_print "branch $b deleted" git branch -d "$b"
    git rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1 \
      && REMOTE_SUGGEST+=("$b")
    echo
  done
  if [ ${#REMOTE_SUGGEST[@]} -gt 0 ]; then
    echo "Optional — their merged remote branches (manual paste only; --apply never runs these):"
    for b in ${REMOTE_SUGGEST[@]+"${REMOTE_SUGGEST[@]}"}; do
      echo "git push origin --delete '$b'"
    done
    echo
  fi
fi

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo
  echo "### Skipped — not touched"
  echo
  for s in ${SKIPPED[@]+"${SKIPPED[@]}"}; do
    echo "- $s"
  done
fi

[ "$PRUNABLE" -gt 0 ] && { echo; echo "Note: $PRUNABLE prunable worktree entr(y/ies) (directory already gone) — run 'git worktree prune' to clear the metadata."; }

echo
if [ "$MODE" = apply ]; then
  [ "$APPLY_FAILED" -ne 0 ] && exit 1
elif [ ${#READY_WT[@]} -gt 0 ] || [ ${#READY_BR[@]} -gt 0 ]; then
  echo "Paste the commands above, or re-run with --apply from the main checkout to execute them."
fi
exit 0
