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
golden "usage: no verb" "$M" "" "repos: a verb is required — one of: strategy, list, prs, gate, land, provision, sync, push, open-prs\nexit=2"
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

# --- 4. prs, gate and land ---------------------------------------------------------
echo "repos.sh — prs, gate and land (fake gh, real git)"

# Members with GitHub-shaped origins that really fetch from local bare repos:
# url.*.insteadOf in a lab-only global config. The fake gh reads its answers
# from $FGH: prs/<owner_repo>@<branch> holds `gh pr list`'s rows.
export GIT_CONFIG_GLOBAL="$LAB/gitconfig"
LR="$LAB/lr"; mkdir -p "$LR"
git config --global protocol.file.allow always
git config --global user.email t@t; git config --global user.name t
for n in parent app server solo; do
  git config --global "url.$LR/$n.git.insteadOf" "git@github.com:acme/$n.git"
done
for n in app server; do mkremote "$LR" "$n"; done
mkrepo "$LR/seed-parent"; git clone -q --bare "$LR/seed-parent" "$LR/parent.git"
mkrepo "$LR/seed-solo";   git clone -q --bare "$LR/seed-solo"   "$LR/solo.git"

L="$LAB/L"
git clone -q git@github.com:acme/parent.git "$L"
mkdir -p "$L/.jst"
printf 'PROJECT-KEY=XX\nDEFAULT_BASE_BRANCH=development\nPRODUCTION_BRANCH=main\nJST_MEMBERS = app server\n' > "$L/.jst/jira-sdlc-tools.env"
printf 'jira-sdlc-tools.local.env\n' > "$L/.jst/.gitignore"
printf 'JIRA_ACCOUNT_URL=example.atlassian.net\nGITHUB_PAT_TOKEN=\n' > "$L/.jst/jira-sdlc-tools.local.env"
git -C "$L" submodule add -q -b development git@github.com:acme/app.git app
git -C "$L" submodule add -q -b development git@github.com:acme/server.git server
git -C "$L" add .jst/.gitignore .jst/jira-sdlc-tools.env; git -C "$L" commit -qm "members"; git -C "$L" push -q origin development

B=feature/XX-5-land
git -C "$L" branch "$B"; git -C "$L" push -q origin "$B"
git -C "$L/app" switch -qc "$B"; echo change > "$L/app/f.txt"; git -C "$L/app" add f.txt; git -C "$L/app" commit -qm "XX-5 change"; git -C "$L/app" push -q origin "$B"
FEATURE=$(git -C "$L/app" rev-parse HEAD)
W="$LAB/W"; git -C "$L" worktree add -q "$W" "$B"
( cd "$W" && bash "$ROOT/$SCRIPTS/posix/ensure_local_env.sh" >/dev/null )   # a skill's step 1: the worktree's credentials
git -C "$W" submodule update -q --init
git -C "$W/app" fetch -q origin; git -C "$W/app" switch -q "$B"

FGH="$LAB/fgh"; mkdir -p "$FGH/prs" "$FGH/merge" "$FGH/branches" "$FGH/ahead" "$LAB/bin4"
export FGH
cat > "$LAB/bin4/gh" <<'GH'
#!/usr/bin/env bash
D="$FGH"; key() { local b="${2//\//%}"; printf '%s@%s' "${1//\//_}" "$b"; }
dec() { printf '%s' "$1" | sed 's#%2F#/#g'; }
opt() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { printf '%s' "$2"; return; }; shift; done; }
case "$1 $2" in
  "pr list")
    k=$(key "$(opt -R "$@")" "$(opt --head "$@")"); echo "pr list $k" >> "$D/calls"
    [ -f "$D/prs/$k.error" ] && { cat "$D/prs/$k.error" >&2; exit 1; }
    [ -f "$D/prs/$k.emptyonce" ] && { rm "$D/prs/$k.emptyonce"; exit 0; }
    [ -f "$D/prs/$k" ] && cat "$D/prs/$k"; exit 0 ;;
  "pr view")
    s=$(opt -R "$@")
    if [ "$(opt --json "$@")" = body ]; then cat "$D/body/${s//\//_}#$3" 2>/dev/null; exit 0; fi
    cat "$D/merge/${s//\//_}#$3"; exit 0 ;;
  "pr edit")
    s=$(opt -R "$@"); cp "$(opt --body-file "$@")" "$D/body/${s//\//_}#$3"
    echo "$s#$3" >> "$D/edited"; exit 0 ;;
  "pr create")
    s=$(opt -R "$@"); h=$(opt --head "$@"); b=$(opt --base "$@")
    cp "$(opt --body-file "$@")" "$D/created.body"
    printf '%s %s %s %s\n' "$s" "$b" "$h" "$(opt --title "$@")" >> "$D/created"
    n=99; [ -f "$D/next" ] && n=$(cat "$D/next")
    mkdir -p "$D/body"; cp "$(opt --body-file "$@")" "$D/body/${s//\//_}#$n"
    u="https://github.com/$s/pull/$n"
    printf '%s\tOPEN\t%s\t%s\n' "$n" "$b" "$u" >> "$D/prs/$(key "$s" "$h")"
    echo "$u"; exit 0 ;;
esac
if [ "$1" = api ]; then
  p=$2; s=$(printf '%s' "$p" | cut -d/ -f2,3)
  case "$p" in
    repos/*/branches/*)
      [ -f "$D/branches/$(key "$s" "$(dec "$(printf '%s' "$p" | cut -d/ -f5-)")")" ] && { echo '{}'; exit 0; }
      echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    repos/*/compare/*)
      spec=${p#*/compare/}; f="$D/ahead/$(key "$s" "$(dec "${spec#*...}")")"
      if [ -f "$f" ]; then cat "$f"; else echo 0; fi; exit 0 ;;
  esac
fi
echo "fake gh: unexpected: $*" >&2; exit 1
GH
chmod +x "$LAB/bin4/gh"
K() { printf '%s@%s' "acme_$1" "${2//\//%}"; }            # K <repo> <branch> — a fake-gh data key ('/' → '%')
setpr() { printf '%b\n' "$3" > "$FGH/prs/$(K "$1" "$2")"; } # setpr <repo> <branch> <rows, \t \n escapes>
clearfgh() { rm -f "$FGH"/prs/* "$FGH"/branches/* "$FGH"/ahead/* "$FGH"/merge/* "$FGH/calls"; }

rp() { # rp <port> <dir> <args…> — run repos with the fake gh; stdout, then exit=<rc>
  local port="$1" dir="$2"; shift 2
  if [ "$port" = sh ]; then ( cd "$dir" && PATH="$LAB/bin4:$PATH" GH_CONFIG_DIR="$LAB/ghcfg" bash "$REPOS_SH" "$@" 2>/dev/null; echo "exit=$?" )
  else ( cd "$dir" && PATH="$LAB/bin4:$PATH" GH_CONFIG_DIR="$LAB/ghcfg" pwsh -NoProfile -File "$REPOS_PS" "$@" 2>/dev/null; echo "exit=$?" ); fi | norm
}
both4() { # both4 <label> <dir> <expected> <args…> — the same expected output from both ports
  local label="$1" dir="$2" want port; want=$(printf '%b' "$3"); shift 3
  for port in sh ${PORTS:+ps}; do
    is "$label$([ "$port" = ps ] && echo ' (win)')" "$(rp "$port" "$dir" "$@")" "$want"
  done
}
PH='repo\tslug\tpr\tstate\tbase\turl'
U='https://github.com/acme'

# prs
clearfgh; setpr app "$B" "11\tOPEN\tdevelopment\t$U/app/pull/11"
both4 "prs: a member's open PR, none elsewhere" "$W" \
  "$PH\n.\tacme/parent\t-\tnone\t-\t-\napp\tacme/app\t11\tOPEN\tdevelopment\t$U/app/pull/11\nserver\tacme/server\t-\tnone\t-\t-\nexit=0" prs
touch "$FGH/prs/$(K app "$B").emptyonce"
both4 "prs: an empty answer is asked again before it counts" "$W" \
  "$PH\n.\tacme/parent\t-\tnone\t-\t-\napp\tacme/app\t11\tOPEN\tdevelopment\t$U/app/pull/11\nserver\tacme/server\t-\tnone\t-\t-\nexit=0" prs
echo "gh: HTTP 502" > "$FGH/prs/$(K server "$B").error"
both4 "prs: a gh failure is unknown, not none (exit 4)" "$W" \
  "$PH\n.\tacme/parent\t-\tnone\t-\t-\napp\tacme/app\t11\tOPEN\tdevelopment\t$U/app/pull/11\nserver\tacme/server\t-\terror\t-\t-\nexit=4" prs
rm "$FGH/prs/$(K server "$B").error"
both4 "prs --state open drops the rest" "$W" \
  "$PH\n.\tacme/parent\t-\tnone\t-\t-\napp\tacme/app\t-\tnone\t-\t-\nserver\tacme/server\t-\tnone\t-\t-\nexit=0" prs --state open --branch feature/XX-6-other

# gate — the phases, on fake data (git state doesn't matter here)
G() { printf 'phase=%s\nreason=%s\nroot=%s\nmembers=%s\n' "$1" "$2" "$3" "$4"; }
T() { printf '%b' "$PH"; for r in "$@"; do printf '\n%b' "$r"; done; printf '\nexit=0'; }
NP=".\tacme/parent\t-\tnone\t-\t-"; NA="app\tacme/app\t-\tnone\t-\t-"; NS="server\tacme/server\t-\tnone\t-\t-"
OA="app\tacme/app\t11\tOPEN\tdevelopment\t$U/app/pull/11"; MA="app\tacme/app\t11\tMERGED\tdevelopment\t$U/app/pull/11"
clearfgh
both4 "gate: none" "$W" "$(G none "no PR on $B in any repo" none none)\n$(T "$NP" "$NA" "$NS")" gate
setpr app "$B" "11\tOPEN\tdevelopment\t$U/app/pull/11"
both4 "gate: review (a member PR open)" "$W" "$(G review "member PRs open: app" none open)\n$(T "$NP" "$OA" "$NS")" gate
setpr app "$B" "11\tMERGED\tdevelopment\t$U/app/pull/11"
both4 "gate: land (every member PR merged, no root PR)" "$W" \
  "$(G land "every member PR is merged (app); no root PR yet — land it" none merged)\n$(T "$NP" "$MA" "$NS")" gate
setpr parent "$B" "99\tOPEN\tdevelopment\t$U/parent/pull/99"
OP=".\tacme/parent\t99\tOPEN\tdevelopment\t$U/parent/pull/99"
both4 "gate: review-landing" "$W" "$(G review-landing "root PR #99 open; every member PR is merged (app)" open merged)\n$(T "$OP" "$MA" "$NS")" gate
setpr parent "$B" "99\tMERGED\tdevelopment\t$U/parent/pull/99"
both4 "gate: merged" "$W" "$(G merged "root PR #99 merged" merged merged)\n$(T ".\tacme/parent\t99\tMERGED\tdevelopment\t$U/parent/pull/99" "$MA" "$NS")" gate
clearfgh; setpr app "$B" "11\tOPEN\tdevelopment\t$U/app/pull/11"; setpr parent "$B" "99\tOPEN\tdevelopment\t$U/parent/pull/99"
both4 "gate: stop — the root PR is open while a member's is" "$W" \
  "$(G stop "the root PR #99 is open while member PRs are still open (app) — it lands only after they merge" open open)\n$(T "$OP" "$OA" "$NS")" gate
clearfgh; setpr app "$B" "11\tCLOSED\tdevelopment\t$U/app/pull/11"
both4 "gate: stop — closed without merging" "$W" \
  "$(G stop "acme/app#11 was closed without merging — abandoned on purpose? Ask before reviewing or replacing it" none none)\n$(T "$NP" "app\tacme/app\t11\tCLOSED\tdevelopment\t$U/app/pull/11" "$NS")" gate
setpr app "$B" "11\tOPEN\tmain\t$U/app/pull/11"
both4 "gate: stop — an open PR off its base" "$W" \
  "$(G stop "acme/app#11 targets 'main', but its base is 'development'" none none)\n$(T "$NP" "app\tacme/app\t11\tOPEN\tmain\t$U/app/pull/11" "$NS")" gate
setpr app "$B" "11\tOPEN\tdevelopment\t$U/app/pull/11\n12\tOPEN\tdevelopment\t$U/app/pull/12"
both4 "gate: stop — several open PRs in one repo" "$W" \
  "$(G stop "several OPEN PRs in app" none none)\n$(T "$NP" "$OA" "app\tacme/app\t12\tOPEN\tdevelopment\t$U/app/pull/12" "$NS")" gate
clearfgh; setpr app "$B" "11\tOPEN\tdevelopment\t$U/app/pull/11"; touch "$FGH/branches/$(K server "$B")"; echo 2 > "$FGH/ahead/$(K server "$B")"
both4 "gate: stop — pushed, no PR" "$W" \
  "$(G stop "server has commits on $B ahead of development, but no PR — pushed, no PR" none open)\n$(T "$NP" "$OA" "$NS")" gate
echo 0 > "$FGH/ahead/$(K server "$B")"
both4 "gate: an empty member branch doesn't take part" "$W" "$(G review "member PRs open: app" none open)\n$(T "$NP" "$OA" "$NS")" gate
clearfgh; echo "gh: HTTP 502" > "$FGH/prs/$(K app "$B").error"
both4 "gate: stop — PRs unknown" "$W" \
  "$(G stop "PRs unknown for: app — gh failed; unknown is not none" unknown unknown)\n$(T "$NP" "app\tacme/app\t-\terror\t-\t-" "$NS")" gate
both4 "gate: stop — multistep across members" "$W" \
  "phase=stop\nreason=multistep issues (Jira sub-tasks) across member repos aren't supported yet — review the sub-task PRs by hand\nroot=unknown\nmembers=unknown\nexit=0" gate --multistep

# gate on a single repo: today's single-step phase check
SO="$LAB/solo"; git clone -q git@github.com:acme/solo.git "$SO"; mkdir -p "$SO/.jst"
printf 'DEFAULT_BASE_BRANCH=development\n' > "$SO/.jst/jira-sdlc-tools.env"
SB=feature/XX-7-solo; NSO=".\tacme/solo\t-\tnone\t-\t-"
clearfgh
both4 "single: gate none" "$SO" "$(G none "no PR on $SB in any repo" none n/a)\n$(T "$NSO")" gate --branch "$SB"
setpr solo "$SB" "5\tOPEN\tdevelopment\t$U/solo/pull/5"
both4 "single: gate review" "$SO" "$(G review "PR #5 open" open n/a)\n$(T ".\tacme/solo\t5\tOPEN\tdevelopment\t$U/solo/pull/5")" gate --branch "$SB"
both4 "single: gate stop when the PR is off --base" "$SO" \
  "$(G stop "acme/solo#5 targets 'development', but its base is 'main'" none n/a)\n$(T ".\tacme/solo\t5\tOPEN\tdevelopment\t$U/solo/pull/5")" gate --branch "$SB" --base main
setpr solo "$SB" "5\tMERGED\tdevelopment\t$U/solo/pull/5"
both4 "single: gate merged" "$SO" "$(G merged "PR #5 merged" merged n/a)\n$(T ".\tacme/solo\t5\tMERGED\tdevelopment\t$U/solo/pull/5")" gate --branch "$SB"
both4 "single: land has nothing to land" "$SO" "landed=\nreason=nothing to land — the set has no member gitlinks\nexit=0" land --branch "$SB"

# land — a real squash merge, then the landing commit, push and PR
clearfgh; setpr app "$B" "11\tOPEN\tdevelopment\t$U/app/pull/11"
HEAD0=$(git -C "$W" rev-parse HEAD)
both4 "land refuses while a member PR is open, and changes nothing" "$W" \
  "error=acme/app#11 is still open — merge it first; nothing changed\nexit=1" land
is "  …the root's HEAD didn't move" "$(git -C "$W" rev-parse HEAD)" "$HEAD0"
both4 "land refuses off the issue branch" "$L" \
  "error=run land from the issue worktree, on $B (the root is on 'development')\nexit=1" land --branch "$B"
# "Squash-merge" the member PR on its remote and delete the branch, as GitHub would.
SQ="$LAB/sq"; git clone -q git@github.com:acme/app.git "$SQ"; git -C "$SQ" merge -q --squash "origin/$B" >/dev/null 2>&1
git -C "$SQ" commit -qm "XX-5 change (#11)"; git -C "$SQ" push -q origin development; git -C "$SQ" push -q origin --delete "$B"
SQUASH=$(git -C "$SQ" rev-parse HEAD)
setpr app "$B" "11\tMERGED\tdevelopment\t$U/app/pull/11"; printf '%s\n' "$SQUASH" > "$FGH/merge/acme_app#11"
for port in sh ${PORTS:+ps}; do
  sfx=""; [ "$port" = ps ] && sfx=" (win)"
  # each port lands from the same starting point
  git -C "$W" reset -q --hard "$HEAD0"; git -C "$W" -c push.recurseSubmodules=no push -q -f origin "$B"
  git -C "$W/app" checkout -q "$B" 2>/dev/null || true
  rm -f "$FGH/prs/$(K parent "$B")" "$FGH/created"
  OUT=$(rp "$port" "$W" land)
  NEWHEAD=$(git -C "$W" rev-parse HEAD)
  is "land: lands the squash commit and opens the root PR$sfx" "$OUT" \
    "$(printf 'landed=app\ncommit=%s\npr=%s\nexit=0' "$NEWHEAD" "$U/parent/pull/99")"
  is "  …the gitlink is the merged commit, not the feature one$sfx" "$(git -C "$W" ls-tree HEAD app | awk '{print $3}')" "$SQUASH"
  is "  …the commit is pushed$sfx" "$(git -C "$W" ls-remote origin "refs/heads/$B" | cut -f1)" "$NEWHEAD"
  is "  …the PR went to the root's base$sfx" "$(cat "$FGH/created")" "acme/parent development $B XX-5: land app"
  grep -q "^Jira: https://example.atlassian.net/browse/XX-5$" "$FGH/created.body" \
    && ok "  …its body links the issue$sfx" || no "  …its body links the issue$sfx: $(cat "$FGH/created.body")"
  is "land again: reuses the open PR, no second commit$sfx" "$(rp "$port" "$W" land)" \
    "$(printf 'landed=app\ncommit=%s\npr=%s\nexit=0' "$NEWHEAD" "$U/parent/pull/99")"
  is "  …still one root PR$sfx" "$(wc -l < "$FGH/created" | tr -d ' ')" 1
done
CH='repo\tgitlink\tbase\tresult'
both4 "land --check: every gitlink on its base" "$W" \
  "$CH\napp\t${SQUASH:0:12}\tdevelopment\tok\nserver\t$(git -C "$W" ls-tree HEAD server | awk '{print substr($3,1,12)}')\tdevelopment\tok\nexit=0" land --check
# A gitlink to the orphaned feature commit — what a landing without MS-LA-1 would push.
git -C "$W/app" checkout -q "$FEATURE"; git -C "$W" add app; git -C "$W" commit -qm "bad gitlink"
git -C "$W" -c push.recurseSubmodules=no push -q origin "$B"
both4 "land --check: a gitlink off its member's base fails" "$W" \
  "$CH\napp\t${FEATURE:0:12}\tdevelopment\tnot on origin/development\nserver\t$(git -C "$W" ls-tree HEAD server | awk '{print substr($3,1,12)}')\tdevelopment\tok\nexit=1" land --check
# --- 5. the executor's verbs: provision, sync, push, open-prs ----------------------
echo "repos.sh — provision, sync, push and open-prs (fake gh, real git)"

# These verbs change state, so every port gets a workspace of its own: a parent
# with members app and server, and bare remotes, under GitHub owner <ns>.
E=feature/XX-8-exec
mk5() { # mk5 <ns> [none] — build $LAB/<ns>/W, the issue worktree, with app on $E (none: no member on it yet)
  local ns="$1" r="$LAB/$1/remotes" n
  mkdir -p "$r"
  for n in parent app server; do git config --global "url.$r/$n.git.insteadOf" "git@github.com:$ns/$n.git"; done
  mkremote "$r" app; mkremote "$r" server
  mkrepo "$r/seed-parent"; git clone -q --bare "$r/seed-parent" "$r/parent.git"
  git clone -q "git@github.com:$ns/parent.git" "$LAB/$ns/main"
  mkdir -p "$LAB/$ns/main/.jst"
  printf 'DEFAULT_BASE_BRANCH=development\nJST_MEMBERS = app server\n' > "$LAB/$ns/main/.jst/jira-sdlc-tools.env"
  git -C "$LAB/$ns/main" submodule add -q -b development "git@github.com:$ns/app.git" app
  git -C "$LAB/$ns/main" submodule add -q -b development "git@github.com:$ns/server.git" server
  git -C "$LAB/$ns/main" add .jst; git -C "$LAB/$ns/main" commit -qm members; git -C "$LAB/$ns/main" push -q origin development
  git -C "$LAB/$ns/main" branch "$E"; git -C "$LAB/$ns/main" push -q -u origin "$E"
  if [ "${2:-}" != none ]; then
    git -C "$LAB/$ns/main/app" switch -qc "$E"; git -C "$LAB/$ns/main/app" push -q -u origin "$E"   # app takes part
  fi
  git -C "$LAB/$ns/main" worktree add -q "$LAB/$ns/W" "$E"
}
for port in sh ${PORTS:+ps}; do
  ns="e-$port"; mk5 "$ns"; W5="$LAB/$ns/W"; sfx=""; [ "$port" = ps ] && sfx=" (win)"
  is "provision: app onto the branch, server pinned$sfx" "$(rp $port "$W5" provision)" "$(printf 'provisioned=app\npinned=server\nexit=0')"
  is "  …app is on $E$sfx" "$(git -C "$W5/app" branch --show-current)" "$E"
  is "  …its parentbranch is set inside the worktree's member$sfx" "$(git -C "$W5/app" config "branch.$E.parentbranch")" development
  is "  …the push-order guard is on$sfx" "$(git -C "$W5" config push.recurseSubmodules)" check
  is "provision again: the same, nothing changed$sfx" "$(rp $port "$W5" provision)" "$(printf 'provisioned=app\npinned=server\nexit=0')"
  is "provision --add a non-member$sfx" "$(rp $port "$W5" provision --add nope)" "$(printf 'error=--add nope: not a member (JST_MEMBERS lists the members)\nexit=1')"
  is "provision --add server: scope growth$sfx" "$(rp $port "$W5" provision --add server)" "$(printf 'provisioned=app server\npinned=\nexit=0')"
  is "  …server's branch is on its origin$sfx" "$(git -C "$W5/server" ls-remote --heads origin "$E" | wc -l | tr -d ' ')" 1
  is "sync: both current$sfx" "$(rp $port "$W5" sync)" "$(printf 'synced=app server\nexit=0')"
  # A conflict: app's base and app's branch change the same line.
  echo base > "$LAB/$ns/seed-tmp"; git clone -q "git@github.com:$ns/app.git" "$LAB/$ns/c"
  echo "from base" > "$LAB/$ns/c/README.md"; git -C "$LAB/$ns/c" commit -qam base; git -C "$LAB/$ns/c" push -q origin development
  echo "from the branch" > "$W5/app/README.md"; git -C "$W5/app" commit -qam branch
  is "sync: a conflict stops the run and names it$sfx" "$(rp $port "$W5" sync)" "$(printf 'conflict=app\nfiles=README.md\nsynced=\nexit=1')"
  git -C "$W5/app" merge --abort
  git -C "$W5/app" reset -q --hard "origin/$E"   # back to the pushed branch
  echo work > "$W5/app/work.txt"; git -C "$W5/app" add work.txt; git -C "$W5/app" commit -qm "XX-8 work"
  is "push: the member with work, not the root$sfx" "$(rp $port "$W5" push)" "$(printf 'pushed=app\nexit=0')"
  is "  …it reached the member's origin$sfx" "$(git -C "$W5/app" rev-list --count "origin/$E..HEAD")" 0
  is "push again: nothing to push$sfx" "$(rp $port "$W5" push)" "$(printf 'pushed=\nexit=0')"
  # open-prs: app has commits ahead of its base; server's branch is empty, so it gets no PR.
  clearfgh; rm -rf "$FGH/body" "$FGH/created" "$FGH/edited"; echo 7 > "$FGH/next"
  printf 'XX-8: the work.\n' > "$LAB/$ns/body.md"
  is "open-prs: one PR, for the member with commits$sfx" "$(rp $port "$W5" open-prs --title "XX-8: work" --body-file "$LAB/$ns/body.md")" \
    "$(printf 'repo\tslug\tpr\taction\turl\napp\t%s/app\t7\tcreated\thttps://github.com/%s/app/pull/7\nexit=0' "$ns" "$ns")"
  is "  …it went to the member's base$sfx" "$(cat "$FGH/created")" "$ns/app development $E XX-8: work"
  grep -q "^- $ns/app#7 — OPEN$" "$FGH/body/${ns}_app#7" && ok "  …its body carries the PR set$sfx" || no "  …PR-set section$sfx: $(cat "$FGH/body/${ns}_app#7")"
  is "open-prs again: it exists, nothing created$sfx" "$(rp $port "$W5" open-prs --title "XX-8: work" --body-file "$LAB/$ns/body.md")" \
    "$(printf 'repo\tslug\tpr\taction\turl\napp\t%s/app\t7\texists\thttps://github.com/%s/app/pull/7\nexit=0' "$ns" "$ns")"
  # Scope grew: server gets a commit, and its new PR joins the set in both bodies.
  echo more > "$W5/server/more.txt"; git -C "$W5/server" add more.txt; git -C "$W5/server" commit -qm "XX-8 more"; rp $port "$W5" push >/dev/null
  echo 8 > "$FGH/next"
  rp $port "$W5" open-prs --title "XX-8: work" --body-file "$LAB/$ns/body.md" >/dev/null
  grep -q "^- $ns/server#8 — OPEN$" "$FGH/body/${ns}_app#7" && ok "  …a new PR is added to the set in the older PR$sfx" || no "  …app body: $(cat "$FGH/body/${ns}_app#7")"
  is "  …and the section isn't duplicated$sfx" "$(grep -c '<!-- jst:pr-set -->' "$FGH/body/${ns}_app#7")" 1
done
# The assigner's case: no member has the branch yet, and --add names the in-scope ones.
for port in sh ${PORTS:+ps}; do
  ns="a-$port"; mk5 "$ns" none; WA="$LAB/$ns/W"; sfx=""; [ "$port" = ps ] && sfx=" (win)"
  is "provision --add with a non-member in the list stops first$sfx" "$(rp $port "$WA" provision --add "app,nope")" \
    "$(printf 'error=--add nope: not a member (JST_MEMBERS lists the members)\nexit=1')"
  is "  …and created nothing$sfx" "$(git ls-remote --heads "$LAB/$ns/remotes/app.git" "$E" | wc -l | tr -d ' ')" 0   # the remote itself: the member isn't checked out yet
  is "provision --add \"app server\": both branches cut and pushed$sfx" "$(rp $port "$WA" provision --add "app server")" \
    "$(printf 'provisioned=app server\npinned=\nexit=0')"
  is "  …both on their origins$sfx" "$(for m in app server; do git -C "$WA/$m" ls-remote --heads origin "$E"; done | wc -l | tr -d ' ')" 2
  is "  …the main checkout's members didn't move$sfx" "$(git -C "$LAB/$ns/main/app" branch --show-current)" development
  is "provision --add again: idempotent$sfx" "$(rp $port "$WA" provision --add "app server")" "$(printf 'provisioned=app server\npinned=\nexit=0')"
done
# Single repo: push always pushes, open-prs opens the root's PR with no PR-set section.
for port in sh ${PORTS:+ps}; do
  sfx=""; [ "$port" = ps ] && sfx=" (win)"; S5="$LAB/solo-$port"
  git clone -q git@github.com:acme/solo.git "$S5"; mkdir -p "$S5/.jst"; printf 'DEFAULT_BASE_BRANCH=development\n' > "$S5/.jst/jira-sdlc-tools.env"
  git -C "$S5" switch -qc "feature/XX-9-$port"; echo x > "$S5/x.txt"; git -C "$S5" add x.txt; git -C "$S5" commit -qm x
  is "single: provision has nothing to do$sfx" "$(rp $port "$S5" provision)" "$(printf 'provisioned=\npinned=\nexit=0')"
  is "single: push pushes the branch$sfx" "$(rp $port "$S5" push)" "$(printf 'pushed=.\nexit=0')"
  clearfgh; rm -rf "$FGH/body" "$FGH/created"; echo 3 > "$FGH/next"; printf 'XX-9.\n' > "$LAB/b9.md"
  is "single: open-prs opens the root's PR into --base$sfx" "$(rp $port "$S5" open-prs --title "XX-9: x" --body-file "$LAB/b9.md" --base development)" \
    "$(printf 'repo\tslug\tpr\taction\turl\n.\tacme/solo\t3\tcreated\thttps://github.com/acme/solo/pull/3\nexit=0')"
  grep -q 'jst:pr-set' "$FGH/body/acme_solo#3" && no "single: a PR-set section was added$sfx" || ok "  …no PR-set section on a single repo$sfx"
done

unset GIT_CONFIG_GLOBAL

echo
printf 'check-repos: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
