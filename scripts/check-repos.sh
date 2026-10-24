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
#      match the one from the commit this branch is based on — for a plain repo
#      and for a repo whose only submodule is vendored, each in the main
#      checkout and in a linked worktree — except for exactly one added line,
#      the `repo_strategy | INFO | single` row. Submodules support must not
#      change anything else for a project that doesn't use it.
#   3. repos.sh (strategy, list) against golden output, and the statuscheck
#      rows built from it, on a parent with members, a pinned submodule, an
#      uninitialized member and invalid JST_MEMBERS values.
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
echo "statuscheck — single-repo projects see one new INFO row, nothing else"

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
    # A skill's step 1: ensure_local_env first (it provisions a fresh worktree's
    # .jst/ — without it, statuscheck stops at its jst_dir gate and nothing
    # past the first row gets compared), then statuscheck.
    if [ "$2" = sh ]; then
      ( cd "$3" && bash "$1/$SCRIPTS/posix/ensure_local_env.sh" \
          && GITHUB_PAT_TOKEN= bash "$1/$SCRIPTS/posix/statuscheck.sh" --role executor ) >"$4.out" 2>"$4.err"
    else
      ( cd "$3" && pwsh -NoProfile -File "$1/$SCRIPTS/win/ensure_local_env.ps1" \
          && GITHUB_PAT_TOKEN= TEMP=/tmp STATUSCHECK_FORCE_OS=windows \
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
    # Allowed: the new table is the old one plus exactly one repo_strategy row.
    grep -v '^| repo_strategy | INFO | single' "$LAB/sc.new.out" > "$LAB/sc.new.base"
    added=$(grep -c '^| repo_strategy | INFO | single' "$LAB/sc.new.out")
    if [ "$added" = 1 ] && cmp -s "$LAB/sc.old.out" "$LAB/sc.new.base" \
       && { [ "$3" = ps ] || cmp -s "$LAB/sc.old.err" "$LAB/sc.new.err"; }; then ok "$1 — $(grep '^| repo_strategy' "$LAB/sc.new.out" | cut -d'|' -f4 | sed 's/^ //; s/ $//')"
    else no "$1 (repo_strategy rows added: $added)"; diff "$LAB/sc.old.out" "$LAB/sc.new.out" | sed 's/^/        /'
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

# --- 3. repos.sh and the rows built from it ---------------------------------------
echo "repos.sh — strategy and list, golden output"

REPOS_SH="$ROOT/$SCRIPTS/posix/repos.sh"
REPOS_PS="$ROOT/$SCRIPTS/win/repos.ps1"
# norm: the lab path → <LAB>, so the golden output is stable.
norm() { sed "s#$LAB#<LAB>#g"; }
repos_sh() { ( cd "$1" && bash "$REPOS_SH" "$2" 2>&1; echo "exit=$?" ) | norm; }
repos_ps() { ( cd "$1" && pwsh -NoProfile -File "$REPOS_PS" "$2" 2>&1; echo "exit=$?" ) | norm; }
golden() { # golden <label> <dir> <verb> <expected, \t for tabs>
  local want; want=$(printf '%b' "$4")
  is "$1" "$(repos_sh "$2" "$3")" "$want"
  [ -n "$PORTS" ] && is "$1 (win)" "$(repos_ps "$2" "$3")" "$want"
}
setmembers() { # setmembers <project> <value> — rewrite JST_MEMBERS in the team env file
  sed -i '/^JST_MEMBERS/d' "$1/.jst/jira-sdlc-tools.env"
  [ -n "$2" ] && printf 'JST_MEMBERS = %s\n' "$2" >> "$1/.jst/jira-sdlc-tools.env"
  return 0
}

# A parent with two members (app holds a nested submodule), one vendored
# submodule left pinned, and GitHub-shaped origins. .jst/ is committed, so the
# root reads clean.
mkremote "$R" server
M="$LAB/m"
mkproj "$M"; git -C "$M" remote add origin git@github.com:acme/parent.git
addsub "$M" "$R/app.git" app; addsub "$M" "$R/server.git" server; addsub "$M" "$R/vendored.git" vendor/lib
git -C "$M" config -f .gitmodules submodule.server.url ../server.git   # relative, resolved against origin
git -C "$M/app" remote set-url origin git@github.com:acme/app.git
git -C "$M/server" remote set-url origin https://github.com/acme/server.git
setmembers "$M" "app server"
git -C "$M" add .gitmodules .jst/.gitignore .jst/jira-sdlc-tools.env; git -C "$M" commit -qm "members"

H='repo\trole\tinitialized\tslug\tbase\tbranch\tdirty\tahead'
golden "single: no members, submodules pinned" "$LAB/outer" strategy \
  'strategy=single\nroot=<LAB>/outer\nmembers=\npinned=proj\nexit=0'
golden "single: one row" "$LAB/single" list \
  "$H\n.\troot\tyes\t-\tdevelopment\tdevelopment\tyes\t-\nexit=0"
golden "submodules: members and pinned" "$M" strategy \
  'strategy=submodules\nroot=<LAB>/m\nmembers=app server\npinned=vendor/lib\nexit=0'
golden "submodules: root then members" "$M" list \
  "$H\n.\troot\tyes\tacme/parent\tdevelopment\tdevelopment\tno\t-\napp\tmember\tyes\tacme/app\tdevelopment\tdevelopment\tno\t0\nserver\tmember\tyes\tacme/server\tdevelopment\tdevelopment\tno\t0\nexit=0"
golden "from inside a member: the same set" "$M/app" strategy \
  'strategy=submodules\nroot=<LAB>/m\nmembers=app server\npinned=vendor/lib\nexit=0'

wtsub "$M" "$LAB/mw" feature/XX-9-a
golden "worktree: members detached" "$LAB/mw" list \
  "$H\n.\troot\tyes\tacme/parent\tdevelopment\tfeature/XX-9-a\tno\t-\napp\tmember\tyes\t-\tdevelopment\t(detached)\tno\t-\nserver\tmember\tyes\t-\tdevelopment\t(detached)\tno\t-\nexit=0"

gsub -C "$M" submodule deinit -q -f server
golden "uninitialized member: slug from .gitmodules, relative URL resolved" "$M" list \
  "$H\n.\troot\tyes\tacme/parent\tdevelopment\tdevelopment\tno\t-\napp\tmember\tyes\tacme/app\tdevelopment\tdevelopment\tno\t0\nserver\tmember\tno\tacme/server\tdevelopment\t-\t-\t-\nexit=0"
gsub -C "$M" submodule update -q --init server
git -C "$M/server" switch -q development   # re-init leaves it detached at the gitlink
git -C "$M/server" remote set-url origin https://github.com/acme/server.git

setmembers "$M" "app nope"
golden "invalid: not a submodule" "$M" strategy \
  "strategy=submodules\nroot=<LAB>/m\nmembers=\npinned=\nerror=JST_MEMBERS lists 'nope', which isn't a top-level submodule in .gitmodules\nexit=2"
setmembers "$M" "app/lib"
golden "invalid: a nested submodule" "$M" list \
  "error=JST_MEMBERS lists 'app/lib', which isn't a top-level submodule in .gitmodules\nexit=2"
setmembers "$M" "app app"
golden "invalid: listed twice" "$M" list "error=JST_MEMBERS lists 'app' twice\nexit=2"
setmembers "$LAB/single" "app"
golden "invalid: no .gitmodules" "$LAB/single" strategy \
  "strategy=submodules\nroot=<LAB>/single\nmembers=\npinned=\nerror=JST_MEMBERS is set, but the project has no .gitmodules — list the submodule paths that take part in issues, or leave it empty for a single-repo project\nexit=2"
setmembers "$LAB/single" ""
golden "usage: no verb" "$M" "" "repos: a verb is required — one of: strategy, list\nexit=2"
golden "usage: outside a repo" "$LAB/norepo" strategy "repos: not inside a git repository\nexit=2"
setmembers "$M" "app server"

echo "statuscheck — repo_strategy and member_repo rows (fake gh)"

# A fake gh that answers only what statuscheck asks, so the rows' OK / 404 /
# missing-base paths run without a network. GH_CONFIG_DIR points at the lab
# too, so even a real gh reached by mistake can't touch your login.
mkdir -p "$LAB/bin" "$LAB/ghcfg"
cat > "$LAB/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "auth logout") exit 0 ;;
  "auth login")  cat >/dev/null; exit 0 ;;
  "auth status") echo "  ✓ Logged in to github.com account fake (keyring)"; exit 0 ;;
  "pr list")     echo "[]"; exit 0 ;;
esac
[ "$1" = api ] || { echo "fake gh: unexpected: $*" >&2; exit 1; }
shift; [ "$1" = --paginate ] && shift
case "$1" in
  repos/acme/parent|repos/acme/app|repos/acme/server|repos/acme/nobase) echo '{}' ;;
  repos/acme/app/branches)    printf 'development\nmain\n' ;;
  repos/acme/server/branches) printf 'development\n' ;;
  repos/acme/nobase/branches) printf 'main\n' ;;
  *) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
esac
GH
# statuscheck.ps1 shells out to cmd for its gh login's stdin redirect (AGENTS.md).
printf '#!/usr/bin/env bash\n[ "$1" = "/c" ] && shift; exec bash -c "$*"\n' > "$LAB/bin/cmd"
chmod +x "$LAB/bin/gh" "$LAB/bin/cmd"
sed -i 's/^GITHUB_PAT_TOKEN=.*/GITHUB_PAT_TOKEN=fake-token/' "$M/.jst/jira-sdlc-tools.local.env"

sc_rows() { # sc_rows <dir> <port> — the repo rows of statuscheck's table
  if [ "$2" = sh ]; then
    ( cd "$1" && PATH="$LAB/bin:$PATH" GH_CONFIG_DIR="$LAB/ghcfg" bash "$ROOT/$SCRIPTS/posix/statuscheck.sh" --role executor 2>/dev/null )
  else
    ( cd "$1" && PATH="$LAB/bin:$PATH" GH_CONFIG_DIR="$LAB/ghcfg" TEMP=/tmp STATUSCHECK_FORCE_OS=windows \
        pwsh -NoProfile -File "$ROOT/$SCRIPTS/win/statuscheck.ps1" --role executor 2>/dev/null )
  fi | grep -E '^\| (gh_auth|repo_strategy|member_repo)' | norm
}
rows() { # rows <label> <expected rows, \n-separated>
  local want port sfx; want=$(printf '%b' "$2")
  for port in sh ${PORTS:+ps}; do
    sfx=""; [ "$port" = ps ] && sfx=" (win)"
    is "$1$sfx" "$(sc_rows "$M" "$port")" "$want"
  done
}
GHA='| gh_auth | OK | Logged in to github.com account fake (keyring) (PAT session login) |'
RSOK='| repo_strategy | OK | submodules — members: app server · pinned: vendor/lib |'
APPOK='| member_repo[app] | OK | acme/app · base development · on development |'
rows "every member usable (server has no main: WARN)" \
  "$GHA\n$RSOK\n$APPOK\n| member_repo[server] | WARN | acme/server · base development · on development — no 'main' branch there, so a hotfix can't touch this member |"
if [ -n "$PORTS" ]; then   # the whole table, not just these rows: no filtering needed with the fake gh
  full() { ( cd "$M" && PATH="$LAB/bin:$PATH" GH_CONFIG_DIR="$LAB/ghcfg" TEMP=/tmp STATUSCHECK_FORCE_OS=windows "$@" --role executor 2>/dev/null; echo "exit=$?" ); }
  full bash "$ROOT/$SCRIPTS/posix/statuscheck.sh" > "$LAB/t.sh"
  full pwsh -NoProfile -File "$ROOT/$SCRIPTS/win/statuscheck.ps1" > "$LAB/t.ps"
  if cmp -s "$LAB/t.sh" "$LAB/t.ps"; then ok "the whole table is identical in both ports"
  else no "the whole table differs between ports"; diff "$LAB/t.sh" "$LAB/t.ps" | norm | sed 's/^/        /'; fi
fi
git -C "$M/server" remote set-url origin git@github.com:acme/hidden.git
rows "the PAT can't see a member (404)" \
  "$GHA\n$RSOK\n$APPOK\n| member_repo[server] | FAIL | the PAT authenticates but 404s on acme/hidden — the fine-grained token's 'only selected repositories' list probably doesn't include this member |"
git -C "$M/server" remote set-url origin git@github.com:acme/nobase.git
rows "a member's base isn't on GitHub" \
  "$GHA\n$RSOK\n$APPOK\n| member_repo[server] | FAIL | base branch 'development' isn't on acme/nobase — issue branches are cut from it and PRs target it |"
git -C "$M/server" remote set-url origin /not/github
rows "a member whose origin isn't GitHub" \
  "$GHA\n$RSOK\n$APPOK\n| member_repo[server] | WARN | origin is not a github.com remote — can't probe it with gh, and 'gh pr create' won't work against it |"
git -C "$M" config -f .gitmodules submodule.server.branch .
rows "a member with 'branch = .'" \
  "$GHA\n$RSOK\n$APPOK\n| member_repo[server] | FAIL | .gitmodules sets 'branch = .' for server — a member's base has to be a real branch name |"
git -C "$M" config -f .gitmodules submodule.server.branch development
gsub -C "$M" submodule deinit -q -f server
rows "a member not checked out" "$GHA\n$RSOK\n$APPOK\n| member_repo[server] | FAIL | not checked out |"
setmembers "$M" "app nope"
rows "invalid JST_MEMBERS" "$GHA\n| repo_strategy | FAIL | JST_MEMBERS lists 'nope', which isn't a top-level submodule in .gitmodules |"

echo
printf 'check-repos: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
