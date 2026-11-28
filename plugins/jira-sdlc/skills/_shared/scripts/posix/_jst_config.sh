# _jst_config.sh — the one reader of a project's .jst/ config and of the
# credentials its scripts run with. Sourced, never run, after _jst_root.sh:
#   . "$(dirname "${BASH_SOURCE[0]}")/_jst_root.sh"
#   . "$(dirname "${BASH_SOURCE[0]}")/_jst_config.sh"
# win/_jst_config.ps1 is its twin; keep the two in step. The rules are in
# skills/_shared/project-config.md (§ Credentials) — this file is their code.
#
# Plain config — jst_cfg <NAME-PATTERN>:
#   `NAME = value` lines, parsed, never sourced (the files hold secrets). The
#   last match in a file wins; .jst/jira-sdlc-tools.local.env (machine-specific,
#   gitignored) overrides .jst/jira-sdlc-tools.env (team-shared, tracked).
#   JIRA_ACCOUNT_URL is plain config: the site belongs to the project.
#
# Credentials — jst_cred <KEY>, for the seven keys of the credential group:
#   JIRA_{ASSIGNER,EXECUTOR,REVIEWER}_{EMAIL,TOKEN} and GITHUB_PAT_TOKEN.
#   They come from ONE source, decided per group, never per key (JSW-37):
#     1. the project's own .jst/ files, when they set any key of the group —
#        then they must set all seven, and no profile is read;
#     2. else the profile the project names (JST_CREDENTIALS, plain config);
#     3. else the machine default (<config>/jira-sdlc/default, one line);
#     4. else an error.
#   A profile is <config>/jira-sdlc/profiles/<name>.env, where <config> is
#   $XDG_CONFIG_HOME or ~/.config (%APPDATA% on Windows). It holds the seven
#   keys and PROFILE_GITHUB_OWNERS, is refused when group or others can read
#   it, and is used only when every GitHub owner of the project's remotes (the
#   root's and each member's) is in PROFILE_GITHUB_OWNERS. A partial set, in
#   the project or in a profile, is an error naming what's missing: nothing is
#   filled in from another source, so a script never quietly acts as somebody
#   else.
#
# Nothing here prints a value: jst_cred hands one to its caller, and every
# message names keys, files and owners only.

JST_LOCAL_ENV_NAME=jira-sdlc-tools.local.env
JST_TEAM_ENV_NAME=jira-sdlc-tools.env
JST_CRED_KEYS="JIRA_ASSIGNER_EMAIL JIRA_ASSIGNER_TOKEN JIRA_EXECUTOR_EMAIL JIRA_EXECUTOR_TOKEN JIRA_REVIEWER_EMAIL JIRA_REVIEWER_TOKEN GITHUB_PAT_TOKEN"

JST_CFG_ROOT=""; JST_CFG_DIR=""

# jst_config_init [<root>] — read the config of the project at <root> (default:
# jst_root, else $PWD). Run again to switch projects; it drops the cached
# credential resolution.
jst_config_init() {
  JST_CFG_ROOT=${1:-}
  [ -n "$JST_CFG_ROOT" ] || JST_CFG_ROOT=$(jst_root 2>/dev/null || true)
  [ -n "$JST_CFG_ROOT" ] || JST_CFG_ROOT=$PWD
  JST_CFG_DIR="$JST_CFG_ROOT/.jst"
  _jst_cred_done=""
}

# _jst_file_val <file> <NAME-PATTERN> — the value of the last matching line.
_jst_file_val() {
  local v
  [ -f "$1" ] || return 1
  v=$(grep -E "^[[:space:]]*($2)[[:space:]]*=" "$1" 2>/dev/null \
      | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# _jst_cfg_file <NAME-PATTERN> — which .jst/ file a plain key comes from.
_jst_cfg_file() {
  local f
  for f in "$JST_LOCAL_ENV_NAME" "$JST_TEAM_ENV_NAME"; do
    _jst_file_val "$JST_CFG_DIR/$f" "$1" >/dev/null && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# jst_cfg_raw <NAME-PATTERN> — the project's own value, local over team.
jst_cfg_raw() {
  local f
  [ -n "$JST_CFG_DIR" ] || jst_config_init
  for f in "$JST_LOCAL_ENV_NAME" "$JST_TEAM_ENV_NAME"; do
    _jst_file_val "$JST_CFG_DIR/$f" "$1" && return 0
  done
  return 1
}

# jst_is_cred_key <NAME> — exit 0 for a key of the credential group.
jst_is_cred_key() {
  case " $JST_CRED_KEYS " in *" $1 "*) return 0 ;; esac
  return 1
}

# jst_cfg <NAME-PATTERN> — a plain value; a credential key is answered from the
# group's one source, so no caller can read a token past the precedence.
jst_cfg() {
  [ -n "$JST_CFG_DIR" ] || jst_config_init
  if jst_is_cred_key "$1"; then jst_cred "$1"; return; fi
  jst_cfg_raw "$1"
}

# jst_config_home — <config>/jira-sdlc.
jst_config_home() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then printf '%s/jira-sdlc' "$XDG_CONFIG_HOME"; return; fi
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) [ -n "${APPDATA:-}" ] && { printf '%s/jira-sdlc' "$APPDATA"; return; } ;;
  esac
  printf '%s/.config/jira-sdlc' "$HOME"
}
jst_profiles_dir() { printf '%s/profiles' "$(jst_config_home)"; }
jst_profile_path() { printf '%s/%s.env' "$(jst_profiles_dir)" "$1"; }

# jst_tilde <path> — the path with $HOME shown as ~, for messages.
jst_tilde() {
  case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac
}

# jst_default_profile — the machine default's name, or nothing.
jst_default_profile() {
  local f n
  f="$(jst_config_home)/default"
  [ -f "$f" ] || return 1
  n=$(grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | head -1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# jst_valid_profile_name <name> — letters, digits, . _ - (no path in it).
jst_valid_profile_name() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

# jst_file_mode <file> — its permission bits in octal (644), or nothing.
jst_file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null
}

# jst_loose_mode <file> — exit 0 when group or others have any access to it.
# Not checked on Windows, where the bits mean nothing and %APPDATA% is the
# user's own (win/_jst_config.ps1 does the same).
jst_loose_mode() {
  local m
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 1 ;; esac
  m=$(jst_file_mode "$1") || return 1
  [ -n "$m" ] || return 1
  [ $(( 0$m & 077 )) -ne 0 ]
}

# _jst_owner <remote-url> — the github.com owner, lowercased; non-zero otherwise.
_jst_owner() {
  local s
  case "$1" in *github.com*) ;; *) return 1 ;; esac
  s=${1#*github.com}; s=${s#:}; s=${s#/}; s=${s%/}; s=${s%.git}
  printf '%s' "$s" | grep -qE '^[^/]+/[^/]+$' || return 1
  printf '%s' "${s%%/*}" | tr '[:upper:]' '[:lower:]'
}

# _jst_resolve_url <base-url> <url> — repos.sh's resolve_url: a relative
# .gitmodules URL (./x, ../x) resolved against the root's origin.
_jst_resolve_url() {
  local base="$1" rel="$2"
  case "$rel" in ./*|../*) ;; *) printf '%s' "$rel"; return 0 ;; esac
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

# jst_project_owners — the GitHub owners of the project's remotes: the root's
# origin and each member's (JST_MEMBERS), lowercased, sorted, space-separated.
# A member not checked out is read from .gitmodules. Non-GitHub remotes add
# nothing; no owner at all prints nothing.
jst_project_owners() {
  local root_url url p name o owners=""
  [ -n "$JST_CFG_DIR" ] || jst_config_init
  root_url=$(git -C "$JST_CFG_ROOT" config --get remote.origin.url 2>/dev/null || true)
  o=$(_jst_owner "$root_url") && owners="$o"
  for p in $(jst_cfg_raw JST_MEMBERS || true); do
    url=""
    if [ -e "$JST_CFG_ROOT/$p/.git" ]; then
      url=$(git -C "$JST_CFG_ROOT/$p" config --get remote.origin.url 2>/dev/null || true)
    fi
    if [ -z "$url" ] && [ -f "$JST_CFG_ROOT/.gitmodules" ]; then
      name=$(git config -f "$JST_CFG_ROOT/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null \
             | awk -v p="$p" '$2 == p { sub(/^submodule\./, "", $1); sub(/\.path$/, "", $1); print $1; exit }')
      [ -n "$name" ] && url=$(git config -f "$JST_CFG_ROOT/.gitmodules" --get "submodule.$name.url" 2>/dev/null || true)
      [ -n "$url" ] && url=$(_jst_resolve_url "$root_url" "$url")
    fi
    o=$(_jst_owner "$url") && owners="$owners $o"
  done
  printf '%s\n' $owners | awk 'NF && !seen[$0]++' | sort | tr '\n' ' ' | sed 's/ $//'
}

# _jst_cred_fail <message> <remedy> — the resolution failed.
_jst_cred_fail() { JST_CRED_SOURCE=""; JST_CRED_ERR=$1; JST_CRED_FIX=$2; return 1; }

# jst_cred_kind — which source the group would come from, without reading a
# profile: project (the project sets a key of the group), profile (it names one,
# or the machine has a default), none. ensure_local_env decides by this.
jst_cred_kind() {
  local k
  [ -n "$JST_CFG_DIR" ] || jst_config_init
  for k in $JST_CRED_KEYS; do
    jst_cfg_raw "$k" >/dev/null && { printf 'project'; return 0; }
  done
  if jst_cfg_raw JST_CREDENTIALS >/dev/null || jst_default_profile >/dev/null; then
    printf 'profile'; return 0
  fi
  printf 'none'
}

# jst_cred_resolve — decide the group's source once per project. Sets:
#   JST_CRED_SOURCE  project | profile | "" (failed: JST_CRED_ERR, JST_CRED_FIX)
#   JST_CRED_WHERE   where the values come from, for messages
#   JST_CRED_NAME    the profile's name, JST_CRED_FILE the file read
#   JST_CRED_VIA     how the profile was chosen
#   JST_CRED_OWNERS  the project's owners; JST_CRED_PROFILE_OWNERS the profile's
# Exit 0 when a source is usable.
jst_cred_resolve() {
  local k v set="" missing="" name via file mode o lacking=""
  [ -n "$JST_CFG_DIR" ] || jst_config_init
  if [ -n "${_jst_cred_done:-}" ]; then [ -n "$JST_CRED_SOURCE" ]; return; fi
  _jst_cred_done=1
  JST_CRED_SOURCE=""; JST_CRED_ERR=""; JST_CRED_FIX=""; JST_CRED_WHERE=""
  JST_CRED_NAME=""; JST_CRED_FILE=""; JST_CRED_VIA=""; JST_CRED_OWNERS=""; JST_CRED_PROFILE_OWNERS=""

  # 1. The project's own .jst/ files: any key of the group makes them the source.
  for k in $JST_CRED_KEYS; do
    if v=$(jst_cfg_raw "$k"); then set="$set $k"; printf -v "_JST_CV_$k" '%s' "$v"
    else missing="$missing $k"; fi
  done
  if [ -n "$set" ]; then
    JST_CRED_FILE="$JST_CFG_DIR/$JST_LOCAL_ENV_NAME"
    JST_CRED_WHERE=".jst/$JST_LOCAL_ENV_NAME"
    if [ -n "$missing" ]; then
      for k in $JST_CRED_KEYS; do printf -v "_JST_CV_$k" '%s' ""; done
      _jst_cred_fail "the project's .jst/ sets part of the credential group (${set# }) — missing:${missing} (a partial set is never filled in from a profile)" \
        "set the missing keys in .jst/$JST_LOCAL_ENV_NAME, or remove every key of the group from .jst/ and use a profile (JST_CREDENTIALS) — see skills/_shared/project-config.md § Credentials"
      return 1
    fi
    JST_CRED_SOURCE=project
    return 0
  fi

  # 2./3. A profile: the one the project names, else the machine default.
  if name=$(jst_cfg_raw JST_CREDENTIALS); then
    via="JST_CREDENTIALS in .jst/$(_jst_cfg_file JST_CREDENTIALS)"
  elif name=$(jst_default_profile); then
    via="the machine default ($(jst_tilde "$(jst_config_home)/default"))"
  else
    _jst_cred_fail "no credentials: the project's .jst/ sets none of the credential group, names no profile (JST_CREDENTIALS), and this machine has no default profile ($(jst_tilde "$(jst_config_home)/default"))" \
      "name a profile with JST_CREDENTIALS = <name> in .jst/$JST_TEAM_ENV_NAME (a file in $(jst_tilde "$(jst_profiles_dir)")), or set the seven keys in .jst/$JST_LOCAL_ENV_NAME — see skills/_shared/project-config.md § Credentials"
    return 1
  fi
  JST_CRED_NAME=$name; JST_CRED_VIA=$via
  if ! jst_valid_profile_name "$name"; then
    _jst_cred_fail "profile name '$name' ($via) is not a name: letters, digits, '.', '_' and '-' only" \
      "fix the name ($via)"
    return 1
  fi
  file=$(jst_profile_path "$name"); JST_CRED_FILE=$file
  JST_CRED_WHERE="profile $name ($(jst_tilde "$file"))"
  if [ ! -f "$file" ]; then
    _jst_cred_fail "profile '$name' ($via) not found: $(jst_tilde "$file")" \
      "create the profile (see skills/_shared/templates/credential-profile.env.example; chmod 600), or name an existing one in $(jst_tilde "$(jst_profiles_dir)")"
    return 1
  fi
  if jst_loose_mode "$file"; then
    mode=$(jst_file_mode "$file")
    _jst_cred_fail "profile $(jst_tilde "$file") is open to group or others (mode $mode) — refused" \
      "chmod 600 $(jst_tilde "$file")"
    return 1
  fi
  missing=""
  for k in $JST_CRED_KEYS; do
    if v=$(_jst_file_val "$file" "$k"); then printf -v "_JST_CV_$k" '%s' "$v"
    else missing="$missing $k"; printf -v "_JST_CV_$k" '%s' ""; fi
  done
  JST_CRED_PROFILE_OWNERS=$(_jst_file_val "$file" PROFILE_GITHUB_OWNERS | tr '[:upper:]' '[:lower:]' | tr ',' ' ' | xargs 2>/dev/null || true)
  if [ -n "$missing" ]; then
    for k in $JST_CRED_KEYS; do printf -v "_JST_CV_$k" '%s' ""; done
    _jst_cred_fail "profile $(jst_tilde "$file") lacks:${missing}" \
      "add the missing keys to $(jst_tilde "$file") — a profile holds all seven"
    return 1
  fi

  # The match check: every owner of the project's remotes is the profile's.
  JST_CRED_OWNERS=$(jst_project_owners)
  if [ -z "$JST_CRED_PROFILE_OWNERS" ]; then
    for k in $JST_CRED_KEYS; do printf -v "_JST_CV_$k" '%s' ""; done
    _jst_cred_fail "profile $(jst_tilde "$file") sets no PROFILE_GITHUB_OWNERS, so it can't be matched to this project (owners: ${JST_CRED_OWNERS:-none})" \
      "set PROFILE_GITHUB_OWNERS (the GitHub owners its PAT is for, space-separated) in $(jst_tilde "$file")"
    return 1
  fi
  if [ -z "$JST_CRED_OWNERS" ]; then
    for k in $JST_CRED_KEYS; do printf -v "_JST_CV_$k" '%s' ""; done
    _jst_cred_fail "the project has no github.com remote, so profile '$name' (owners: $JST_CRED_PROFILE_OWNERS) can't be matched to it" \
      "attach the project's GitHub 'origin' remote, or set the seven keys in .jst/$JST_LOCAL_ENV_NAME"
    return 1
  fi
  for o in $JST_CRED_OWNERS; do
    case " $JST_CRED_PROFILE_OWNERS " in *" $o "*) ;; *) lacking="$lacking $o" ;; esac
  done
  if [ -n "$lacking" ]; then
    for k in $JST_CRED_KEYS; do printf -v "_JST_CV_$k" '%s' ""; done
    _jst_cred_fail "profile '$name' ($via) is for GitHub owner(s) $JST_CRED_PROFILE_OWNERS, but this project's remotes are owned by $JST_CRED_OWNERS (not covered:${lacking})" \
      "name a profile whose PROFILE_GITHUB_OWNERS covers ${lacking# }, add the owner to $(jst_tilde "$file") if its PAT really is for it, or set the seven keys in .jst/$JST_LOCAL_ENV_NAME"
    return 1
  fi
  JST_CRED_SOURCE=profile
  return 0
}

# jst_cred <KEY> — one credential value, from the group's source. Non-zero (and
# no output) when the resolution failed: the caller reports JST_CRED_ERR.
jst_cred() {
  local var
  jst_is_cred_key "$1" || return 1
  jst_cred_resolve || return 1
  var="_JST_CV_$1"
  [ -n "${!var:-}" ] || return 1
  printf '%s' "${!var}"
}

# jst_cred_describe — one line for statuscheck's credentials row: the source
# and the match, never a value.
jst_cred_describe() {
  jst_cred_resolve || return 1
  if [ "$JST_CRED_SOURCE" = project ]; then
    printf 'project .jst/ (.jst/%s)' "$JST_LOCAL_ENV_NAME"
  else
    printf 'profile %s (%s) · via %s · owners match (%s)' "$JST_CRED_NAME" "$(jst_tilde "$JST_CRED_FILE")" "$JST_CRED_VIA" "$JST_CRED_OWNERS"
  fi
}
