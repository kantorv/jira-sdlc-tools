#!/usr/bin/env bash
# stack-resources.sh — propose or check a stack's host resources, against the host
# and every other project's stack.d/resources.conf.
#
#   stack-resources.sh propose --prefix <name> [--ports-per-instance K] [--instances M]
#                              [--subnet] [--other <conf>]...
#       → KEY=value lines for a new resources.conf: NAME_PREFIX, INSTANCE_MIN/MAX,
#         PORT_BASE, PORT_COUNT, PORTS_PER_INSTANCE, and SUBNET with --subnet
#   stack-resources.sh check [<conf>] [--other <conf>]...
#       → a markdown table (check | status | detail); exit 1 on any FAIL
#
# Other projects: each --other <conf>, plus every path in $JST_STACK_CONFS
# (colon-separated; the jira-sdlc web app sets it from its registry). A port
# block is free when it overlaps no other project's block, stays below the
# host's ephemeral range, and nothing listens in it; a subnet is free when no
# other project and no Docker network uses it.
#
# Exit 0 done / all OK; 1 a FAIL (check) or nothing free (propose); 2 usage or a
# bad resources.conf. Docs: https://kantorv.github.io/jira-sdlc-tools/docs/running-multiple-copies

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_stack.sh"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

VERB=${1:-}; [ -n "$VERB" ] || usage; shift
PREFIX="" PER=10 COUNT_INST=100 WANT_SUBNET=0 TARGET="" OTHERS=()
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) PREFIX=${2:-}; shift 2 ;;
    --ports-per-instance) PER=${2:-}; shift 2 ;;
    --instances) COUNT_INST=${2:-}; shift 2 ;;
    --subnet) WANT_SUBNET=1; shift ;;
    --other) OTHERS+=("${2:-}"); shift 2 ;;
    -*) usage ;;
    *) TARGET=$1; shift ;;
  esac
done
IFS=: read -ra env_others <<< "${JST_STACK_CONFS:-}"
for o in "${env_others[@]}"; do [ -n "$o" ] && OTHERS+=("$o"); done

ephemeral_low=$(awk '{print $1}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null || echo 32768)

# Other projects' blocks ("first last prefix") and subnets ("a.b prefix").
other_blocks=() other_subnets=() other_prefixes=()
for o in "${OTHERS[@]}"; do
  [ "$(readlink -f "$o")" = "$(readlink -f "${TARGET:-/nonexistent}")" ] && continue
  stack_conf "$o" 2>/dev/null || continue
  other_prefixes+=("${CONF[NAME_PREFIX]:-?}")
  if [ -n "${CONF[PORT_BASE]:-}" ] && [ -n "${CONF[PORT_COUNT]:-}" ]; then
    other_blocks+=("${CONF[PORT_BASE]} $((CONF[PORT_BASE] + CONF[PORT_COUNT] - 1)) ${CONF[NAME_PREFIX]:-?}")
  fi
  [ -n "${CONF[SUBNET]:-}" ] && other_subnets+=("$(cut -d. -f1-2 <<< "${CONF[SUBNET]}") ${CONF[NAME_PREFIX]:-?}")
done
docker_subnets=$(command -v docker >/dev/null 2>&1 && docker network ls -q 2>/dev/null \
  | xargs -r docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null \
  | tr ' ' '\n' | grep -E '^[0-9]' | cut -d. -f1-2 | sort -u)

block_clash() {  # <first> <last> [own prefix] → what it overlaps, or nothing
  local a=$1 b=$2 own=${3:-} x
  for x in "${other_blocks[@]}"; do
    read -r f l p <<< "$x"
    [ "$p" = "$own" ] && continue
    [ "$a" -le "$l" ] && [ "$b" -ge "$f" ] && { printf '%s (%s-%s)' "$p" "$f" "$l"; return; }
  done
}
subnet_clash() {  # <a.b> [own prefix] → what uses it, or nothing
  local ab=$1 own=${2:-} x
  for x in "${other_subnets[@]}"; do read -r s p <<< "$x"; [ "$s" = "$ab" ] && [ "$p" != "$own" ] && { printf '%s' "$p"; return; }; done
}

case $VERB in
  propose)
    [[ $PREFIX =~ ^[a-z][a-z0-9-]*$ ]] || { echo "stack-resources: --prefix must be lower case (got '$PREFIX')" >&2; exit 2; }
    for x in "${other_prefixes[@]}"; do
      [ "$x" = "$PREFIX" ] && { echo "stack-resources: NAME_PREFIX $PREFIX is another project's" >&2; exit 1; }
    done
    size=$((PER * COUNT_INST)); size=$(( (size + 999) / 1000 * 1000 ))
    base=""
    for ((b = 20000; b + size - 1 < ephemeral_low; b += 1000)); do
      [ -z "$(block_clash "$b" $((b + size - 1)))" ] && [ -z "$(ports_busy "$b" $((b + size - 1)))" ] && { base=$b; break; }
    done
    [ -n "$base" ] || { echo "stack-resources: no free block of $size ports below $ephemeral_low" >&2; exit 1; }
    printf 'NAME_PREFIX=%s\nINSTANCE_MIN=1\nINSTANCE_MAX=%s\nPORT_BASE=%s\nPORT_COUNT=%s\nPORTS_PER_INSTANCE=%s\n' \
      "$PREFIX" "$COUNT_INST" "$base" "$size" "$PER"
    if [ "$WANT_SUBNET" = 1 ]; then
      for ((o = 200; o <= 254; o++)); do
        ab="10.$o"
        [ -z "$(subnet_clash "$ab")" ] && ! grep -qx "$ab" <<< "$docker_subnets" && { printf 'SUBNET=%s.0.0/16\n' "$ab"; exit 0; }
      done
      echo "stack-resources: no free 10.x.0.0/16 subnet" >&2; exit 1
    fi
    ;;
  check)
    TARGET=${TARGET:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/stack.d/resources.conf}
    stack_conf "$TARGET" || exit 2
    fail=0
    row() { printf '| %s | %s | %s |\n' "$1" "$2" "$3"; [ "$2" = FAIL ] && fail=1; }
    printf '| check | status | detail |\n| -- | -- | -- |\n'
    miss=""; for k in NAME_PREFIX INSTANCE_MIN INSTANCE_MAX; do [ -n "${CONF[$k]:-}" ] || miss+="$k "; done
    if [ -n "$miss" ]; then row keys FAIL "missing: $miss"; else row keys OK "NAME_PREFIX=${CONF[NAME_PREFIX]}, instances ${CONF[INSTANCE_MIN]}-${CONF[INSTANCE_MAX]}"; fi
    own=${CONF[NAME_PREFIX]:-}
    for x in "${other_prefixes[@]}"; do [ "$x" = "$own" ] && row name_prefix FAIL "$own is also another project's"; done
    if [ -n "${CONF[PORT_BASE]:-}" ]; then
      first=${CONF[PORT_BASE]}
      last=$((first + ${CONF[PORT_COUNT]:-$(( (CONF[INSTANCE_MAX] - CONF[INSTANCE_MIN] + 1) * ${CONF[PORTS_PER_INSTANCE]:-1} ))} - 1))
      need=$(( (CONF[INSTANCE_MAX] - CONF[INSTANCE_MIN] + 1) * ${CONF[PORTS_PER_INSTANCE]:-1} ))
      if [ "$need" -gt $((last - first + 1)) ]; then row port_block FAIL "$need ports needed, PORT_COUNT gives $((last - first + 1))"
      elif [ "$last" -ge "$ephemeral_low" ]; then row port_block FAIL "$first-$last reaches the ephemeral range ($ephemeral_low+)"
      else c=$(block_clash "$first" "$last" "$own"); if [ -n "$c" ]; then row port_block FAIL "$first-$last overlaps $c"; else row port_block OK "$first-$last"; fi; fi
    else
      row port_block INFO "no port block (instances on a subnet, or none)"
    fi
    if [ -n "${CONF[SUBNET]:-}" ]; then
      ab=$(cut -d. -f1-2 <<< "${CONF[SUBNET]}")
      c=$(subnet_clash "$ab" "$own")
      if [ -n "$c" ]; then row subnet FAIL "${CONF[SUBNET]} is also $c's"; else row subnet OK "${CONF[SUBNET]}"; fi
    fi
    row others INFO "${#other_prefixes[@]} other project(s) compared${other_prefixes[*]:+: ${other_prefixes[*]}}"
    exit "$fail"
    ;;
  *) usage ;;
esac
