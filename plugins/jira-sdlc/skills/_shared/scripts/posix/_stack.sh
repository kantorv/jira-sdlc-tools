# _stack.sh — helpers for the stack contract's files, shared by instance.sh,
# stack-resources.sh and stack-trial.sh. Sourced, never run:
#   . "$(dirname "${BASH_SOURCE[0]}")/_stack.sh"
#
# POSIX only: stack contract v1 is bash, so these scripts have no win/ twins
# (onboarding decision D11: Windows deferred). Docs:
# https://kantorv.github.io/jira-sdlc-tools/docs/running-multiple-copies

# stack_conf <file> — read stack.d/resources.conf into the associative array CONF.
# The contract's grammar: KEY=value lines and # comments only; a value has no
# quotes, spaces, $, backquotes or backslashes. Any other line → return 2 and
# say which, so every reader sees the same values or none.
declare -gA CONF=()
stack_conf() {
  local file=$1 line n=0
  CONF=()
  [ -f "$file" ] || { printf 'stack: no %s\n' "$file" >&2; return 2; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ $line =~ ^([A-Z][A-Z0-9_]*)=([^[:space:]\"\'\$\`\\]*)$ ]]; then
      CONF[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    else
      printf 'stack: %s:%s is not KEY=value: %s\n' "$file" "$n" "$line" >&2
      return 2
    fi
  done < "$file"
}

# stack_need <KEY>... — return 2 naming the first key CONF lacks.
stack_need() {
  local k
  for k in "$@"; do
    [ -n "${CONF[$k]:-}" ] || { printf 'stack: resources.conf has no %s\n' "$k" >&2; return 2; }
  done
}

# stack_ports <N> — "first last" of instance N's port block, or nothing when the
# stack has no port block (PORT_BASE and PORTS_PER_INSTANCE).
stack_ports() {
  local n=$1 base=${CONF[PORT_BASE]:-} per=${CONF[PORTS_PER_INSTANCE]:-} min=${CONF[INSTANCE_MIN]:-1}
  [ -n "$base" ] && [ -n "$per" ] || return 0
  local first=$((base + (n - min) * per))
  printf '%s %s\n' "$first" $((first + per - 1))
}

# stack_home <N> — instance N's home when no caller sets CF_INSTANCE_HOME.
stack_home() { printf '%s/.local/state/%s/i%s\n' "$HOME" "${CONF[NAME_PREFIX]}" "$1"; }

# listening_ports — every TCP port something listens on, one per line.
listening_ports() {
  ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un
}

# ports_busy <first> <last> — the listening ports in [first, last], space-separated.
ports_busy() {
  listening_ports | awk -v a="$1" -v b="$2" '$1 >= a && $1 <= b' | tr '\n' ' ' | sed 's/ $//'
}

# docker_named <name> — containers, networks and volumes named <name>, <name>-… or
# <name>_…, one "<kind> <name>" per line; nothing without Docker.
docker_named() {
  local name=$1 kind
  command -v docker >/dev/null 2>&1 || return 0
  for kind in container network volume; do
    case $kind in
      container) docker ps -a --format '{{.Names}}' ;;
      network) docker network ls --format '{{.Name}}' ;;
      volume) docker volume ls --format '{{.Name}}' ;;
    esac 2>/dev/null | awk -v n="$name" -v k="$kind" '$0 == n || index($0, n "-") == 1 || index($0, n "_") == 1 {print k " " $0}'
  done
}

# main_worktree <dir> — the repository's main worktree (git worktree list's first
# entry). Not the git common dir's parent: inside a submodule that is
# <workspace>/.git/modules/<member>, which is not a checkout.
main_worktree() { git -C "$1" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p'; }

# subnet_listeners <N> — "addr:port" listeners on instance N's /24 (<a.b>.N.*), when
# the stack has a SUBNET; nothing otherwise.
subnet_listeners() {
  local sub=${CONF[SUBNET]:-}
  [ -n "$sub" ] || return 0
  local net; net="$(cut -d. -f1-2 <<< "$sub").$1."
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -F "$net" | tr '\n' ' ' | sed 's/ $//'
}
