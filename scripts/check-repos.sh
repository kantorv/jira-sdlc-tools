#!/usr/bin/env bash
# check-repos.sh — regression checks for how the scripts find the project, in
# projects that hold their repos as git submodules, and proof that a
# single-repo project sees no change.
#
#   1. jst_root (posix/_jst_root.sh) resolves the project root from every place
#      a skill can run: the root, a subfolder, a member submodule, a nested
#      submodule, a linked worktree and its members, a project vendored into an
#      unrelated repo, and outside any repo.
#   2. The single-repo regression: statuscheck's table from this checkout must
#      be byte-identical to the one from the commit this branch is based on, for
#      a plain repo and for a repo whose only submodule is vendored — each in
#      the main checkout and in a linked worktree. Submodules support must not
#      change anything for a project that doesn't use it.
#
# Builds throwaway repos in $TMPDIR with local bare remotes. No credentials,
# and no network beyond what statuscheck's own gh/Jira rows do (GITHUB_PAT_TOKEN
# is blank, as in check-ensure-local-env.sh, so it never touches your gh login).
#
# Usage:  bash scripts/check-repos.sh [--ports] [--base <ref>]
#           --ports   also run the win/ ports (needs pwsh; skipped when absent):
#                     Get-JstRoot must agree with jst_root, and statuscheck.ps1
#                     gets the same old-vs-new regression
#           --base    the commit to compare statuscheck against (default: the
#                     merge base of HEAD and origin/development, else development)
# Exit 0 — every check passed. Exit 1 — at least one failed, named on stdout.

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SCRIPTS=plugins/jira-sdlc/skills/_shared/scripts
HELPER="$ROOT/$SCRIPTS/posix/_jst_root.sh"
PSHELPER="$ROOT/$SCRIPTS/win/_jst_root.ps1"
PORTS="" BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --ports) PORTS=1; shift ;;
    --base)  BASE="${2:-}"; shift 2 ;;
    *) echo "check-repos: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
if [ -n "$PORTS" ] && ! command -v pwsh >/dev/null 2>&1; then
  echo "check-repos: pwsh not installed — skipping the win/ ports"; PORTS=""
fi

LAB=$(cd "$(mktemp -d)" && pwd -P)   # -P: git reports physical paths
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }

# Fixtures — the same shapes as check-ensure-local-env.sh's mkproj/mkmember.
gsub() { git -c protocol.file.allow=always "$@"; }
mkrepo() { # mkrepo <dir> — a committed repo on development, no .jst/
  mkdir -p "$1"; git -C "$1" init -q -b development
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  echo x > "$1/README.md"; git -C "$1" add README.md; git -C "$1" commit -qm init
}
mkproj() { # mkproj <dir> — a repo with .jst/ as jst-install leaves it (untracked)
  mkrepo "$1"; mkdir -p "$1/.jst" "$1/src"
  printf 'PROJECT-KEY=XX\nDEFAULT_BASE_BRANCH=development\nPRODUCTION_BRANCH=main\n' > "$1/.jst/jira-sdlc-tools.env"
  printf 'jira-sdlc-tools.local.env\n' > "$1/.jst/.gitignore"
  printf 'JIRA_ACCOUNT_URL=example.invalid\nGITHUB_PAT_TOKEN=\n' > "$1/.jst/jira-sdlc-tools.local.env"
}
mkremote() { # mkremote <remotes-dir> <name> [<nested-name>] — a bare repo, optionally holding a submodule
  local r="$1" n="$2"
  mkrepo "$r/seed-$n"
  if [ -n "${3:-}" ]; then
    gsub -C "$r/seed-$n" submodule add -q "$r/$3.git" "$3"; git -C "$r/seed-$n" commit -qm "add $3"
  fi
  git clone -q --bare "$r/seed-$n" "$r/$n.git"
}
addsub() { # addsub <project> <remote> <path> — add, init, commit (.jst/ stays untracked)
  gsub -C "$1" submodule add -q -b development "$2" "$3"
  gsub -C "$1" submodule update -q --init --recursive
  git -C "$1" commit -qm "add $3"
}
wtsub() { git -C "$1" worktree add -q "$2" -b "$3"; gsub -C "$2" submodule update -q --init --recursive; }

R="$LAB/remotes"; mkdir -p "$R"
mkremote "$R" lib; mkremote "$R" app lib; mkremote "$R" vendored

# --- 1. jst_root ----------------------------------------------------------------
echo "jst_root — the project root from every place a skill can run"

root_sh() { ( cd "$1" && bash -c ". '$HELPER'; jst_root" 2>/dev/null ) || true; }
root_ps() { ( cd "$1" && pwsh -NoProfile -Command ". '$PSHELPER'; Get-JstRoot" 2>/dev/null ) || true; }
expect_root() { # expect_root <label> <run-in> <want>
  is "$1" "$(root_sh "$2")" "$3"
  [ -n "$PORTS" ] && is "$1 (win)" "$(root_ps "$2")" "$3"
}

mkproj "$LAB/single"
expect_root "single repo"                      "$LAB/single"     "$LAB/single"
expect_root "single repo, subfolder"           "$LAB/single/src" "$LAB/single"

mkproj "$LAB/c"; addsub "$LAB/c" "$R/app.git" app
expect_root "parent"                           "$LAB/c"          "$LAB/c"
expect_root "member"                           "$LAB/c/app"      "$LAB/c"
expect_root "nested submodule"                 "$LAB/c/app/lib"  "$LAB/c"
mkdir "$LAB/c/app/.jst"
expect_root "member with a .jst/ of its own"   "$LAB/c/app"      "$LAB/c"
rmdir "$LAB/c/app/.jst"

wtsub "$LAB/c" "$LAB/d" feature/XX-1-a   # .jst/ is untracked, so the worktree is born without it
expect_root "worktree member, no .jst/ yet"    "$LAB/d/app"      "$LAB/d"
mkdir "$LAB/d/.jst"
expect_root "worktree"                         "$LAB/d"          "$LAB/d"
expect_root "worktree member"                  "$LAB/d/app"      "$LAB/d"
expect_root "worktree nested submodule"        "$LAB/d/app/lib"  "$LAB/d"

mkrepo "$LAB/outer"; mkremote "$R" proj; addsub "$LAB/outer" "$R/proj.git" proj; mkdir "$LAB/outer/proj/.jst"
expect_root "project vendored into a repo without .jst/" "$LAB/outer/proj" "$LAB/outer/proj"

mkdir -p "$LAB/norepo"
expect_root "outside any git repository"       "$LAB/norepo"     ""

# --- 2. single-repo regression ----------------------------------------------------
echo "statuscheck — single-repo projects see no change"

if [ -z "$BASE" ]; then
  BASE=$(git merge-base HEAD origin/development 2>/dev/null || git merge-base HEAD development 2>/dev/null || true)
fi
if [ -z "$BASE" ] || ! git cat-file -e "$BASE^{commit}" 2>/dev/null; then
  no "no base commit to compare against (pass --base <ref>)"
else
  echo "  (comparing against $(git rev-parse --short "$BASE"))"
  mkdir -p "$LAB/old"
  git archive "$BASE" "$SCRIPTS" | tar -x -C "$LAB/old"

  # Each run gets a freshly built fixture at the same path: statuscheck
  # provisions .jst/ in a worktree, so a second run would start from another state.
  f_main()   { mkproj "$1"; }
  f_wt()     { mkproj "$1.main"; git -C "$1.main" worktree add -q "$1" -b feature/XX-2-a; }
  f_vmain()  { mkproj "$1"; addsub "$1" "$R/vendored.git" vendor/lib; }
  f_vwt()    { f_vmain "$1.main"; wtsub "$1.main" "$1" feature/XX-3-a; }

  run_sc() { # run_sc <scripts-root> <port> <dir> <out-prefix> — stdout, stderr and exit code, apart
    if [ "$2" = sh ]; then
      ( cd "$3" && GITHUB_PAT_TOKEN= bash "$1/$SCRIPTS/posix/statuscheck.sh" --role executor ) >"$4.out" 2>"$4.err"
    else
      ( cd "$3" && GITHUB_PAT_TOKEN= TEMP=/tmp STATUSCHECK_FORCE_OS=windows \
          pwsh -NoProfile -File "$1/$SCRIPTS/win/statuscheck.ps1" --role executor ) >"$4.out" 2>"$4.err"
    fi
    echo "exit=$?" >>"$4.out"
  }
  # The table and the exit code are the contract the skills read, so they must
  # be identical. stderr is compared for bash only: under pwsh on Linux,
  # statuscheck.ps1 can't launch "$PSHOME\pwsh.exe" for its ensure_local_env
  # child, and that error quotes the script's path and line number — which
  # moves with any edit above it. (AGENTS.md: Linux-under-pwsh noise.)
  same() { # same <label> <fixture-fn> <port>
    local d="$LAB/rx" i
    for i in old new; do
      rm -rf "$d" "$d.main"; "$2" "$d"
      if [ "$i" = old ]; then run_sc "$LAB/old" "$3" "$d" "$LAB/sc.old"
      else                    run_sc "$ROOT"    "$3" "$d" "$LAB/sc.new"; fi
    done
    if cmp -s "$LAB/sc.old.out" "$LAB/sc.new.out" \
       && { [ "$3" = ps ] || cmp -s "$LAB/sc.old.err" "$LAB/sc.new.err"; }; then ok "$1"
    else no "$1"; diff "$LAB/sc.old.out" "$LAB/sc.new.out" | sed 's/^/        /'
         [ "$3" = ps ] || diff "$LAB/sc.old.err" "$LAB/sc.new.err" | sed 's/^/        /'; fi
  }
  for port in sh ${PORTS:+ps}; do
    sfx=""; [ "$port" = ps ] && sfx=" (win)"
    same "plain repo, main checkout$sfx"                f_main  "$port"
    same "plain repo, linked worktree$sfx"              f_wt    "$port"
    same "vendored submodule, main checkout$sfx"        f_vmain "$port"
    same "vendored submodule, linked worktree$sfx"      f_vwt   "$port"
  done
fi

echo
printf 'check-repos: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
