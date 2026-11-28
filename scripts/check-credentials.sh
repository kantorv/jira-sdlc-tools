#!/usr/bin/env bash
# check-credentials.sh — regression checks for credential profiles (JSW-37):
# where the scripts' credentials come from, and that they never come from two
# places at once.
#
# The eight cases the issue names, each end to end through the real scripts:
#   1. a project with its own credentials ignores profiles (and the default);
#   2. a project naming a profile (JST_CREDENTIALS) uses it;
#   3. the machine default applies only when the project names none;
#   4. a partial set in the project fails, and nothing falls back to a profile;
#   5. an owner mismatch fails, naming both sides (a member's owner counts);
#   6. a profile open to group or others (0644) is refused;
#   7. a worktree gets no token when the project uses a profile;
#   8. the migration's dry run changes nothing, and --apply changes only the
#      project whose credentials equal a profile's.
# Plus, on every output: no value of any dummy credential is ever printed.
#
# Scratch everything: projects in $TMPDIR, XDG_CONFIG_HOME pointing at a
# scratch config, dummy values, a fake gh that answers by token. It never reads
# the machine's real ~/.config/jira-sdlc or any real local env, and needs no
# network (jira.sh's site is example.invalid, so its whoami fails fast).
#
# Usage:  bash scripts/check-credentials.sh [--ports]
#           --ports   also run the cases through the win/ ports (needs pwsh;
#                     skipped with a notice when absent)
# Exit 0 — every check passed. Exit 1 — at least one failed, named on stdout.

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
P="$ROOT/plugins/jira-sdlc/skills/_shared/scripts/posix"
W="$ROOT/plugins/jira-sdlc/skills/_shared/scripts/win"
PORTS=""; [ "${1:-}" = "--ports" ] && PORTS=1

LAB=$(mktemp -d)
trap 'rm -rf "$LAB"' EXIT
export HOME="$LAB/home"; mkdir -p "$HOME"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$LAB/cache"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$LAB/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.email t@t
git config --file "$GIT_CONFIG_GLOBAL" user.name t
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch development
PROFILES="$XDG_CONFIG_HOME/jira-sdlc/profiles"
mkdir -p "$PROFILES"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1 (no '$3' in: $2)" ;; esac; }

# --- fixtures -----------------------------------------------------------------
KEYS="JIRA_ASSIGNER_EMAIL JIRA_ASSIGNER_TOKEN JIRA_EXECUTOR_EMAIL JIRA_EXECUTOR_TOKEN JIRA_REVIEWER_EMAIL JIRA_REVIEWER_TOKEN GITHUB_PAT_TOKEN"

# group <tag> — the seven keys with dummy values marked <tag> (dummy-<tag>-<key>).
group() { local k; for k in $KEYS; do printf '%s = dummy-%s-%s\n' "$k" "$1" "$k"; done; }

# profile <name> <owners> <tag> [mode] — a profile file.
profile() {
  { group "$3"; printf 'PROFILE_GITHUB_OWNERS = %s\n' "$2"; } > "$PROFILES/$1.env"
  chmod "${4:-600}" "$PROFILES/$1.env"
}

# mkproj <dir> <owner> — a repo whose origin is github.com:<owner>/app, with a
# committed .jst/ (team env + ignore rule) and no local env yet.
mkproj() {
  mkdir -p "$1/.jst"; git -C "$1" init -q
  git -C "$1" remote add origin "git@github.com:$2/app.git"
  printf 'PROJECT_KEY=XX\nDEFAULT_BASE_BRANCH=development\nPRODUCTION_BRANCH=main\nJIRA_ACCOUNT_URL=example.invalid\n' > "$1/.jst/jira-sdlc-tools.env"
  printf 'jira-sdlc-tools.local.env\n' > "$1/.jst/.gitignore"
  git -C "$1" add .jst && git -C "$1" commit -qm init
}
local_env() { ( umask 077; cat > "$1/.jst/jira-sdlc-tools.local.env" ); }

# A fake gh: answers `api user` with a login chosen by the token it was given,
# so a test sees WHICH credential gh.sh passed without printing it.
mkdir -p "$LAB/bin"
cat > "$LAB/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${GH_TOKEN:-}" in
  dummy-own-GITHUB_PAT_TOKEN) who=own ;;
  dummy-acme-GITHUB_PAT_TOKEN) who=acme-profile ;;
  dummy-dflt-GITHUB_PAT_TOKEN) who=default-profile ;;
  "") echo "fake gh: no GH_TOKEN" >&2; exit 4 ;;
  *) who=other ;;
esac
[ "$*" = "api user --jq .login" ] && { echo "$who"; exit 0; }
echo "fake gh: not faked: $*" >&2; exit 1
EOF
chmod +x "$LAB/bin/gh"
export PATH="$LAB/bin:$PATH"

# src <dir> <command…> — run a reader call from inside <dir>.
src() { local d=$1; shift; ( cd "$d" && . "$P/_jst_root.sh" && . "$P/_jst_config.sh" && jst_config_init && "$@" ); }
ghwho() { ( cd "$1" && bash "$P/gh.sh" api user --jq .login 2>&1 ); }
credrow() { ( cd "$1" && bash "$P/statuscheck.sh" --role executor 2>/dev/null ) | grep -E '^\| credentials \|'; }
ALL_OUT="$LAB/all-output"; : > "$ALL_OUT"
keep() { printf '%s\n' "$1" >> "$ALL_OUT"; printf '%s' "$1"; }

profile acme "acme" acme
profile dflt "acme" dflt
printf 'dflt\n' > "$XDG_CONFIG_HOME/jira-sdlc/default"

# --- 1. own credentials ignore profiles ------------------------------------------
echo "1. a project with its own credentials ignores profiles"
mkproj "$LAB/own" acme
{ group own; printf 'JST_CREDENTIALS = acme\n'; } | local_env "$LAB/own"
source_of() { ( cd "$1" && . "$P/_jst_root.sh" && . "$P/_jst_config.sh" && jst_config_init && jst_cred_resolve && echo "$JST_CRED_SOURCE" ); }
is "  source is the project, even naming a profile and with a default" "$(source_of "$LAB/own")" project
is "  jst_cred reads the project's own value" "$(src "$LAB/own" jst_cred JIRA_EXECUTOR_EMAIL)" dummy-own-JIRA_EXECUTOR_EMAIL
is "  gh.sh passes the project's PAT" "$(keep "$(ghwho "$LAB/own")")" own
has "  credentials row: project .jst/" "$(keep "$(credrow "$LAB/own")")" "| credentials | OK | project .jst/"

# --- 2. a named profile ---------------------------------------------------------
echo "2. a project naming a profile uses it"
mkproj "$LAB/named" acme
printf 'JST_CREDENTIALS = acme\n' >> "$LAB/named/.jst/jira-sdlc-tools.env"
git -C "$LAB/named" commit -qam "name the profile"
is "  gh.sh passes the profile's PAT" "$(keep "$(ghwho "$LAB/named")")" acme-profile
has "  credentials row names the profile and its file" "$(keep "$(credrow "$LAB/named")")" "| credentials | OK | profile acme (~/.config/jira-sdlc/profiles/acme.env)"
row=$(credrow "$LAB/named")
has "  …and the match" "$row" "owners match (acme)"
env_row=$( ( cd "$LAB/named" && bash "$P/statuscheck.sh" --role executor 2>/dev/null ) | grep -E '^\| env_local \|')
has "  env_local is optional with a profile" "$env_row" "| env_local | INFO |"
out=$( ( cd "$LAB/named" && bash "$P/get_assignee_email.sh" ) 2>&1 )
is "  get_assignee_email reads the profile's executor email" "$out" "dummy-acme-JIRA_EXECUTOR_EMAIL"

# --- 3. the default only when the project names none -------------------------------
echo "3. the machine default applies only when the project names none"
mkproj "$LAB/plain" acme
is "  no name → the default" "$(keep "$(ghwho "$LAB/plain")")" default-profile
has "  credentials row says it came from the default" "$(keep "$(credrow "$LAB/plain")")" "via the machine default"
is "  a name → that profile, not the default" "$(ghwho "$LAB/named")" acme-profile
printf 'JST_CREDENTIALS = nosuch\n' | local_env "$LAB/plain"
out=$(keep "$(ghwho "$LAB/plain")")
has "  a named profile that doesn't exist fails, no fallback to the default" "$out" "profile 'nosuch' (JST_CREDENTIALS in .jst/jira-sdlc-tools.local.env) not found"
has "  …and the row FAILs" "$(keep "$(credrow "$LAB/plain")")" "| credentials | FAIL |"
rm -f "$LAB/plain/.jst/jira-sdlc-tools.local.env"
mv "$XDG_CONFIG_HOME/jira-sdlc/default" "$LAB/default.off"
out=$(keep "$(ghwho "$LAB/plain")"); rc=$( (cd "$LAB/plain" && bash "$P/gh.sh" api user --jq .login >/dev/null 2>&1); echo $?)
has "  no name and no default: no credentials" "$out" "no credentials:"
is "  …gh.sh exits 4" "$rc" 4
mv "$LAB/default.off" "$XDG_CONFIG_HOME/jira-sdlc/default"

# --- 4. a partial project set fails ------------------------------------------------
echo "4. a partial project set fails, never filled in from a profile"
mkproj "$LAB/partial" acme
{ printf 'JIRA_EXECUTOR_EMAIL = dummy-own-JIRA_EXECUTOR_EMAIL\nJIRA_EXECUTOR_TOKEN = dummy-own-JIRA_EXECUTOR_TOKEN\nJST_CREDENTIALS = acme\n'; } | local_env "$LAB/partial"
out=$(keep "$(ghwho "$LAB/partial")")
has "  gh.sh refuses, naming what's missing" "$out" "missing: JIRA_ASSIGNER_EMAIL JIRA_ASSIGNER_TOKEN JIRA_REVIEWER_EMAIL JIRA_REVIEWER_TOKEN GITHUB_PAT_TOKEN"
out=$(keep "$( (cd "$LAB/partial" && bash "$P/jira.sh" --role executor whoami) 2>&1 )")
has "  jira.sh refuses too (even for the role whose pair is set)" "$out" "sets part of the credential group"
has "  the row FAILs" "$(keep "$(credrow "$LAB/partial")")" "| credentials | FAIL | the project's .jst/ sets part of the credential group"
is "  jst_cred gives nothing" "$(src "$LAB/partial" jst_cred JIRA_EXECUTOR_TOKEN)" ""

# --- 5. owner mismatch ---------------------------------------------------------------
echo "5. an owner mismatch fails, naming both sides"
mkproj "$LAB/foreign" globex
printf 'JST_CREDENTIALS = acme\n' | local_env "$LAB/foreign"
out=$(keep "$(credrow "$LAB/foreign")")
has "  the row FAILs with the profile's owners" "$out" "is for GitHub owner(s) acme"
has "  …and the project's" "$out" "owned by globex"
out=$(keep "$(ghwho "$LAB/foreign")")
has "  gh.sh refuses" "$out" "jst-gh: profile 'acme'"
out=$(keep "$( (cd "$LAB/foreign" && bash "$P/jira.sh" --role executor whoami) 2>&1 )")
has "  jira.sh refuses" "$out" "owned by globex"
mkproj "$LAB/members" acme
printf '[submodule "lib"]\n\tpath = lib\n\turl = git@github.com:globex/lib.git\n' > "$LAB/members/.gitmodules"
printf 'JST_MEMBERS=lib\nJST_CREDENTIALS = acme\n' | local_env "$LAB/members"
is "  a member's owner counts" "$(src "$LAB/members" jst_project_owners)" "acme globex"
has "  …so the profile doesn't cover the project" "$(keep "$(ghwho "$LAB/members")")" "(not covered: globex)"
profile both "acme globex" both
printf 'JST_MEMBERS=lib\nJST_CREDENTIALS = both\n' | local_env "$LAB/members"
is "  a profile covering both owners works" "$(ghwho "$LAB/members")" other

# --- 6. a 0644 profile -------------------------------------------------------------
echo "6. a profile open to group or others is refused"
profile loose "acme" loose 644
mkproj "$LAB/loose" acme
printf 'JST_CREDENTIALS = loose\n' | local_env "$LAB/loose"
out=$(keep "$(ghwho "$LAB/loose")")
has "  refused, with the chmod to run" "$out" "chmod 600 ~/.config/jira-sdlc/profiles/loose.env"
has "  the row FAILs" "$(keep "$(credrow "$LAB/loose")")" "(mode 644) — refused"
chmod 600 "$PROFILES/loose.env"
is "  …and works once fixed" "$(ghwho "$LAB/loose")" other

# --- 7. worktrees get no tokens --------------------------------------------------------
echo "7. a worktree gets no token when the project uses a profile"
printf 'WORKTREES_DIR=%s\nJST_CREDENTIALS = acme\nGITHUB_PAT_TOKEN =\n' "$LAB/wts" | local_env "$LAB/named"
git -C "$LAB/named" worktree add -q "$LAB/wts/one" -b feature/XX-1-a
out=$(keep "$( (cd "$LAB/wts/one" && bash "$P/ensure_local_env.sh") 2>&1 )")
has "  ensure_local_env copies without the group" "$out" "without the credential group"
got=$(grep -cE "^[[:space:]]*($(echo $KEYS | tr ' ' '|'))[[:space:]]*=" "$LAB/wts/one/.jst/jira-sdlc-tools.local.env")
is "  …so the copy holds no key of it" "$got" 0
has "  …and keeps the rest" "$(cat "$LAB/wts/one/.jst/jira-sdlc-tools.local.env")" "WORKTREES_DIR="
is "  the worktree runs on the profile" "$(ghwho "$LAB/wts/one")" acme-profile
rm -f "$LAB/named/.jst/jira-sdlc-tools.local.env"
git -C "$LAB/named" worktree add -q "$LAB/wts/two" -b feature/XX-2-a
out=$( (cd "$LAB/wts/two" && bash "$P/ensure_local_env.sh"; echo "rc=$?") 2>&1 )
has "  no local env in the main checkout is no error with a profile" "$out" "none needed"
has "  …exit 0" "$out" "rc=0"
is "  …and the worktree runs on the profile" "$(ghwho "$LAB/wts/two")" acme-profile
git -C "$LAB/own" worktree add -q "$LAB/wts/three" -b feature/XX-3-a
(cd "$LAB/wts/three" && bash "$P/ensure_local_env.sh" >/dev/null 2>&1)
is "  a project with its own credentials is copied whole" "$(ghwho "$LAB/wts/three")" own

# --- 8. migration ------------------------------------------------------------------
echo "8. the migration's dry run changes nothing; --apply changes only the matching project"
mkdir -p "$LAB/roots"
mkproj "$LAB/roots/match" acme
{ group acme; printf 'WORKTREES_DIR=%s\n' "$LAB/roots/match-wts"; } | local_env "$LAB/roots/match"
git -C "$LAB/roots/match" worktree add -q "$LAB/roots/match-wts/w1" -b feature/XX-4-a
cp "$LAB/roots/match/.jst/jira-sdlc-tools.local.env" "$LAB/roots/match-wts/w1/.jst/jira-sdlc-tools.local.env"
mkproj "$LAB/roots/nomatch" acme
group other | local_env "$LAB/roots/nomatch"
mkproj "$LAB/roots/wrongowner" globex
group acme | local_env "$LAB/roots/wrongowner"
sums() { find "$LAB/roots" -path '*/.git' -prune -o -type f -print | sort | xargs sha256sum; }
before=$(sums)
out=$(keep "$(bash "$P/jst-credentials.sh" migrate --roots "$LAB/roots" 2>&1)")
is "  the dry run wrote nothing" "$(sums)" "$before"
has "  …and says what it would do" "$out" "$LAB/roots/match	migrate	acme	would set JST_CREDENTIALS=acme"
has "  …with the worktree copy" "$out" "and 1 worktree copy"
has "  …leaves a project with its own credentials" "$out" "$LAB/roots/nomatch	unchanged	-	own credentials"
has "  …and one whose owner the profile doesn't cover" "$out" "$LAB/roots/wrongowner	unchanged	acme"
nm=$(sha256sum < "$LAB/roots/nomatch/.jst/jira-sdlc-tools.local.env")
wo=$(sha256sum < "$LAB/roots/wrongowner/.jst/jira-sdlc-tools.local.env")
out=$(keep "$(bash "$P/jst-credentials.sh" migrate --roots "$LAB/roots" --apply 2>&1)")
has "  --apply migrates the match" "$out" "$LAB/roots/match	migrated	acme"
is "  …the other two unchanged" "$(sha256sum < "$LAB/roots/nomatch/.jst/jira-sdlc-tools.local.env") $(sha256sum < "$LAB/roots/wrongowner/.jst/jira-sdlc-tools.local.env")" "$nm $wo"
for f in "$LAB/roots/match/.jst/jira-sdlc-tools.local.env" "$LAB/roots/match-wts/w1/.jst/jira-sdlc-tools.local.env"; do
  is "  ${f#"$LAB"/} holds no key of the group" "$(grep -cE "^[[:space:]]*($(echo $KEYS | tr ' ' '|'))[[:space:]]*=" "$f")" 0
  has "  …names the profile and keeps the rest" "$(tr '\n' ' ' < "$f")" "WORKTREES_DIR=$LAB/roots/match-wts JST_CREDENTIALS=acme"
  is "  …and is still 0600" "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" 600
done
is "  the migrated project runs on the profile" "$(ghwho "$LAB/roots/match")" acme-profile
is "  …and so does its worktree" "$(ghwho "$LAB/roots/match-wts/w1")" acme-profile
out=$(keep "$(bash "$P/jst-credentials.sh" migrate --roots "$LAB/roots" 2>&1)")
has "  a second run sees it as done" "$out" "already names profile acme"

# --- no value is ever printed ------------------------------------------------------------
echo "no output above holds a credential value"
if grep -qE 'dummy-(own|acme|dflt|other)-(JIRA|GITHUB)_[A-Z_]*TOKEN' "$ALL_OUT"; then
  no "  a token value was printed: $(grep -oE 'dummy-[a-z]+-[A-Z_]*TOKEN' "$ALL_OUT" | sort -u | tr '\n' ' ')"
else
  ok "  no token value in any captured output"
fi

if [ -n "$PORTS" ]; then
  if command -v pwsh >/dev/null 2>&1; then
    echo "ports: win/ against posix/"
    for d in own named plain partial foreign members loose; do
      a=$( (cd "$LAB/$d" && bash "$P/gh.sh" api user --jq .login 2>&1; echo "rc=$?") )
      b=$( (cd "$LAB/$d" && pwsh -NoProfile -File "$W/gh.ps1" api user --jq .login 2>&1; echo "rc=$?") )
      is "  gh: $d" "$b" "$a"
      a=$( (cd "$LAB/$d" && bash "$P/statuscheck.sh" --role executor 2>/dev/null) | grep -E '^\| (env_local|env_local_ignored|credentials) \|')
      b=$( (cd "$LAB/$d" && STATUSCHECK_FORCE_OS=linux pwsh -NoProfile -File "$W/statuscheck.ps1" --role executor 2>/dev/null) | grep -E '^\| (env_local|env_local_ignored|credentials) \|')
      is "  statuscheck rows: $d" "$b" "$a"
    done
    # ensure_local_env.ps1's profile branch: a worktree of a profile project.
    printf 'WORKTREES_DIR=%s\nJST_CREDENTIALS = acme\nGITHUB_PAT_TOKEN =\n' "$LAB/wts" | local_env "$LAB/named"
    git -C "$LAB/named" worktree add -q "$LAB/wts/ps" -b feature/XX-9-a
    out=$( (cd "$LAB/wts/ps" && pwsh -NoProfile -File "$W/ensure_local_env.ps1") 2>&1 )
    has "  ensure_local_env.ps1 copies without the group" "$out" "without the credential group"
    is "  …so the copy holds no key of it" "$(grep -cE "^[[:space:]]*($(echo $KEYS | tr ' ' '|'))[[:space:]]*=" "$LAB/wts/ps/.jst/jira-sdlc-tools.local.env")" 0
    rm -f "$LAB/named/.jst/jira-sdlc-tools.local.env"
    git -C "$LAB/named" worktree add -q "$LAB/wts/ps2" -b feature/XX-10-a
    out=$( (cd "$LAB/wts/ps2" && pwsh -NoProfile -File "$W/ensure_local_env.ps1"; echo "rc=$?") 2>&1 )
    has "  ensure_local_env.ps1: no main local env is no error with a profile" "$out" "none needed"
    has "  …exit 0" "$out" "rc=0"
    out=$( (cd "$LAB/partial" && pwsh -NoProfile -File "$W/jira.ps1" --role executor whoami) 2>&1 )
    has "  jira.ps1 refuses a partial set" "$out" "sets part of the credential group"
    out=$( (cd "$LAB/named" && pwsh -NoProfile -File "$W/get_assignee_email.ps1") 2>&1 )
    is "  get_assignee_email.ps1 reads the profile" "$out" "dummy-acme-JIRA_EXECUTOR_EMAIL"
  else
    echo "ports: skipped — pwsh is not installed"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
