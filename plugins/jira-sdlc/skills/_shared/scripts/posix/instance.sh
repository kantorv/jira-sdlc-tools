#!/usr/bin/env bash
# instance.sh — an issue worktree's instance number N, and who holds it.
#
#   instance.sh number <KEY>                    N for an issue key → "instance=<N>"
#   instance.sh claim <N> [--checkout <dir>] [--force]
#                                               record this checkout as N's owner
#   instance.sh owner <N>                       → "owner=<dir|none>" "home=<dir>"
#   instance.sh release <N>                     forget N's owner (after teardown)
#   instance.sh list                            every claimed N: "<N> <state> <owner>"
#
# Run from the checkout (an issue worktree, or the main checkout for list/owner);
# the values come from its stack.d/resources.conf (--conf <file> overrides).
#
# N = cksum(KEY) mod (INSTANCE_MAX - INSTANCE_MIN + 1) + INSTANCE_MIN: the same key
# always gets the same N, with no lookup and no state (onboarding decision D2).
# Two keys can share an N; claim is what refuses the second:
#
#   held=<dir>      another live checkout owns N
#   stale=<dir>     N's owner is gone, but its instance home is still there
#   busy=<what>     no owner recorded, yet something runs as N: containers named
#                   <NAME_PREFIX>-i<N>, or listeners in N's ports (another tool's
#                   instance, e.g. ControlFreak's, which shares the range: D12)
#   unowned=<home>  N's home exists with no owner (made before instance.sh);
#                   --force adopts it
#
# The owner file is <instance home>/owner; the home is the contract's default,
# ~/.local/state/<NAME_PREFIX>/i<N>. The stack's teardown removes the home (logs
# kept), which also releases N.
#
# Exit 0 done; 1 usage; 2 refused (above, or a bad resources.conf). Docs:
# https://kantorv.github.io/jira-sdlc-tools/docs/running-multiple-copies

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_stack.sh"

usage() { sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 1; }

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

valid_n() {
  [[ $1 =~ ^[1-9][0-9]*$ ]] && [ "$1" -ge "$MIN" ] && [ "$1" -le "$MAX" ] \
    || { printf 'instance: N must be an integer %s-%s (got %s)\n' "$MIN" "$MAX" "$1" >&2; exit 2; }
}

case $VERB in
  number)
    [[ $ARG =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || { printf 'instance: not an issue key: %s\n' "$ARG" >&2; exit 1; }
    sum=$(printf '%s' "$ARG" | cksum | awk '{print $1}')
    printf 'instance=%s\n' $((sum % (MAX - MIN + 1) + MIN))
    ;;
  owner)
    valid_n "$ARG"; home=$(stack_home "$ARG")
    owner=$(cat "$home/owner" 2>/dev/null || true)
    printf 'owner=%s\nhome=%s\n' "${owner:-none}" "$home"
    ;;
  claim)
    valid_n "$ARG"; home=$(stack_home "$ARG")
    owner=$(cat "$home/owner" 2>/dev/null || true)
    if [ -n "$owner" ]; then
      if [ "$owner" = "$CHECKOUT" ]; then
        printf 'claimed=%s\nhome=%s\n' "$ARG" "$home"; exit 0
      elif [ -d "$owner" ]; then
        printf 'held=%s\n' "$owner"; printf 'instance: N=%s is held by %s\n' "$ARG" "$owner" >&2; exit 2
      else
        printf 'stale=%s\n' "$owner"
        printf 'instance: N=%s belongs to %s, which is gone: ./stack teardown --instance %s, then claim again\n' "$ARG" "$owner" "$ARG" >&2
        exit 2
      fi
    fi
    if [ "$FORCE" != 1 ]; then
      busy=$(docker_named "${CONF[NAME_PREFIX]}-i$ARG" | tr '\n' ',' | sed 's/,$//')
      read -r first last < <(stack_ports "$ARG") || true
      if [ -n "${first:-}" ]; then
        p=$(ports_busy "$first" "$last"); [ -z "$p" ] || busy="${busy:+$busy,}ports:$p"
      fi
      if [ -n "$busy" ]; then
        printf 'busy=%s\n' "$busy"
        printf 'instance: something already runs as N=%s (%s): another tool'"'"'s instance? stop it, or --force\n' "$ARG" "$busy" >&2
        exit 2
      fi
      if [ -d "$home" ] && [ -n "$(ls -A "$home" 2>/dev/null | grep -v '^logs$')" ]; then
        printf 'unowned=%s\n' "$home"
        printf 'instance: %s exists with no owner: tear it down, or --force to adopt it\n' "$home" >&2
        exit 2
      fi
    fi
    mkdir -p "$home" && chmod 700 "$home" && printf '%s\n' "$CHECKOUT" > "$home/owner"
    printf 'claimed=%s\nhome=%s\n' "$ARG" "$home"
    ;;
  release)
    valid_n "$ARG"; rm -f "$(stack_home "$ARG")/owner"; printf 'released=%s\n' "$ARG"
    ;;
  list)
    base="$HOME/.local/state/${CONF[NAME_PREFIX]}"
    for f in "$base"/i*/owner; do
      [ -f "$f" ] || continue
      n=${f%/owner}; n=${n##*/i}; owner=$(cat "$f")
      if [ -d "$owner" ]; then state=live; else state=stale; fi
      printf '%s %s %s\n' "$n" "$state" "$owner"
    done
    ;;
  *) usage ;;
esac
