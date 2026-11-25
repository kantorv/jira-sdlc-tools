#!/usr/bin/env bash
# stack-trial.sh — try a project's ./stack through the contract's whole lifecycle,
# in a throwaway checkout, as one instance; report what happened.
#
#   stack-trial.sh [--ref <commit>] [--instance N] [--keep]
#
# Run from the project's main checkout. It makes a detached worktree at --ref
# (default HEAD; with member repos, each member a worktree of its own repo at the
# commit the ref records), picks a free instance N (default: the highest free one
# in the stack's range), gives it a private home, and runs, from that checkout:
#
#   bootstrap → start (+ its {"urls": …} line) → each URL answers → start again
#   → teardown while running must exit 3 → stop (its ports free) → start (a
#   restart) → stop → teardown → teardown again → the leak check
#
# The leak check: no process from the checkout, nothing listening in N's ports,
# no container, network or volume named <NAME_PREFIX>-i<N>, nothing in the home
# but logs/. The first failing step ends the lifecycle; stop and teardown then
# run as cleanup, and the leak check still runs.
#
# The stack gets the contract's environment: CF_INSTANCE_HOME (the trial's home)
# and CF_MAIN_CHECKOUT (this checkout), plus the caller's own environment.
#
# Output: a markdown table (step | result | detail), then the logs' folder, then
# the last line: "TRIAL PASSED" or "TRIAL FAILED: <step>". The worktree is removed
# (--keep leaves it); the home and its logs stay.
#
# Exit 0 passed; 1 failed; 2 refused before starting (no ./stack, no marker, a bad
# resources.conf, no free N, or a SHARED_PORTS port of the main checkout's that nothing
# listens on: an instance can't start without those services, so the trial doesn't try). Ported from ControlFreak's pipeline/trial.py
# (controlfreak@7af306f). Docs: https://kantorv.github.io/jira-sdlc-tools/docs/running-multiple-copies

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_stack.sh"

usage() { sed -n '2,6p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
REF=HEAD N="" KEEP=0
while [ $# -gt 0 ]; do
  case $1 in
    --ref) REF=${2:-}; shift 2 ;;
    --instance) N=${2:-}; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) usage ;;
  esac
done
T_BOOT=${STACK_TRIAL_TIMEOUT_START:-900} T_STOP=${STACK_TRIAL_TIMEOUT_STOP:-300}

refuse() { printf 'stack-trial: %s\n' "$*" >&2; echo "TRIAL FAILED: refused: $*"; exit 2; }
MAIN=$(git rev-parse --show-toplevel 2>/dev/null) || refuse "not in a git repository"
SHA=$(git -C "$MAIN" rev-parse --verify --short "$REF^{commit}" 2>/dev/null) || refuse "no commit $REF"
git -C "$MAIN" cat-file -e "$SHA:stack" 2>/dev/null || refuse "$REF has no ./stack"
[ "$(git -C "$MAIN" show "$SHA:stack" | sed -n 2p)" = "# controlfreak-stack-contract: 1" ] \
  || refuse "./stack at $REF has no contract marker on line 2"
CONF_TMP=$(mktemp); git -C "$MAIN" show "$SHA:stack.d/resources.conf" > "$CONF_TMP" 2>/dev/null
stack_conf "$CONF_TMP" || { rm -f "$CONF_TMP"; refuse "no valid stack.d/resources.conf at $REF"; }
rm -f "$CONF_TMP"
stack_need NAME_PREFIX INSTANCE_MIN INSTANCE_MAX || refuse "resources.conf lacks a required key"
PREFIX=${CONF[NAME_PREFIX]}

# The main checkout's services every instance needs (SHARED_PORTS: a broker, the database a seed
# copies). Without them the lifecycle fails partway, and its cleanup can leave things behind.
if [ -n "${CONF[SHARED_PORTS]:-}" ]; then
  down=""
  for p in ${CONF[SHARED_PORTS]//,/ }; do
    [[ $p =~ ^[1-9][0-9]{0,4}$ ]] || refuse "SHARED_PORTS has '$p', not a port"
    [ -n "$(ports_busy "$p" "$p")" ] || down+="$p "
  done
  [ -z "$down" ] || refuse "nothing listens on the main checkout's shared port(s) ${down% } (SHARED_PORTS): start those services in the main checkout (stack.d/README.md, \"Shared services that must already run\"), then run the trial again"
fi

n_free() {  # <N> → 0 when nothing holds N
  local n=$1 first last
  [ -e "$(stack_home "$n")/owner" ] && return 1
  [ -n "$(docker_named "$PREFIX-i$n")" ] && return 1
  read -r first last < <(stack_ports "$n") || true
  [ -z "${first:-}" ] || [ -z "$(ports_busy "$first" "$last")" ]
}
if [ -z "$N" ]; then
  for ((n = CONF[INSTANCE_MAX]; n >= CONF[INSTANCE_MIN]; n--)); do n_free "$n" && { N=$n; break; }; done
  [ -n "$N" ] || refuse "no free instance in ${CONF[INSTANCE_MIN]}-${CONF[INSTANCE_MAX]}"
else
  [[ $N =~ ^[1-9][0-9]*$ ]] && [ "$N" -ge "${CONF[INSTANCE_MIN]}" ] && [ "$N" -le "${CONF[INSTANCE_MAX]}" ] || refuse "bad --instance $N"
  n_free "$N" || refuse "instance $N is in use"
fi
read -r PORT_FIRST PORT_LAST < <(stack_ports "$N") || true

RUN_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/jst-trials/$PREFIX-$(date +%Y%m%d-%H%M%S)
CHECKOUT=$RUN_DIR/checkout HOME_DIR=$RUN_DIR/home LOGS=$RUN_DIR/home/logs
mkdir -p "$LOGS" && chmod 700 "$HOME_DIR"

# Member repos: JST_MEMBERS from the committed team config, at the ref.
MEMBERS=$(git -C "$MAIN" show "$SHA:.jst/jira-sdlc-tools.env" 2>/dev/null \
  | grep -E '^[[:space:]]*JST_MEMBERS[[:space:]]*=' | tail -1 | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')

ROWS=() FAILED=""
row() { ROWS+=("| $1 | $2 | $3 |"); [ "$2" = FAIL ] && [ -z "$FAILED" ] && FAILED=$1; return 0; }

make_checkout() {
  git -C "$MAIN" worktree add --detach "$CHECKOUT" "$SHA" >/dev/null 2>"$LOGS/checkout.err" || return 1
  local m sha
  for m in $MEMBERS; do
    sha=$(git -C "$MAIN" ls-tree "$SHA" -- "$m" | awk '$1 == "160000" {print $3}')
    [ -n "$sha" ] || { echo "member $m: no gitlink at $SHA" >> "$LOGS/checkout.err"; return 1; }
    rmdir "$CHECKOUT/$m" 2>/dev/null || true
    git -C "$MAIN/$m" worktree add --detach "$CHECKOUT/$m" "$sha" >/dev/null 2>>"$LOGS/checkout.err" || return 1
  done
}
remove_checkout() {
  local m
  for m in $MEMBERS; do git -C "$MAIN/$m" worktree remove --force "$CHECKOUT/$m" >/dev/null 2>&1; git -C "$MAIN/$m" worktree prune 2>/dev/null; done
  git -C "$MAIN" worktree remove --force "$CHECKOUT" >/dev/null 2>&1
  rm -rf "$CHECKOUT"; git -C "$MAIN" worktree prune 2>/dev/null
}

# verb <verb> <label> → runs ./stack <verb> --instance N; sets RC
verb() {
  local v=$1 label=$2 t=$T_STOP
  case $v in bootstrap | start) t=$T_BOOT ;; esac
  ( cd "$CHECKOUT" && CF_INSTANCE_HOME=$HOME_DIR CF_MAIN_CHECKOUT=$MAIN \
      timeout --kill-after=10 "$t" ./stack "$v" --instance "$N" ) >"$LOGS/$label.out" 2>"$LOGS/$label.err" </dev/null
  RC=$?
}
expect() {  # <verb> <label> <want> → records the step; 0 when it matched
  verb "$1" "$2"
  if [ "$RC" = "$3" ]; then row "$2" OK "exit $RC"; return 0; fi
  local why="exit $RC, expected $3" st
  [ "$RC" = 124 ] && why="timed out"
  st=$(grep '^::step-failed::' "$LOGS/$2.err" 2>/dev/null | tail -1 | sed 's/^::step-failed:://')
  [ -n "$st" ] && why="$why, in its step '$st'"
  row "$2" FAIL "$why (logs/$2.err)"; return 1
}
wait_ports_free() {  # N's port block and subnet address: prints what still listens
  [ -n "${PORT_FIRST:-}" ] || [ -n "${CONF[SUBNET]:-}" ] || return 0
  local i busy
  for ((i = 0; i < 30; i++)); do
    busy=""
    [ -z "${PORT_FIRST:-}" ] || busy=$(ports_busy "$PORT_FIRST" "$PORT_LAST")
    busy="$busy $(subnet_listeners "$N")"; busy=${busy# }; busy=${busy% }
    [ -z "$busy" ] && return 0; sleep 0.5
  done
  printf '%s' "$busy"; return 1
}

lifecycle() {
  expect bootstrap bootstrap 0 || return
  expect start start 0 || return
  local urls line name url code bad=""
  line=$(grep -v '^[[:space:]]*$' "$LOGS/start.out" | tail -1)
  urls=$(jq -r '.urls | to_entries[] | "\(.key)\t\(.value)"' <<< "$line" 2>/dev/null)
  [ -n "$urls" ] || { row urls FAIL 'start printed no {"urls": {...}} as its last stdout line'; return; }
  local detail=""
  while IFS=$'\t' read -r name url; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null); code=${code:-000}
    detail+="$name $url → $code; "
    { [ "$code" = 000 ] || [ "$code" -ge 500 ]; } && bad=1
  done <<< "$urls"
  if [ -n "$bad" ]; then row urls FAIL "${detail%; }"; return; else row urls OK "${detail%; }"; fi
  expect start start-again 0 || return
  expect teardown teardown-while-running 3 || return
  expect stop stop 0 || return
  local busy where="${PORT_FIRST:+ports $PORT_FIRST-$PORT_LAST}"
  [ -z "${CONF[SUBNET]:-}" ] || where="${where:+$where, }$(cut -d. -f1-2 <<< "${CONF[SUBNET]}").$N.*"
  if busy=$(wait_ports_free); then row ports-free OK "nothing listens in ${where:-its ports}"
  else row ports-free FAIL "still listening: $busy"; return; fi
  expect start restart 0 || return
  expect stop stop-again 0 || return
  expect teardown teardown 0 || return
  expect teardown teardown-again 0
}

leak_check() {
  local problems="" procs busy dock files p
  procs=$(for p in /proc/[0-9]*; do
      [ "${p#/proc/}" = "$$" ] && continue
      c=$(readlink "$p/cwd" 2>/dev/null); cmd=$(tr '\0' ' ' 2>/dev/null < "$p/cmdline")
      case "$c/" in "$CHECKOUT"/*) echo "${p#/proc/}"; continue ;; esac
      case "$cmd" in *"$CHECKOUT/"*) echo "${p#/proc/}" ;; esac
    done | tr '\n' ' ')
  [ -n "${procs// }" ] && problems+="processes: $procs; "
  busy=$(wait_ports_free) || problems+="listening: $busy; "
  dock=$(docker_named "$PREFIX-i$N" | tr '\n' ',' | sed 's/,$//')
  [ -n "$dock" ] && problems+="docker: $dock; "
  files=$(ls -A "$HOME_DIR" | grep -v '^logs$' | tr '\n' ' ')
  [ -n "$files" ] && problems+="in the home: $files; "
  if [ -n "$problems" ]; then row leak-check FAIL "${problems%; }"; else row leak-check OK "nothing left behind"; fi
  for p in $procs; do kill -9 -- "-$(ps -o pgid= "$p" | tr -d ' ')" 2>/dev/null || kill -9 "$p" 2>/dev/null; done
}

trap 'row interrupted FAIL "the trial was interrupted"; verb stop cleanup-stop; verb teardown cleanup-teardown; [ "$KEEP" = 1 ] || remove_checkout; exit 1' INT TERM

printf 'Trial of %s at %s as instance %s (%s-i%s)\n\n' "$(basename "$MAIN")" "$SHA" "$N" "$PREFIX" "$N" >&2
if make_checkout; then
  row checkout OK "$SHA${MEMBERS:+, members: $MEMBERS}"
  lifecycle
  if [ -n "$FAILED" ]; then
    verb stop cleanup-stop; verb teardown cleanup-teardown
    row cleanup INFO "stop and teardown ran after the failure (logs/cleanup-*.err)"
  fi
  leak_check
else
  row checkout FAIL "$(tail -3 "$LOGS/checkout.err" | tr '\n' ' ')"
fi
[ "$KEEP" = 1 ] || remove_checkout

printf '| step | result | detail |\n| -- | -- | -- |\n'
printf '%s\n' "${ROWS[@]}"
printf '\nLogs: %s\n' "$LOGS"
if [ -z "$FAILED" ]; then echo "TRIAL PASSED"; exit 0; fi
echo "TRIAL FAILED: $FAILED"; exit 1
