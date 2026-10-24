#!/usr/bin/env bash
# repos.sh — the set of repos an issue's work spans, behind one front door.
#
# A project is one repo (the "single" strategy) or a parent repo holding member
# repos as git submodules (the "submodules" strategy). The skills call this
# script for repo work and act on its output; which strategy applies, and what
# it means for each verb, lives in strategies/<name>.sh. A single-repo project
# is a set of one, so the same skill sentence covers both. Design:
# https://kantorv.github.io/jira-sdlc-tools/docs/proposals/submodules-strategy
#
# Usage: bash repos.sh <verb> [--branch <b>] [--state all|open] [--base <b>]
#                              [--check] [--multistep]
#   strategy  which strategy applies — key=value lines:
#               strategy=single|submodules
#               root=<project root>
#               members=<paths, space-separated; empty for single>
#               pinned=<top-level submodules that aren't members>
#   list      one row per repo in the set, root first — tab-separated, with a
#             header: repo role initialized slug base branch dirty ahead.
#             Local facts only: no network.
#   prs       every PR whose head is --branch (default: the root's current
#             branch), in every repo of the set — tab-separated, with a header:
#             repo slug pr state base url. One row per PR; `none` when a repo
#             has none; `error` when it couldn't be looked up (exit 4). --state
#             open keeps only OPEN ones. The query is the one rule for reading
#             PRs (JST-310): --head is the bare branch name, every state, no
#             --base — `gh` answers a filter that misses with `[]`, not an
#             error, so a narrowed query reads an open PR as none — and an
#             empty answer is asked twice before it counts as none.
#   gate      the phase of --branch's PR set — key=value lines (phase, reason,
#             root, members), then the prs table. phase is one of: none,
#             review, land, review-landing, merged, stop (reason says why).
#             --base is the root PR's expected base (default
#             DEFAULT_BASE_BRANCH); a member's is its own base. --multistep:
#             the issue has Jira sub-tasks.
#   land      move each member's gitlink to its merged PR's commit on the
#             member's base, commit, push and open (or reuse) the root's PR.
#             Run from the issue worktree, on --branch. Checks everything
#             before it changes anything. --check instead verifies the
#             gitlinks --branch carries: each on its member's base, and
#             .gitmodules unchanged against --base.
#
# The strategy comes from JST_MEMBERS in .jst/jira-sdlc-tools.env: the
# submodule paths that take part in issues. Unset or empty → single, whether or
# not the project has submodules (unlisted ones stay pinned); set → submodules.
#
# Exit 0 — ok (for gate, every phase, `stop` included: it's a decision).
# Exit 1 — land refused or failed, or land --check found a bad gitlink:
#          `error=<reason>` (land) or a failing row (--check) on stdout.
# Exit 2 — usage error (message on stderr, nothing on stdout), or JST_MEMBERS
#          is invalid: stdout then ends with an `error=<reason>` line, which
#          statuscheck's repo_strategy row relays.
# Exit 4 — prs couldn't look up at least one repo: unknown, never none.
#
# win/repos.ps1 is the twin: same arguments, output and exit codes.

set -u
SC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SC_DIR/_jst_root.sh"

die_usage() { printf '%s\n' "repos: $1" >&2; exit 2; }

VERBS="strategy, list, prs, gate, land"
VERB="${1:-}"
case "$VERB" in
  strategy|list|prs|gate|land) shift ;;
  "") die_usage "a verb is required — one of: $VERBS" ;;
  *)  die_usage "unknown verb '$VERB' — one of: $VERBS" ;;
esac
OPT_BRANCH="" OPT_STATE=all OPT_BASE="" OPT_CHECK="" OPT_MULTISTEP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --branch)    OPT_BRANCH="${2:-}"; shift 2 ;;
    --branch=*)  OPT_BRANCH="${1#--branch=}"; shift ;;
    --state)     OPT_STATE="${2:-}"; shift 2 ;;
    --state=*)   OPT_STATE="${1#--state=}"; shift ;;
    --base)      OPT_BASE="${2:-}"; shift 2 ;;
    --base=*)    OPT_BASE="${1#--base=}"; shift ;;
    --check)     OPT_CHECK=1; shift ;;
    --multistep) OPT_MULTISTEP=1; shift ;;
    *) die_usage "unknown argument '$1'" ;;
  esac
done
case "$OPT_STATE" in all|open) ;; *) die_usage "--state must be all or open (got '$OPT_STATE')" ;; esac

ROOT=$(jst_root) || die_usage "not inside a git repository"
CFG_DIR="$ROOT/.jst"

# Same `NAME = value` parser as the other scripts: local.env overrides .env,
# the last match in a file wins, values are parsed, never sourced.
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

# --- helpers the strategies share ---------------------------------------------

# gh_slug <remote-url> -> OWNER/REPO; non-zero when not github.com (statuscheck's rule).
gh_slug() {
  local u="$1" s
  case "$u" in *github.com*) ;; *) return 1 ;; esac
  s=${u#*github.com}
  s=${s#:}; s=${s#/}; s=${s%/}; s=${s%.git}
  printf '%s' "$s" | grep -qE '^[^/]+/[^/]+$' || return 1
  printf '%s' "$s"
}

# resolve_url <base-url> <url> — a .gitmodules URL, with git's relative form
# (./x, ../x) resolved against the root's origin. Absolute URLs pass through.
resolve_url() {
  local base="$2" rel
  case "$2" in ./*|../*) ;; *) printf '%s' "$2"; return 0 ;; esac
  base="$1"; rel="$2"
  base=${base%/}
  while :; do
    case "$rel" in
      ./*)  rel=${rel#./} ;;
      ../*) rel=${rel#../}
            case "$base" in */*) base=${base%/*} ;; *:*) base=${base%%:*}: ;; esac ;;
      *) break ;;
    esac
  done
  case "$base" in *:) printf '%s%s' "$base" "$rel" ;; *) printf '%s/%s' "$base" "$rel" ;; esac
}

# submodules — "<name>\t<path>" per top-level submodule, in .gitmodules order.
# Names may contain dots, hence the greedy match.
submodules() {
  [ -f "$ROOT/.gitmodules" ] || return 0
  git config -f "$ROOT/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | sed -E 's/^submodule\.(.*)\.path (.*)$/\1\t\2/'
}

# repo_row <path> <role> <base> <dirty-flags> — one `list` row for a checked-out repo.
repo_row() {
  local p="$1" dir branch dirty ahead slug url
  dir="$ROOT"; [ "$p" = . ] || dir="$ROOT/$p"
  # The configured URL, not `remote get-url`'s: that one applies url.*.insteadOf
  # rewrites, and the slug names the GitHub repo, not where fetches go.
  url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)
  slug=$(gh_slug "$url" 2>/dev/null) || slug=-
  branch=$(git -C "$dir" branch --show-current 2>/dev/null || true)
  [ -n "$branch" ] || branch="(detached)"
  # shellcheck disable=SC2086  # $4 is a deliberate list of flags
  if [ -n "$(git -C "$dir" status --porcelain $4 2>/dev/null)" ]; then dirty=yes; else dirty=no; fi
  ahead=$(git -C "$dir" rev-list --count '@{u}..HEAD' 2>/dev/null) || ahead=-
  printf '%s\t%s\tyes\t%s\t%s\t%s\t%s\t%s\n' "$p" "$2" "$slug" "$3" "$branch" "$dirty" "$ahead"
}

LIST_HEADER=$(printf 'repo\trole\tinitialized\tslug\tbase\tbranch\tdirty\tahead')
BASE_BRANCH=$(cfg DEFAULT_BASE_BRANCH || true)
MEMBERS_CFG=$(cfg JST_MEMBERS || true)

if [ -n "$MEMBERS_CFG" ]; then STRATEGY=submodules; else STRATEGY=single; fi
. "$SC_DIR/strategies/$STRATEGY.sh"

# --- the PR verbs (prs, gate, land) -------------------------------------------
# They work on the repo set — the root, plus members when the strategy has
# them — so a single repo is just a set without members, not another branch of
# code. Network calls go through gh with the same PAT statuscheck logs in.

PRS_HEADER=$(printf 'repo\tslug\tpr\tstate\tbase\turl')
TMOUT_CMD=""; command -v timeout >/dev/null 2>&1 && TMOUT_CMD="timeout 30"
ERRF=$(mktemp "${TMPDIR:-/tmp}/repos-err.XXXXXX"); trap 'rm -f "$ERRF"' EXIT
ROOT_BASE="${OPT_BASE:-$BASE_BRANCH}"

need_branch() {
  [ -n "$OPT_BRANCH" ] || OPT_BRANCH=$(git -C "$ROOT" branch --show-current 2>/dev/null || true)
  [ -n "$OPT_BRANCH" ] || die_usage "no branch: the root is on a detached HEAD — pass --branch <b>"
}

# repo_set — "repo\tslug\tbase\trole" per repo, root first (from s_list). An
# invalid JST_MEMBERS ends the run here with s_list's error= line, exit 2.
repo_set() {
  local out
  out=$(s_list) || { printf '%s\n' "$out"; exit 2; }
  printf '%s\n' "$out" | tail -n +2 | awk -F'\t' -v rb="$ROOT_BASE" '{ b = ($2 == "root" && rb != "") ? rb : $5; print $1 "\t" $4 "\t" b "\t" $2 }'
}

urlenc() { printf '%s' "$1" | sed 's#/#%2F#g'; }   # a branch name inside an API path

# pr_rows <slug> <branch> — "pr\tstate\tbase\turl" per PR. Exit 1 on a gh error
# (message in $ERRF). An empty answer is asked once more before it stands.
pr_rows() {
  local out i
  for i in 1 2; do
    out=$($TMOUT_CMD gh pr list -R "$1" --head "$2" --state all --json number,state,baseRefName,url \
          --jq '.[] | [.number, .state, .baseRefName, .url] | @tsv' 2>"$ERRF") || return 1
    [ -n "$out" ] && break
  done
  [ -z "$out" ] || printf '%s\n' "$out"
}

v_prs() {
  local set rc=0 repo slug base role rows
  need_branch
  set=$(repo_set) || { printf '%s\n' "$set"; exit 2; }
  printf '%s\n' "$PRS_HEADER"
  while IFS=$'\t' read -r repo slug base role; do
    [ -n "$repo" ] || continue
    if [ "$slug" = - ]; then
      printf '%s\t-\t-\terror\t-\t-\n' "$repo"
      printf '%s\n' "repos: $repo: origin isn't a github.com remote, so its PRs can't be looked up" >&2
      rc=4; continue
    fi
    if ! rows=$(pr_rows "$slug" "$OPT_BRANCH"); then
      printf '%s\t%s\t-\terror\t-\t-\n' "$repo" "$slug"
      printf '%s\n' "repos: $slug: $(awk 'NF{print; exit}' "$ERRF")" >&2
      rc=4; continue
    fi
    [ "$OPT_STATE" = open ] && rows=$(printf '%s\n' "$rows" | awk -F'\t' '$2 == "OPEN"')
    if [ -z "$rows" ]; then
      printf '%s\t%s\t-\tnone\t-\t-\n' "$repo" "$slug"
    else
      printf '%s\n' "$rows" | awk -F'\t' -v r="$repo" -v s="$slug" '{ print r "\t" s "\t" $1 "\t" $2 "\t" $3 "\t" $4 }'
    fi
  done <<EOF
$set
EOF
  exit "$rc"
}

# effective <prs-rows-for-one-repo> <expected-base> — one word for a repo's PRs:
# none | OPEN <n> | MERGED <n> | stop <reason>. Several PRs → the OPEN one;
# several OPEN, an OPEN one off its base, or only CLOSED ones → stop.
effective() {
  local rows="$1" want="$2" opens n b
  [ -n "$rows" ] || { echo none; return; }
  opens=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "OPEN"' | wc -l | tr -d ' ')
  if [ "$opens" -gt 1 ]; then echo "stop several OPEN PRs in $(printf '%s' "$rows" | head -1 | cut -f1)"; return; fi
  if [ "$opens" -eq 1 ]; then
    n=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "OPEN" { print $3 }')
    b=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "OPEN" { print $5 }')
    if [ -n "$want" ] && [ "$b" != "$want" ]; then
      echo "stop $(printf '%s' "$rows" | head -1 | cut -f2)#$n targets '$b', but its base is '$want'"; return
    fi
    echo "OPEN $n"; return
  fi
  n=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "MERGED" { print $3; exit }')
  [ -n "$n" ] && { echo "MERGED $n"; return; }
  n=$(printf '%s\n' "$rows" | awk -F'\t' '$4 == "CLOSED" { print $3; exit }')
  echo "stop $(printf '%s' "$rows" | head -1 | cut -f2)#$n was closed without merging — abandoned on purpose? Ask before reviewing or replacing it"
}

# takes_part <slug> <base> — for a member with no PR: "no" (the issue branch isn't
# on its origin, or has no commits ahead of base), "pushed" (commits, no PR), or
# "error <message>".
takes_part() {
  local ahead
  if ! $TMOUT_CMD gh api "repos/$1/branches/$(urlenc "$OPT_BRANCH")" >/dev/null 2>"$ERRF"; then
    grep -qE '404|Not Found' "$ERRF" && { echo no; return; }
    echo "error $(awk 'NF{print; exit}' "$ERRF")"; return
  fi
  ahead=$($TMOUT_CMD gh api "repos/$1/compare/$(urlenc "$2")...$(urlenc "$OPT_BRANCH")" --jq .ahead_by 2>"$ERRF") \
    || { echo "error $(awk 'NF{print; exit}' "$ERRF")"; return; }
  if [ "${ahead:-0}" -gt 0 ]; then echo pushed; else echo no; fi
}

v_gate() {
  local prsout rc set repo slug base role eff word root="none" root_n="" stop="" open_m="" merged_m="" n_part=0 tp
  need_branch
  set=$(repo_set) || { printf '%s\n' "$set"; exit 2; }
  prsout=$(v_prs); rc=$?
  [ "$rc" -eq 2 ] && { printf '%s\n' "$prsout"; exit 2; }
  gate_out() { printf 'phase=%s\nreason=%s\nroot=%s\nmembers=%s\n%s\n' "$1" "$2" "$3" "$4" "$prsout"; exit 0; }
  if [ "$rc" -ne 0 ]; then
    gate_out stop "PRs unknown for: $(printf '%s\n' "$prsout" | awk -F'\t' '$4 == "error" { print $1 }' | paste -sd' ' -) — gh failed; unknown is not none" unknown unknown
  fi
  while IFS=$'\t' read -r repo slug base role; do
    [ -n "$repo" ] || continue
    eff=$(effective "$(printf '%s\n' "$prsout" | awk -F'\t' -v r="$repo" 'NR > 1 && $1 == r && $4 != "none"')" "$base")
    word=${eff%% *}
    if [ "$word" = stop ]; then stop="${stop:-${eff#stop }}"; continue; fi
    if [ "$role" = root ]; then
      root=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]'); root_n=${eff#* }
      continue
    fi
    case "$word" in
      OPEN)   open_m="${open_m:+$open_m }$repo"; n_part=$((n_part + 1)) ;;
      MERGED) merged_m="${merged_m:+$merged_m }$repo"; n_part=$((n_part + 1)) ;;
      none)
        tp=$(takes_part "$slug" "$base")
        case "$tp" in
          pushed) stop="${stop:-$repo has commits on $OPT_BRANCH ahead of $base, but no PR — pushed, no PR}" ;;
          error*) stop="${stop:-could not tell whether $repo takes part: ${tp#error } — unknown is not none}" ;;
        esac ;;
    esac
  done <<EOF
$set
EOF
  local members=n/a
  if printf '%s\n' "$set" | awk -F'\t' '$4 == "member"' | grep -q .; then
    if   [ -n "$open_m" ] && [ -n "$merged_m" ]; then members=mixed
    elif [ -n "$open_m" ];   then members=open
    elif [ -n "$merged_m" ]; then members=merged
    else members=none; fi
  fi
  [ -n "$stop" ] && gate_out stop "$stop" "$root" "$members"
  if [ "$n_part" -eq 0 ]; then   # the root is the only repo with work: today's single-step check
    case "$root" in
      none)   gate_out none "no PR on $OPT_BRANCH in any repo" "$root" "$members" ;;
      open)   gate_out review "PR #$root_n open" "$root" "$members" ;;
      merged) gate_out merged "PR #$root_n merged" "$root" "$members" ;;
    esac
  fi
  if [ -n "$open_m" ]; then
    case "$root" in
      none) gate_out review "member PRs open: $open_m${merged_m:+ (merged: $merged_m)}" "$root" "$members" ;;
      *)    gate_out stop "the root PR #$root_n is $root while member PRs are still open ($open_m) — it lands only after they merge" "$root" "$members" ;;
    esac
  fi
  case "$root" in
    none)   gate_out land "every member PR is merged ($merged_m); no root PR yet — land it" "$root" "$members" ;;
    open)   gate_out review-landing "root PR #$root_n open; every member PR is merged ($merged_m)" "$root" "$members" ;;
    merged) gate_out merged "root PR #$root_n merged" "$root" "$members" ;;
  esac
}

land_fail() { printf 'error=%s\n' "$1"; exit 1; }

v_land_check() {
  local set ref repo slug base role gl rc=0
  need_branch
  set=$(repo_set) || { printf '%s\n' "$set"; exit 2; }
  printf '%s\n' "$set" | awk -F'\t' '$4 == "member"' | grep -q . || { printf 'check=nothing to check — no member gitlinks\n'; exit 0; }
  git -C "$ROOT" fetch -q origin "$OPT_BRANCH" "$ROOT_BASE" 2>/dev/null || true
  ref="origin/$OPT_BRANCH"; git -C "$ROOT" rev-parse -q --verify "$ref" >/dev/null || ref=HEAD
  printf 'repo\tgitlink\tbase\tresult\n'
  while IFS=$'\t' read -r repo slug base role; do
    [ "$role" = member ] || continue
    gl=$(git -C "$ROOT" ls-tree "$ref" -- "$repo" | awk '{ print $3 }')
    if [ -z "$gl" ]; then printf '%s\t-\t%s\tmissing from %s\n' "$repo" "$base" "$ref"; rc=1; continue; fi
    if ! git -C "$ROOT/$repo" fetch -q origin "$base" 2>/dev/null; then
      printf '%s\t%s\t%s\tcannot fetch origin/%s\n' "$repo" "${gl:0:12}" "$base" "$base"; rc=1; continue
    fi
    if git -C "$ROOT/$repo" merge-base --is-ancestor "$gl" "origin/$base" 2>/dev/null; then
      printf '%s\t%s\t%s\tok\n' "$repo" "${gl:0:12}" "$base"
    else
      printf '%s\t%s\t%s\tnot on origin/%s\n' "$repo" "${gl:0:12}" "$base" "$base"; rc=1
    fi
  done <<EOF
$set
EOF
  if ! git -C "$ROOT" diff --quiet "origin/$ROOT_BASE" "$ref" -- .gitmodules 2>/dev/null; then
    printf '.gitmodules\t-\t%s\tchanged against origin/%s — a landing PR must not move submodule settings\n' "$ROOT_BASE" "$ROOT_BASE"; rc=1
  fi
  exit "$rc"
}

v_land() {
  [ -n "$OPT_CHECK" ] && v_land_check
  local set prsout rc repo slug base role eff mc key cur root_eff root_slug plan="" landed="" body url jurl
  need_branch
  set=$(repo_set) || { printf '%s\n' "$set"; exit 2; }
  printf '%s\n' "$set" | awk -F'\t' '$4 == "member"' | grep -q . \
    || { printf 'landed=\nreason=nothing to land — the set has no member gitlinks\n'; exit 0; }
  cur=$(git -C "$ROOT" branch --show-current 2>/dev/null || true)
  [ "$cur" = "$OPT_BRANCH" ] || land_fail "run land from the issue worktree, on $OPT_BRANCH (the root is on '${cur:-a detached HEAD}')"
  [ -z "$(git -C "$ROOT" status --porcelain --ignore-submodules=all)" ] || land_fail "the root has uncommitted changes — commit or stash them first"
  key=$(printf '%s' "${OPT_BRANCH#*/}" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)
  prsout=$(v_prs); rc=$?
  [ "$rc" -eq 0 ] || land_fail "PRs unknown (prs exit $rc) — nothing changed"
  # Everything is checked before anything changes.
  while IFS=$'\t' read -r repo slug base role; do
    [ -n "$repo" ] || continue
    eff=$(effective "$(printf '%s\n' "$prsout" | awk -F'\t' -v r="$repo" 'NR > 1 && $1 == r && $4 != "none"')" "$base")
    if [ "$role" = root ]; then root_eff=$eff; root_slug=$slug; continue; fi
    case "$eff" in
      stop*) land_fail "${eff#stop } — nothing changed" ;;
      OPEN*) land_fail "$slug#${eff#OPEN } is still open — merge it first; nothing changed" ;;
      none)  [ "$(takes_part "$slug" "$base")" = no ] || land_fail "$repo has work on $OPT_BRANCH but no merged PR — nothing changed"; continue ;;
    esac
    mc=$($TMOUT_CMD gh pr view "${eff#MERGED }" -R "$slug" --json mergeCommit --jq .mergeCommit.oid 2>"$ERRF") \
      || land_fail "$slug#${eff#MERGED }: $(awk 'NF{print; exit}' "$ERRF") — nothing changed"
    [ "$(git -C "$ROOT/$repo" rev-parse --show-toplevel 2>/dev/null)" = "$ROOT/$repo" ] \
      || land_fail "$repo isn't checked out here — nothing changed"
    [ -z "$(git -C "$ROOT/$repo" status --porcelain)" ] || land_fail "$repo has uncommitted changes — nothing changed"
    git -C "$ROOT/$repo" fetch -q origin "$base" 2>/dev/null || land_fail "can't fetch $repo's origin/$base — nothing changed"
    git -C "$ROOT/$repo" merge-base --is-ancestor "$mc" "origin/$base" 2>/dev/null \
      || land_fail "$slug#${eff#MERGED }'s merge commit ${mc:0:12} isn't on $repo's origin/$base — nothing changed"
    plan="$plan$repo	$mc	$slug#${eff#MERGED }
"
  done <<EOF
$set
EOF
  case "$root_eff" in
    MERGED*) land_fail "the root PR #${root_eff#MERGED } is already merged — nothing to land" ;;
    stop*)   land_fail "${root_eff#stop } — nothing changed" ;;
  esac
  [ -n "$plan" ] || land_fail "no member PR has merged yet — nothing to land"
  # Apply: each gitlink to its merged commit, one commit, one push.
  body="Lands $key: moves each member's gitlink to its merged PR's commit on the member's base."
  while IFS=$'\t' read -r repo mc ref; do
    [ -n "$repo" ] || continue
    git -C "$ROOT/$repo" checkout -q --detach "$mc" || land_fail "checkout of $mc in $repo failed"
    git -C "$ROOT" add -- "$repo"
    landed="${landed:+$landed }$repo"
    body="$body
- $repo → ${mc:0:12} ($ref, merged)"
  done <<EOF
$plan
EOF
  if ! git -C "$ROOT" diff --cached --quiet; then
    git -C "$ROOT" commit -q -m "$key: land $landed" -m "$body" || land_fail "the landing commit failed"
  fi
  git -C "$ROOT" -c push.recurseSubmodules=check push -q -u origin "$OPT_BRANCH" 2>"$ERRF" \
    || land_fail "committed locally, but the push failed: $(awk 'NF{print; exit}' "$ERRF")"
  case "$root_eff" in
    OPEN*) url=$(printf '%s\n' "$prsout" | awk -F'\t' -v n="${root_eff#OPEN }" 'NR > 1 && $1 == "." && $3 == n { print $6 }') ;;
    *)
      jurl=$(cfg JIRA_ACCOUNT_URL || true); jurl=${jurl#*://}
      printf '%s\n\nEvery gitlink here points at a commit on its member'"'"'s base; the reviewer checks it with `repos.sh land --check`.\n%s\n' \
        "$body" "${jurl:+
Jira: https://$jurl/browse/$key}" > "$ERRF.body"
      url=$($TMOUT_CMD gh pr create -R "$root_slug" --base "$ROOT_BASE" --head "$OPT_BRANCH" \
            --title "$key: land $landed" --body-file "$ERRF.body" 2>"$ERRF" | tail -1)
      rm -f "$ERRF.body"
      [ -n "$url" ] || land_fail "landed and pushed, but opening the root PR failed: $(awk 'NF{print; exit}' "$ERRF")" ;;
  esac
  printf 'landed=%s\ncommit=%s\npr=%s\n' "$landed" "$(git -C "$ROOT" rev-parse HEAD)" "$url"
  exit 0
}

"s_$VERB"
