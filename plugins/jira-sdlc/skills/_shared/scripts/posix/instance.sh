#!/usr/bin/env bash
# instance.sh — an issue worktree's instance number N, and who holds it.
#
#   instance.sh assign <KEY> [--checkout <dir>] [--force]
#                                               pick and claim this checkout's N → "instance=<N>" "home=<dir>"
#   instance.sh lookup [--checkout <dir>]       the N this checkout holds → "instance=<N|none>" ("home=<dir>")
#   instance.sh number <KEY>                    the key's preferred N → "instance=<N>" (never "this worktree's N")
#   instance.sh claim <N> [--checkout <dir>] [--force]
#                                               record this checkout as N's owner
#   instance.sh owner <N>                       → "owner=<dir|none>" "home=<dir>"
#   instance.sh release <N>                     forget N's owner (after teardown)
#   instance.sh list                            every claimed N: "<N> <state> <owner>"
#
# Run from the checkout (an issue worktree, or the main checkout for list/owner);
# the values come from its stack.d/resources.conf (--conf <file> overrides).
#
# A checkout's N is its claim, never a formula (JSW-31, superseding onboarding
# decision D2): assign picks N once and claims it, and everything after reads it
# back with lookup. assign prefers the key's hash, cksum(KEY) mod (INSTANCE_MAX -
# INSTANCE_MIN + 1) + INSTANCE_MIN (what number prints), so an issue nothing collides
# with keeps the same N as before; when that N is taken it tries the next ones, wrapping
# round the range, and claims the first free one. A checkout that holds a claim gets
# that N back. Two keys can share a hash, so anything acting on "this worktree's
# instance" uses lookup, never number.
#
# claim (and assign, for each N it tries) refuses an N that is
#
#   held=<dir>      another live checkout owns N
#   stale=<dir>     N's owner is gone, but its instance home is still there
#   busy=<what>     no owner recorded, yet something runs as N: containers named
#                   <NAME_PREFIX>-i<N>, or listeners in N's ports (another tool's
#                   instance, e.g. ControlFreak's, which shares the range: D12)
#   unowned=<home>  N's home exists with no owner (made before instance.sh);
#                   --force adopts it (and skips busy=)
#   holds=<M>       (claim only) this checkout already holds M: release it first,
#                   or --force to hold both
#
# assign refuses with full=<MIN>-<MAX> when every N is refused, and lookup and
# assign with claims=<N>,<M> when the checkout holds more than one (release the
# one it doesn't use): which of them is its instance is a human's call.
#
# The owner file is <instance home>/owner; the home is the contract's default,
# ~/.local/state/<NAME_PREFIX>/i<N>. A teardown that ends the worktree's instance
# releases N (the web app's, .jst/teardown.sh). claim and assign run under one lock, the directory
# ~/.local/state/<NAME_PREFIX>/.lock (mkdir: atomic everywhere, flock isn't on
# macOS), holding the holder's pid. A lock whose pid is gone, or that has had no pid
# for 10 s, is broken, under a second lock (.lock.break) so only one waiter breaks it;
# a run removes the lock on exit only while it holds its own pid. The owner
# file is written to a temporary file in the state directory and renamed into
# place, so a crash leaves N either claimed or not, never half.
#
# Exit 0 done; 1 usage; 2 refused (above, or a bad resources.conf). Docs:
# https://kantorv.github.io/jira-sdlc-tools/docs/running-multiple-copies

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_stack.sh"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 1; }

VERB=${1:-}; [ -n "$VERB" ] || usage; shift
ARG=""; CHECKOUT=""; CONF_FILE=""; FORCE=0
while [ $# -gt 0 ]; do
  case $1 in
    --checkout) [ $# -ge 2 ] || usage; CHECKOUT=$2; shift 2 ;;
    --conf) [ $# -ge 2 ] || usage; CONF_FILE=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    -*) usage ;;
    *) [ -z "$ARG" ] || usage; ARG=$1; shift ;;
  esac
done

top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
CHECKOUT=$(readlink -f "${CHECKOUT:-$top}")
stack_conf "${CONF_FILE:-$top/stack.d/resources.conf}" || exit 2
stack_need NAME_PREFIX INSTANCE_MIN INSTANCE_MAX || exit 2
MIN=${CONF[INSTANCE_MIN]} MAX=${CONF[INSTANCE_MAX]}
BASE="$HOME/.local/state/${CONF[NAME_PREFIX]}"

valid_n() {
  [[ $1 =~ ^[1-9][0-9]*$ ]] && [ "$1" -ge "$MIN" ] && [ "$1" -le "$MAX" ] \
    || { printf 'instance: N must be an integer %s-%s (got %s)\n' "$MIN" "$MAX" "$1" >&2; exit 2; }
}

valid_key() {
  [[ $1 =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || { printf 'instance: not an issue key: %s\n' "$1" >&2; exit 1; }
}

preferred() {  # <KEY> → the key's hash N
  local sum; sum=$(printf '%s' "$1" | cksum | awk '{print $1}')
  printf '%s\n' $((sum % (MAX - MIN + 1) + MIN))
}

claims_of() {  # <dir> → every N whose owner is <dir>, ascending, one per line
  local f n
  for f in "$BASE"/i*/owner; do
    [ -f "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "$1" ] || continue
    n=${f%/owner}; n=${n##*/i}
    [[ $n =~ ^[0-9]+$ ]] && printf '%s\n' "$n"
  done | sort -n
}

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }  # GNU, then BSD

# dead <lock> <pid read from it> — true when the lock's holder is gone: its pid isn't
# running, or it has no pid and is older than 10 s (its holder was killed between the
# mkdir and the pid write, which are microseconds apart).
dead() {
  if [ -n "$2" ]; then
    ! kill -0 "$2" 2>/dev/null
  else
    local t; t=$(mtime "$1") || return 1
    [ -n "$t" ] && [ $(($(date +%s) - t)) -ge 10 ]
  fi
}

# unlock_dead <lock> <pid> — break a dead holder's lock, under a second mkdir lock:
# two waiters that saw the same dead pid must not both break, or the second would
# break the first's fresh, live lock and both would hold it. Under it the pid is read
# again, and the lock broken only if it is still the same dead one. False when another
# waiter holds the second lock.
unlock_dead() {
  local lk=$1 seen=$2 now
  mkdir "$lk.break" 2>/dev/null || return 1   # another waiter is breaking it: wait
  BREAKING="$lk.break"
  if [ -d "$lk" ]; then
    now=$(cat "$lk/pid" 2>/dev/null || true)
    if [ "$now" = "$seen" ] && dead "$lk" "$now"; then
      mv "$lk" "$lk.dead.$$" 2>/dev/null && rm -rf "$lk.dead.$$"
    fi
  fi
  rmdir "$lk.break"; BREAKING=""
}

# lock — take the state directory's lock for the rest of this run (claim, assign).
# Released on exit only while it is still ours (its pid is this run's).
LOCK_PID="" BREAKING=""
trap '[ -z "$BREAKING" ] || rmdir "$BREAKING" 2>/dev/null
  [ -z "$LOCK_PID" ] || [ "$(cat "$BASE/.lock/pid" 2>/dev/null)" != "$LOCK_PID" ] || rm -rf "$BASE/.lock"' EXIT
lock() {
  local lk="$BASE/.lock" pid tries=0
  mkdir -p "$BASE" && chmod 700 "$BASE" 2>/dev/null
  until mkdir "$lk" 2>/dev/null; do
    pid=$(cat "$lk/pid" 2>/dev/null || true)
    # A holder that died mid-claim left its claim all or nothing: break its lock.
    if dead "$lk" "$pid" && unlock_dead "$lk" "$pid"; then continue; fi
    tries=$((tries + 1))
    if [ "$tries" -ge 300 ]; then
      printf 'instance: %s has been held for 30 s (pid %s): if no instance.sh is running, remove it%s\n' \
        "$lk" "${pid:-none yet}" "$([ ! -d "$lk.break" ] || printf ' (and %s.break)' "$lk")" >&2
      exit 2
    fi
    sleep 0.1
  done
  LOCK_PID=$$; printf '%s\n' "$$" > "$lk/pid"
}

# What runs as N, read once per run: assign tries many Ns.
DOCKER_SEEN="" PORTS_SEEN="" SEEN=0
seen() {
  [ "$SEEN" = 1 ] && return
  DOCKER_SEEN=$(docker_all); PORTS_SEEN=$(listening_ports); SEEN=1
}

# refused <N> — true when this checkout can't claim N, with REFUSAL (the key=value
# line) and REASON (the stderr line) set; false when it can. OWN=1 when N is already
# this checkout's.
refused() {
  local n=$1 home owner busy first last p
  home=$(stack_home "$n"); owner=$(cat "$home/owner" 2>/dev/null || true); OWN=0
  if [ -n "$owner" ]; then
    if [ "$owner" = "$CHECKOUT" ]; then
      OWN=1; return 1
    elif [ -d "$owner" ]; then
      REFUSAL="held=$owner"; REASON="N=$n is held by $owner"
    else
      REFUSAL="stale=$owner"
      REASON="N=$n belongs to $owner, which is gone: ./stack teardown --instance $n, then claim again"
    fi
    return 0
  fi
  [ "$FORCE" = 1 ] && return 1
  seen
  busy=$(printf '%s\n' "$DOCKER_SEEN" | docker_match "${CONF[NAME_PREFIX]}-i$n" | tr '\n' ',' | sed 's/,$//')
  read -r first last < <(stack_ports "$n") || true
  if [ -n "${first:-}" ]; then
    p=$(printf '%s\n' "$PORTS_SEEN" | awk -v a="$first" -v b="$last" '$1 >= a && $1 <= b' | tr '\n' ' ' | sed 's/ $//')
    [ -z "$p" ] || busy="${busy:+$busy,}ports:$p"
  fi
  if [ -n "$busy" ]; then
    REFUSAL="busy=$busy"
    REASON="something already runs as N=$n ($busy): another tool's instance? stop it, or --force"
    return 0
  fi
  if [ -d "$home" ] && [ -n "$(ls -A "$home" 2>/dev/null | grep -v '^logs$')" ]; then
    REFUSAL="unowned=$home"; REASON="$home exists with no owner: tear it down, or --force to adopt it"
    return 0
  fi
  return 1
}

take() {  # <N> — write the owner file atomically
  local home tmp; home=$(stack_home "$1"); tmp="$BASE/.owner.$$"
  mkdir -p "$home" && chmod 700 "$home" && printf '%s\n' "$CHECKOUT" > "$tmp" && mv -f "$tmp" "$home/owner" \
    || { rm -f "$tmp"; printf 'instance: could not write %s/owner\n' "$home" >&2; exit 2; }
}

several() {  # <claims, one per line> — refuse: the checkout holds more than one N
  local list; list=$(printf '%s\n' "$1" | tr '\n' ',' | sed 's/,$//')
  printf 'claims=%s\n' "$list"
  printf 'instance: %s holds N=%s: release the one it does not use (instance.sh release <N>)\n' "$CHECKOUT" "$list" >&2
  exit 2
}

case $VERB in
  number)
    valid_key "$ARG"; printf 'instance=%s\n' "$(preferred "$ARG")"
    ;;
  lookup)
    [ -z "$ARG" ] || usage
    held=$(claims_of "$CHECKOUT")
    case $(printf '%s' "$held" | grep -c .) in
      0) printf 'instance=none\n' ;;
      1) printf 'instance=%s\nhome=%s\n' "$held" "$(stack_home "$held")" ;;
      *) several "$held" ;;
    esac
    ;;
  assign)
    valid_key "$ARG"; lock
    held=$(claims_of "$CHECKOUT")
    case $(printf '%s' "$held" | grep -c .) in
      0) ;;
      1) printf 'instance=%s\nhome=%s\n' "$held" "$(stack_home "$held")"; exit 0 ;;
      *) several "$held" ;;
    esac
    pref=$(preferred "$ARG"); size=$((MAX - MIN + 1)); first=""
    for ((i = 0; i < size; i++)); do
      n=$(( (pref - MIN + i) % size + MIN ))
      if refused "$n"; then
        [ -n "$first" ] || first="$REASON"
        continue
      fi
      take "$n"
      [ -z "$first" ] || printf 'instance: %s preferred N=%s, taken (%s): assigned N=%s\n' "$ARG" "$pref" "$first" "$n" >&2
      printf 'instance=%s\nhome=%s\n' "$n" "$(stack_home "$n")"
      exit 0
    done
    printf 'full=%s-%s\n' "$MIN" "$MAX"
    printf 'instance: no free N in %s-%s (each one held, stale, busy or unowned): tear down what is done (instance.sh list), or widen INSTANCE_MIN..INSTANCE_MAX\n' "$MIN" "$MAX" >&2
    exit 2
    ;;
  owner)
    valid_n "$ARG"; home=$(stack_home "$ARG")
    owner=$(cat "$home/owner" 2>/dev/null || true)
    printf 'owner=%s\nhome=%s\n' "${owner:-none}" "$home"
    ;;
  claim)
    valid_n "$ARG"; lock
    if refused "$ARG"; then
      printf '%s\n' "$REFUSAL"; printf 'instance: %s\n' "$REASON" >&2; exit 2
    fi
    if [ "$OWN" != 1 ]; then
      other=$(claims_of "$CHECKOUT" | head -n 1)
      if [ -n "$other" ] && [ "$FORCE" != 1 ]; then
        printf 'holds=%s\n' "$other"
        printf 'instance: %s already holds N=%s: release it first, or --force to hold both\n' "$CHECKOUT" "$other" >&2
        exit 2
      fi
      take "$ARG"
    fi
    printf 'claimed=%s\nhome=%s\n' "$ARG" "$(stack_home "$ARG")"
    ;;
  release)
    valid_n "$ARG"; rm -f "$(stack_home "$ARG")/owner"; printf 'released=%s\n' "$ARG"
    ;;
  list)
    for f in "$BASE"/i*/owner; do
      [ -f "$f" ] || continue
      n=${f%/owner}; n=${n##*/i}; owner=$(cat "$f")
      if [ -d "$owner" ]; then state=live; else state=stale; fi
      printf '%s %s %s\n' "$n" "$state" "$owner"
    done
    ;;
  *) usage ;;
esac
