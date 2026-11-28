#!/usr/bin/env bash
# jst-credentials.sh — move projects from their own copy of the credentials to
# the machine's credential profiles (JSW-37).
#
# Usage:
#   bash jst-credentials.sh migrate --roots <dir> [<dir>…] [--apply]
#
# migrate finds every project under the roots (a folder whose .jst/ holds a
# jira-sdlc local env) and, for each one whose local env sets the credential
# group (the three Jira role pairs and GITHUB_PAT_TOKEN) to exactly the values
# of one profile — and whose GitHub owners that profile covers — sets
# JST_CREDENTIALS = <profile> in that local env and removes the group from it
# and from each of its linked worktrees' copies. JIRA_ACCOUNT_URL and every
# other key stay where they are. Any other project is reported and left alone:
# a partial group, credentials no profile holds, a profile that doesn't cover
# its owners, a worktree copy holding other credentials.
#
# A dry run by default: it says what --apply would do and writes nothing.
# Values are compared, never printed: the output names projects, profiles,
# keys and owners only.
#
# Output: TSV after a header, one row per project
#   project  result  profile  detail
#   result:  migrate (dry run) · migrated · unchanged · error
# Exit 0 — done (the rows say what). 1 — an --apply write failed (its row says
# which). 2 — usage.
#
# POSIX only: a one-time tool for a machine's own checkouts, run by hand; the
# skills never call it (no win/ twin, like instance.sh). Profiles are read from
# $XDG_CONFIG_HOME/jira-sdlc/profiles (default ~/.config/jira-sdlc/profiles).

set -u
SC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SC_DIR/_jst_root.sh"
. "$SC_DIR/_jst_config.sh"

die_usage() { printf 'jst-credentials: %s\n' "$1" >&2; exit 2; }

VERB=${1:-}; [ $# -gt 0 ] && shift
[ "$VERB" = migrate ] || die_usage "usage: jst-credentials.sh migrate --roots <dir> [<dir>…] [--apply]"
ROOTS=(); APPLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --roots) shift
             while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do ROOTS+=("$1"); shift; done ;;
    *) die_usage "unknown argument '$1'" ;;
  esac
done
[ "${#ROOTS[@]}" -gt 0 ] || die_usage "--roots needs at least one directory"
for i in "${!ROOTS[@]}"; do
  [ -d "${ROOTS[$i]}" ] || die_usage "not a directory: ${ROOTS[$i]}"
  ROOTS[$i]=$(cd "${ROOTS[$i]}" && pwd -P)
done

LE=$JST_LOCAL_ENV_NAME
CRED_RE=$(printf '%s' "$JST_CRED_KEYS" | tr ' ' '|')

# --- the profiles: usable ones only (a name, mode 0600, all seven keys) ---------
PROFILES=()
PDIR=$(jst_profiles_dir)
if [ -d "$PDIR" ]; then
  for f in "$PDIR"/*.env; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .env)
    jst_valid_profile_name "$n" || continue
    jst_loose_mode "$f" && { printf 'jst-credentials: skipping profile %s: open to group or others (chmod 600 %s)\n' "$n" "$(jst_tilde "$f")" >&2; continue; }
    ok=1
    for k in $JST_CRED_KEYS; do _jst_file_val "$f" "$k" >/dev/null || ok=""; done
    [ -n "$ok" ] || { printf 'jst-credentials: skipping profile %s: it lacks a key of the credential group\n' "$n" >&2; continue; }
    PROFILES+=("$n")
  done
fi

# same_group <file-a> <file-b> — exit 0 when both set all seven keys alike.
same_group() {
  local k a b
  for k in $JST_CRED_KEYS; do
    a=$(_jst_file_val "$1" "$k") || return 1
    b=$(_jst_file_val "$2" "$k") || return 1
    [ "$a" = "$b" ] || return 1
  done
}

# group_state <file> — all | none | partial:<missing keys>
group_state() {
  local k set="" missing=""
  for k in $JST_CRED_KEYS; do
    if _jst_file_val "$1" "$k" >/dev/null; then set=1; else missing="$missing $k"; fi
  done
  if [ -z "$set" ]; then echo none
  elif [ -z "$missing" ]; then echo all
  else echo "partial:${missing# }"; fi
}

# rewrite <file> <profile> — drop the group and any JST_CREDENTIALS, then name
# the profile. Same folder, same mode, replaced in one rename.
rewrite() {
  local f="$1" tmp mode
  mode=$(jst_file_mode "$f"); [ -n "$mode" ] || mode=600
  tmp=$(cd "$(dirname "$f")" && umask 077 && mktemp ".jst-credentials.XXXXXX") || return 1
  tmp="$(dirname "$f")/$tmp"
  { grep -vE "^[[:space:]]*($CRED_RE|JST_CREDENTIALS)[[:space:]]*=" "$f" || true
    printf 'JST_CREDENTIALS=%s\n' "$2"; } > "$tmp" 2>/dev/null \
    && chmod "$mode" "$tmp" && mv -f "$tmp" "$f" && return 0
  rm -f "$tmp"; return 1
}

# --- the projects under the roots ------------------------------------------------
FOUND=$(for r in "${ROOTS[@]}"; do
  find "$r" \( -name node_modules -o -name .git -o -name venv -o -name .venv -o -name .cache \) -prune \
    -o -type f -path "*/.jst/$LE" -print 2>/dev/null
done | sed "s#/\\.jst/$LE\$##" | awk '!seen[$0]++' | sort)

printf 'project\tresult\tprofile\tdetail\n'
RC=0
MAINS=" "
while IFS= read -r p; do
  [ -n "$p" ] || continue
  p=$(cd "$p" && pwd -P)
  if jst_is_linked_worktree "$p"; then
    m=$(jst_main_checkout "$p")
    [ -n "$m" ] && printf '%s\n' "$FOUND" | grep -qxF "$m" && continue   # handled with its main checkout
    printf '%s\tunchanged\t-\ta linked worktree whose main checkout (%s) is not among the projects found\n' "$p" "${m:-gone}"
    continue
  fi
  case "$MAINS" in *" $p "*) continue ;; esac
  MAINS="$MAINS$p "
  f="$p/.jst/$LE"
  st=$(group_state "$f")
  case "$st" in
    none)
      used=$(_jst_file_val "$f" JST_CREDENTIALS || _jst_file_val "$p/.jst/$JST_TEAM_ENV_NAME" JST_CREDENTIALS || true)
      printf '%s\tunchanged\t%s\t%s\n' "$p" "${used:--}" "$( [ -n "$used" ] && echo "already names profile $used" || echo "its local env holds no credential group")"
      continue ;;
    partial:*)
      printf '%s\tunchanged\t-\ta partial credential group (missing: %s)\n' "$p" "${st#partial:}"
      continue ;;
  esac
  match=()
  for n in "${PROFILES[@]+"${PROFILES[@]}"}"; do same_group "$f" "$(jst_profile_path "$n")" && match+=("$n"); done
  if [ "${#match[@]}" -eq 0 ]; then
    printf '%s\tunchanged\t-\town credentials: no profile holds the same seven values\n' "$p"; continue
  fi
  if [ "${#match[@]}" -gt 1 ]; then
    printf '%s\tunchanged\t-\tmatches several profiles (%s): name one by hand\n' "$p" "${match[*]}"; continue
  fi
  n=${match[0]}
  jst_config_init "$p"
  owners=$(jst_project_owners)
  powners=$(_jst_file_val "$(jst_profile_path "$n")" PROFILE_GITHUB_OWNERS | tr '[:upper:]' '[:lower:]' | tr ',' ' ' | xargs 2>/dev/null || true)
  lacking=""
  [ -n "$owners" ] || lacking="(no github.com remote)"
  for o in $owners; do case " $powners " in *" $o "*) ;; *) lacking="$lacking $o" ;; esac; done
  if [ -n "$lacking" ]; then
    printf '%s\tunchanged\t%s\tsame values as profile %s, but its owners (%s) don'"'"'t cover the project'"'"'s (%s)\n' "$p" "$n" "$n" "${powners:-none}" "${owners:-none}"
    continue
  fi
  # Its worktrees' copies: none of the group, or the same values, else hands off.
  wts=(); blocked=""
  while IFS= read -r w; do
    [ -n "$w" ] && [ "$w" != "$p" ] && [ -f "$w/.jst/$LE" ] || continue
    case "$(group_state "$w/.jst/$LE")" in
      none) ;;
      all) same_group "$w/.jst/$LE" "$f" && wts+=("$w") || blocked="$blocked $w" ;;
      *) blocked="$blocked $w" ;;
    esac
  done < <(git -C "$p" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  if [ -n "$blocked" ]; then
    printf '%s\tunchanged\t%s\tworktree copies hold other credentials:%s\n' "$p" "$n" "$blocked"; continue
  fi
  detail="$f and ${#wts[@]} worktree cop$( [ "${#wts[@]}" -eq 1 ] && echo y || echo ies)"
  if [ -z "$APPLY" ]; then
    printf '%s\tmigrate\t%s\twould set JST_CREDENTIALS=%s and remove the group from %s\n' "$p" "$n" "$n" "$detail"
    continue
  fi
  failed=""
  rewrite "$f" "$n" || failed="$f"
  for w in "${wts[@]+"${wts[@]}"}"; do rewrite "$w/.jst/$LE" "$n" || failed="$failed $w/.jst/$LE"; done
  if [ -n "$failed" ]; then
    printf '%s\terror\t%s\tcould not rewrite: %s\n' "$p" "$n" "$failed"; RC=1; continue
  fi
  jst_config_init "$p"
  if jst_cred_resolve && [ "$JST_CRED_SOURCE" = profile ]; then
    printf '%s\tmigrated\t%s\tset JST_CREDENTIALS=%s and removed the group from %s\n' "$p" "$n" "$n" "$detail"
  else
    printf '%s\terror\t%s\trewritten, but the credentials no longer resolve: %s\n' "$p" "$n" "$JST_CRED_ERR"; RC=1
  fi
done <<< "$FOUND"
exit "$RC"
