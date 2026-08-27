#!/usr/bin/env bash
# check-ensure-local-env.sh — regression checks for ensure_local_env's safety
# contract, and for the statuscheck rows that report on it.
#
# The invariant worth protecting: a linked worktree gets the .jst/ contract it
# needs, and NEVER ends up holding .jst/jira-sdlc-tools.local.env — three Jira
# role tokens plus a GitHub PAT — at a path git would offer to commit. That is
# a security property of a ~110-line script with no other coverage, and
# AGENTS.md is explicit that a script bug is wrong 100% of the time and rots
# silently in a repo with no tests (JST-301).
#
# Builds throwaway repos in $TMPDIR reproducing the state jst-install leaves —
# .jst/ present but entirely untracked — cuts worktrees from them, and asserts
# the behaviour end to end. Touches nothing outside its temp dirs, needs no
# credentials and no network.
#
# Usage:  bash scripts/check-ensure-local-env.sh [--ports]
#           --ports   also diff the POSIX and Windows ports against each other
#                     (needs pwsh; skipped with a notice when absent)
# Exit 0 — every check passed. Exit 1 — at least one failed, named on stdout.

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SH="$ROOT/plugins/jira-sdlc/skills/_shared/scripts/posix/ensure_local_env.sh"
PS="$ROOT/plugins/jira-sdlc/skills/_shared/scripts/win/ensure_local_env.ps1"
SC="$ROOT/plugins/jira-sdlc/skills/_shared/scripts/posix/statuscheck.sh"
PORTS=""
[ "${1:-}" = "--ports" ] && PORTS=1

LAB=$(mktemp -d)
# chmod back anything we locked, or the cleanup can't remove it
cleanup() { find "$LAB" -type d ! -perm -u+w -exec chmod u+w {} + 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }

# A project exactly as jst-install leaves it: .jst/ written, nothing tracked.
# GITHUB_PAT_TOKEN is deliberately blank — statuscheck logs `gh` out when it
# finds a non-empty one, which would clobber the caller's real session.
mkproj() {
  mkdir -p "$1"; git -C "$1" init -q -b development
  git -C "$1" config user.email t@t; git -C "$1" config user.name t
  echo x > "$1/README.md"; git -C "$1" add README.md; git -C "$1" commit -qm init
  mkdir -p "$1/.jst"
  printf 'PROJECT-KEY=XX\nDEFAULT_BASE_BRANCH=development\nPRODUCTION_BRANCH=main\n' \
    > "$1/.jst/jira-sdlc-tools.env"
  printf 'jira-sdlc-tools.local.env\n' > "$1/.jst/.gitignore"
  printf 'JIRA_ACCOUNT_URL=example.invalid\nGITHUB_PAT_TOKEN=\n' \
    > "$1/.jst/jira-sdlc-tools.local.env"
}
wt() { git -C "$1" worktree add -q "$2" -b "$3"; }

echo "ensure_local_env — safety contract"

# 1. The reported bug: a worktree cut from an untracked .jst/ is born empty,
#    and the credential must not land unignored in it (JST-301).
mkproj "$LAB/p1"; wt "$LAB/p1" "$LAB/w1" feature/XX-1-a
[ -d "$LAB/w1/.jst" ] && no "worktree starts without .jst/" || ok "worktree starts without .jst/ (bug precondition)"
( cd "$LAB/w1" && bash "$SH" >/dev/null 2>&1 ); is "provisions cleanly (exit 0)" "$?" 0
for f in .gitignore jira-sdlc-tools.env jira-sdlc-tools.local.env; do
  [ -f "$LAB/w1/.jst/$f" ] && ok "provisioned .jst/$f" || no "provisioned .jst/$f"
done
git -C "$LAB/w1" check-ignore -q .jst/jira-sdlc-tools.local.env \
  && ok "credential is gitignored in the worktree" || no "CREDENTIAL NOT IGNORED"

# 2. Idempotent, and never overwrites what is already there.
OUT=$( cd "$LAB/w1" && bash "$SH" 2>&1 ); is "second run silent" "$OUT" ""
printf 'MARKER=1\n' >> "$LAB/w1/.jst/jira-sdlc-tools.local.env"
( cd "$LAB/w1" && bash "$SH" >/dev/null 2>&1 )
grep -q MARKER "$LAB/w1/.jst/jira-sdlc-tools.local.env" \
  && ok "never overwrites an existing file" || no "overwrote an existing file"

# 3. Main checkout is a no-op; nothing to copy is exit 1 with a remedy.
OUT=$( cd "$LAB/p1" && bash "$SH" 2>&1 ); is "main checkout no-op" "$OUT" ""
mkproj "$LAB/p3"; rm "$LAB/p3/.jst/jira-sdlc-tools.local.env"
wt "$LAB/p3" "$LAB/w3" feature/XX-3-a
ERR=$( cd "$LAB/w3" && bash "$SH" 2>&1 >/dev/null ); is "nothing to copy -> exit 1" "$?" 1
case "$ERR" in *"not found in the main checkout either"*) ok "names the missing source";; *) no "remedy: $ERR";; esac

# 4. The rule can't be written -> refuse, and leave no credential behind.
#    (A deeper .gitignore always outranks a shallower one, so .jst/.gitignore
#    cannot be overridden from above — an unwritable .jst/ is the real case.)
mkproj "$LAB/p4"; wt "$LAB/p4" "$LAB/w4" feature/XX-4-a
mkdir -p "$LAB/w4/.jst"; chmod a-w "$LAB/w4/.jst"
ERR=$( cd "$LAB/w4" && bash "$SH" 2>&1 >/dev/null ); is "unignorable -> exit 1" "$?" 1
[ -f "$LAB/w4/.jst/jira-sdlc-tools.local.env" ] \
  && no "LEFT AN UNIGNORED CREDENTIAL BEHIND" || ok "wrote no credential it couldn't protect"
case "$ERR" in *"refusing to write"*) ok "refusal names the reason";; *) no "remedy: $ERR";; esac
chmod u+w "$LAB/w4/.jst"

# 5. A credential already TRACKED needs the one remedy that works. check-ignore
#    consults the index, so it can never report a tracked path as ignored —
#    "add the rule to .gitignore" would loop forever (JST-301 review).
mkproj "$LAB/p5"; wt "$LAB/p5" "$LAB/w5" feature/XX-5-a
git -C "$LAB/p5" add -f .jst/.gitignore .jst/jira-sdlc-tools.env .jst/jira-sdlc-tools.local.env
git -C "$LAB/p5" commit -qm "credential committed by mistake"
( cd "$LAB/w5" && git merge -q development --no-edit >/dev/null 2>&1 )
ERR=$( cd "$LAB/w5" && bash "$SH" 2>&1 >/dev/null ); is "tracked credential -> exit 1" "$?" 1
case "$ERR" in
  *"git rm --cached"*|*"rotate the leaked Jira token"*) ok "remedy is the one that clears it";;
  *) no "remedy would not clear the condition: $ERR";;
esac

echo "statuscheck — rows that report on the above"

# 6. env_config and env_local_ignored both read OK after provisioning.
ROWS=$( cd "$LAB/w1" && GITHUB_PAT_TOKEN= bash "$SC" --role executor 2>/dev/null )
printf '%s' "$ROWS" | grep -q '^| env_config | OK'        && ok "env_config OK"        || no "env_config OK"
printf '%s' "$ROWS" | grep -q '^| env_local_ignored | OK' && ok "env_local_ignored OK" || no "env_local_ignored OK"

# 7. In a worktree, env_config's remedy must not tell you to author a copy here.
mkproj "$LAB/p7"; rm "$LAB/p7/.jst/jira-sdlc-tools.env"
wt "$LAB/p7" "$LAB/w7" feature/XX-7-a
( cd "$LAB/w7" && bash "$SH" >/dev/null 2>&1 )
R7=$( cd "$LAB/w7" && GITHUB_PAT_TOKEN= bash "$SC" --role executor 2>/dev/null | grep '`env_config`' )
case "$R7" in *"linked worktree"*) ok "env_config remedy is worktree-aware";; *) no "remedy: $R7";; esac
case "$R7" in *"create jira-sdlc-tools.env in the project's .jst/ folder"*) no "still says author it here";; *) ok "no longer says author it here";; esac

# 8. statuscheck must relay ensure_local_env's own reason, not assert a cause.
R8=$( cd "$LAB/w5" && GITHUB_PAT_TOKEN= bash "$SC" --role executor 2>/dev/null | grep '`env_local`' )
case "$R8" in *"git rm --cached"*) ok "env_local relays the real remedy";; *) no "env_local remedy: $R8";; esac

echo "jira-task-executor step 2 — the merge that follows provisioning"

# 9. Committing .jst/ makes git want paths the worktree already holds
#    untracked. The abort must name only .jst/ paths, and clearing exactly
#    those must let the merge through — that is what step 2 tells the model.
mkproj "$LAB/p9"; wt "$LAB/p9" "$LAB/w9" feature/XX-9-a
( cd "$LAB/w9" && bash "$SH" >/dev/null 2>&1 )
git -C "$LAB/p9" add .jst/.gitignore .jst/jira-sdlc-tools.env
git -C "$LAB/p9" commit -qm "commit .jst as the first task"
( cd "$LAB/w9" && git merge development --no-edit >/dev/null 2>"$LAB/e9" ); is "merge aborts on the artifacts" "$?" 1
COLLIDE=$(sed -n 's/^\t//p' "$LAB/e9")
if [ -z "$COLLIDE" ]; then
  no "abort names the paths"
  no "every named path is under .jst/ (no paths to check)"
else
  ok "abort names the paths"
  printf '%s\n' "$COLLIDE" | grep -qv '^\.jst/' \
    && no "named a path outside .jst/ — step 2 must stop and ask" \
    || ok "every named path is under .jst/ (safe to clear)"
fi
printf '%s\n' "$COLLIDE" | while read -r p; do [ -n "$p" ] && rm -f "$LAB/w9/$p"; done
( cd "$LAB/w9" && git merge development --no-edit >/dev/null 2>&1 ); is "merge succeeds after clearing" "$?" 0
( cd "$LAB/w9" && bash "$SH" >/dev/null 2>&1 ); is "provisioning still sound afterwards" "$?" 0
git -C "$LAB/w9" check-ignore -q .jst/jira-sdlc-tools.local.env \
  && ok "credential still ignored after the merge" || no "CREDENTIAL NOT IGNORED after merge"

# 10. Port parity, opt-in: same stdout, stderr and exit code on every branch.
if [ -n "$PORTS" ]; then
  echo "posix vs win port parity"
  if ! command -v pwsh >/dev/null 2>&1; then
    echo "  skip  pwsh not installed"
  else
    export STATUSCHECK_FORCE_OS=windows
    n=0
    parity() { # parity <label> <setup-fn>
      n=$((n+1))
      for port in sh ps; do
        rm -rf "$LAB/pp$port"; mkdir -p "$LAB/pp$port"; "$2" "$LAB/pp$port"
        d="$LAB/pp$port/wt"; [ -d "$d" ] || d="$LAB/pp$port/proj"
        if [ "$port" = sh ]; then ( cd "$d" && bash "$SH" ) >"$LAB/o.sh" 2>"$LAB/r.sh"; echo $? >"$LAB/c.sh"
        else ( cd "$d" && pwsh -NoProfile -File "$PS" ) >"$LAB/o.ps" 2>"$LAB/r.ps"; echo $? >"$LAB/c.ps"; fi
      done
      for f in o.sh r.sh o.ps r.ps; do sed -i "s#$LAB/pp[a-z]*#<LAB>#g" "$LAB/$f"; done
      if cmp -s "$LAB/o.sh" "$LAB/o.ps" && cmp -s "$LAB/r.sh" "$LAB/r.ps" && cmp -s "$LAB/c.sh" "$LAB/c.ps"
      then ok "port parity — $1"
      else no "port parity — $1"; diff <(cat "$LAB/o.sh" "$LAB/r.sh" "$LAB/c.sh") \
                                       <(cat "$LAB/o.ps" "$LAB/r.ps" "$LAB/c.ps") | sed 's/^/        /'; fi
    }
    p_fresh()  { mkproj "$1/proj"; wt "$1/proj" "$1/wt" feature/XX-1-a; }
    p_again()  { p_fresh "$1"; ( cd "$1/wt" && bash "$SH" >/dev/null 2>&1 ); }
    p_main()   { mkproj "$1/proj"; }
    p_nocopy() { mkproj "$1/proj"; rm "$1/proj/.jst/jira-sdlc-tools.local.env"; wt "$1/proj" "$1/wt" feature/XX-2-a; }
    p_noign()  { mkproj "$1/proj"; rm "$1/proj/.jst/.gitignore"; wt "$1/proj" "$1/wt" feature/XX-3-a; }
    p_nonl()   { mkproj "$1/proj"; printf 'other-rule' > "$1/proj/.jst/.gitignore"; wt "$1/proj" "$1/wt" feature/XX-4-a; }
    p_locked() { mkproj "$1/proj"; wt "$1/proj" "$1/wt" feature/XX-5-a; mkdir -p "$1/wt/.jst"; chmod a-w "$1/wt/.jst"; }
    p_tracked() { mkproj "$1/proj"; wt "$1/proj" "$1/wt" feature/XX-6-a
                  git -C "$1/proj" add -f .jst/.gitignore .jst/jira-sdlc-tools.env .jst/jira-sdlc-tools.local.env
                  git -C "$1/proj" commit -qm tracked
                  ( cd "$1/wt" && git merge -q development --no-edit >/dev/null 2>&1 ); }
    p_norepo() { mkdir -p "$1/proj"; }
    parity "fresh worktree"            p_fresh
    parity "idempotent re-run"         p_again
    parity "main checkout"             p_main
    parity "nothing to copy"           p_nocopy
    parity "no .gitignore in main"     p_noign
    parity "no trailing newline"       p_nonl
    parity "unwritable .jst/"          p_locked
    parity "tracked credential"        p_tracked
    parity "not a git repo"            p_norepo
    find "$LAB" -type d ! -perm -u+w -exec chmod u+w {} + 2>/dev/null
  fi
fi

echo
printf 'check-ensure-local-env: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
