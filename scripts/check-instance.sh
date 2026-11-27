#!/usr/bin/env bash
# check-instance.sh — regression checks for instance.sh's numbers and claims (JSW-31):
# a checkout's N is its claim, never the issue key's hash.
#
#   1. Two keys with the same hash N (JSW-27 and JSW-29, both 120 in 1-250) get
#      different Ns from assign; a key nothing collides with keeps its hash N.
#   2. assign is idempotent, and finds a claim made before assign (claim <N>).
#   3. lookup reads only the checkout's own claim; none → instance=none.
#   4. Concurrent assigns (many checkouts, one key) get distinct Ns.
#   5. A full range refuses (full=, exit 2), and leaves no claim behind.
#   6. claim refuses a second N for a checkout (holds=), and lookup/assign refuse
#      a checkout holding two (claims=). A dead holder's lock is broken; a
#      half-made home (no owner) is claimable.
#   7. The writing guide's .jst/bootstrap.sh and teardown.sh, with a fake ./stack:
#      without JST_INSTANCE they act on the worktree's claim only, and refuse
#      (touching nothing) when it has none; JST_INSTANCE=<N> teardown.sh refuses an
#      N the worktree doesn't own.
#   8. A stale lock: a dead holder's lock, broken by 16 concurrent assigns, still gives
#      16 distinct Ns, trial after trial (only one waiter breaks it); a lock with no
#      pid is broken after 10 s, not before; a run never removes a lock not its own.
#
# Runs against a scratch HOME (the claims live under ~/.local/state/<NAME_PREFIX>/),
# so it never touches real claims; a NAME_PREFIX no Docker object or listener uses,
# and no ports in the scratch conf, so the busy= check finds nothing.
#
# Usage:  bash scripts/check-instance.sh
# Exit 0 — every check passed. Exit 1 — at least one failed, named on stdout.

set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
INST="$ROOT/plugins/jira-sdlc/skills/_shared/scripts/posix/instance.sh"
GUIDE="$ROOT/plugins/jira-sdlc/skills/_shared/stack/writing-guide.md"

LAB=$(cd "$(mktemp -d)" && pwd -P)
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
export HOME="$LAB/home"; mkdir -p "$HOME"
PREFIX=jstcheck$$
STATE="$HOME/.local/state/$PREFIX"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (want '$3', got '$2')"; fi; }

conf() { # conf <file> <min> <max>
  printf 'NAME_PREFIX=%s\nINSTANCE_MIN=%s\nINSTANCE_MAX=%s\n' "$PREFIX" "$2" "$3" > "$1"
}
CONF="$LAB/resources.conf"; conf "$CONF" 1 250
co() { mkdir -p "$LAB/co/$1"; printf '%s\n' "$LAB/co/$1"; }   # a checkout (a live directory)
inst() { (cd "$LAB" && bash "$INST" "$@" --conf "$CONF"); }
val() { sed -n "s/^$1=//p"; }                                  # val <key> < output

echo "== 1. colliding keys get different Ns =="
is "JSW-27's preferred N" "$(inst number JSW-27 | val instance)" 120
is "JSW-29's preferred N" "$(inst number JSW-29 | val instance)" 120
A=$(co a) B=$(co b) C=$(co c)
NA=$(inst assign JSW-27 --checkout "$A" | val instance)
NB=$(inst assign JSW-29 --checkout "$B" 2>"$LAB/err" | val instance)
is "the first gets its preferred N" "$NA" 120
if [ -n "$NB" ] && [ "$NB" != "$NA" ]; then ok "the second gets another N ($NB)"; else no "the second got '$NB'"; fi
if grep -q 'preferred N=120, taken' "$LAB/err"; then ok "assign says it moved"; else no "no move note: $(cat "$LAB/err")"; fi
KEEP=$(inst number JSW-31 | val instance)
is "a key nothing collides with keeps its hash N" "$(inst assign JSW-31 --checkout "$C" | val instance)" "$KEEP"
is "assign claims for the checkout" "$(cat "$STATE/i$NB/owner")" "$B"

echo "== 2. idempotent; an older claim is kept =="
is "assign again: same N" "$(inst assign JSW-27 --checkout "$A" | val instance)" "$NA"
is "assign again (moved one): same N" "$(inst assign JSW-29 --checkout "$B" | val instance)" "$NB"
D=$(co d); inst claim 7 --checkout "$D" >/dev/null
is "assign keeps a claim made by hand" "$(inst assign JSW-29 --checkout "$D" | val instance)" 7
is "assign's home" "$(inst assign JSW-27 --checkout "$A" | val home)" "$STATE/i$NA"

echo "== 3. lookup =="
is "lookup A" "$(inst lookup --checkout "$A" | val instance)" "$NA"
is "lookup B" "$(inst lookup --checkout "$B" | val instance)" "$NB"
is "lookup B's home" "$(inst lookup --checkout "$B" | val home)" "$STATE/i$NB"
E=$(co e)
is "lookup of an unclaimed checkout" "$(inst lookup --checkout "$E" | val instance)" none
(cd "$A" && bash "$INST" lookup --conf "$CONF" | val instance) > "$LAB/out"
is "lookup from inside the checkout" "$(cat "$LAB/out")" "$NA"
inst release "$NB" >/dev/null
is "lookup after release" "$(inst lookup --checkout "$B" | val instance)" none

echo "== 4. concurrent assigns =="
for i in $(seq 1 12); do co "p$i" >/dev/null; done
for i in $(seq 1 12); do (inst assign JSW-27 --checkout "$LAB/co/p$i" 2>/dev/null | val instance > "$LAB/p$i.n") & done
wait
got=$(cat "$LAB"/p*.n | sort -n); uniq=$(printf '%s\n' "$got" | sort -un | grep -c .)
is "12 concurrent assigns: 12 Ns" "$(printf '%s\n' "$got" | grep -c .)" 12
is "all distinct" "$uniq" 12
if ls -A "$STATE" | grep -q '^\.owner\.'; then no "a temporary owner file was left"; else ok "no temporary owner file left"; fi
[ ! -e "$STATE/.lock" ] && ok "the lock is released" || no "the lock was left"

echo "== 5. a full range =="
SMALL="$LAB/small.conf"; conf "$SMALL" 1 2
small() { (cd "$LAB" && bash "$INST" "$@" --conf "$SMALL"); }
rm -rf "$STATE"
F1=$(co f1) F2=$(co f2) F3=$(co f3)
small assign JSW-1 --checkout "$F1" >/dev/null; small assign JSW-2 --checkout "$F2" >/dev/null
out=$(small assign JSW-3 --checkout "$F3" 2>"$LAB/err"); rc=$?
is "a third assign in 1-2 exits 2" "$rc" 2
is "it says full=" "$(printf '%s\n' "$out" | val full)" 1-2
if grep -q 'no free N in 1-2' "$LAB/err"; then ok "with a reason"; else no "reason: $(cat "$LAB/err")"; fi
is "and claims nothing" "$(small lookup --checkout "$F3" | val instance)" none

echo "== 6. refusals, the lock, half-made homes =="
rm -rf "$STATE"
G=$(co g); H=$(co h)
inst claim 10 --checkout "$G" >/dev/null
out=$(inst claim 11 --checkout "$G" 2>/dev/null); rc=$?
is "claim of a second N refuses" "$rc" 2
is "with holds=" "$(printf '%s\n' "$out" | val holds)" 10
out=$(inst claim 10 --checkout "$H" 2>/dev/null); rc=$?
is "claim of another's N refuses" "$rc" 2
is "with held=" "$(printf '%s\n' "$out" | val held)" "$G"
inst claim 11 --checkout "$G" --force >/dev/null
out=$(inst lookup --checkout "$G" 2>/dev/null); rc=$?
is "lookup of two claims exits 2" "$rc" 2
is "with claims=" "$(printf '%s\n' "$out" | val claims)" 10,11
out=$(inst assign JSW-27 --checkout "$G" 2>/dev/null); rc=$?
is "assign with two claims exits 2" "$rc" 2
rm -rf "$STATE"
mkdir -p "$STATE/.lock"; (exit 0) & dead=$!; wait "$dead"; echo "$dead" > "$STATE/.lock/pid"
is "a dead holder's lock is broken" "$(timeout 20 bash -c "cd '$LAB' && bash '$INST' assign JSW-27 --checkout '$H' --conf '$CONF'" | val instance)" 120
mkdir -p "$STATE/i121/logs"
I=$(co i)
is "a home with only logs, no owner, is claimable" "$(inst assign JSW-29 --checkout "$I" | val instance)" 121
mkdir -p "$STATE/i122"; echo x > "$STATE/i122/env"
out=$(inst claim 122 --checkout "$(co j)" 2>/dev/null); rc=$?
is "a home with more than logs, no owner, refuses" "$rc:$(printf '%s\n' "$out" | sed 's/=.*//')" 2:unowned

echo "== 7. the writing guide's hooks =="
rm -rf "$STATE"
hook() { # hook <bootstrap|teardown> — the guide's block for .jst/<name>.sh
  awk -v want="# .jst/$1.sh:" '/^```bash$/ {inb=1; buf=""; next} /^```$/ && inb {if (hit) {printf "%s", buf; exit} inb=0; next}
    inb {buf = buf $0 "\n"; if (index($0, want) == 1) hit=1}' "$GUIDE"
}
mkwt() { # mkwt <name> — a worktree-shaped checkout with the guide's hooks and a fake ./stack
  local w="$LAB/wt/$1"; mkdir -p "$w/.jst" "$w/stack.d"
  cp "$CONF" "$w/stack.d/resources.conf"
  hook bootstrap > "$w/.jst/bootstrap.sh"; hook teardown > "$w/.jst/teardown.sh"
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/stack.calls"\n' "$w" > "$w/stack"
  chmod +x "$w/stack" "$w/.jst/"*.sh; printf '%s\n' "$w"
}
W1=$(mkwt w1) W2=$(mkwt w2) W3=$(mkwt w3)
if [ -s "$W1/.jst/teardown.sh" ] && [ -s "$W1/.jst/bootstrap.sh" ]; then ok "both hooks found in the guide"; else no "a hook is missing from $GUIDE"; fi
bash -n "$W1/.jst/teardown.sh" && bash -n "$W1/.jst/bootstrap.sh" && ok "both parse" || no "a hook doesn't parse"
grep -q cksum "$W1/.jst/teardown.sh" "$W1/.jst/bootstrap.sh" && no "a hook still hashes the key" || ok "no hook hashes the key"
N1=$(inst assign JSW-27 --checkout "$W1" | val instance); N2=$(inst assign JSW-29 --checkout "$W2" | val instance)
JST_ISSUE_KEY=JSW-29 bash "$W2/.jst/teardown.sh" 2>/dev/null
is "teardown.sh acts on its own claim" "$(cat "$W2/stack.calls" 2>/dev/null | tr '\n' ';')" "stop --instance $N2;teardown --instance $N2;"
[ ! -e "$W1/stack.calls" ] && ok "and not on the other worktree's" || no "it ran in the other worktree"
is "teardown.sh releases its claim" "$(inst lookup --checkout "$W2" | val instance)" none
is "and keeps the other's" "$(inst lookup --checkout "$W1" | val instance)" "$N1"
rm -f "$W2/stack.calls"
JST_INSTANCE=$N1 bash "$W2/.jst/teardown.sh" 2>"$LAB/err"; rc=$?
is "JST_INSTANCE=<another worktree's N> teardown.sh refuses" "$rc" 2
[ ! -e "$W2/stack.calls" ] && ok "touching nothing" || no "it ran ./stack: $(cat "$W2/stack.calls")"
grep -q "owner: $W1" "$LAB/err" && ok "naming the owner" || no "reason: $(cat "$LAB/err")"
is "and never releases another worktree's claim" "$(inst lookup --checkout "$W1" | val instance)" "$N1"
JST_ISSUE_KEY=JSW-27 bash "$W1/.jst/bootstrap.sh" 2>/dev/null
is "bootstrap.sh starts its own claim" "$(cat "$W1/stack.calls" | tr '\n' ';')" "start --instance $N1;"
JST_ISSUE_KEY=JSW-31 bash "$W3/.jst/teardown.sh" 2>"$LAB/err"; rc=$?
is "teardown.sh without a claim refuses" "$rc" 2
[ ! -e "$W3/stack.calls" ] && ok "touching nothing" || no "it ran ./stack: $(cat "$W3/stack.calls")"
grep -q 'no instance claimed' "$LAB/err" && ok "with a reason" || no "reason: $(cat "$LAB/err")"
JST_ISSUE_KEY=JSW-31 bash "$W3/.jst/bootstrap.sh" 2>/dev/null; rc=$?
is "bootstrap.sh without a claim refuses" "$rc" 2
JST_INSTANCE=5 bash "$W3/.jst/teardown.sh" 2>/dev/null; rc=$?
is "JST_INSTANCE=<an unclaimed N> teardown.sh refuses" "$rc" 2
[ ! -e "$W3/stack.calls" ] && ok "touching nothing" || no "it ran ./stack: $(cat "$W3/stack.calls")"
rm -f "$W1/stack.calls"
JST_INSTANCE=$N1 bash "$W1/.jst/teardown.sh"
is "JST_INSTANCE=<its own N> tears it down" "$(cat "$W1/stack.calls" | tr '\n' ';')" "stop --instance $N1;teardown --instance $N1;"
is "and releases it" "$(inst lookup --checkout "$W1" | val instance)" none

echo "== 8. a stale lock: one breaker, never two holders =="
# A dead holder's lock and 16 concurrent assigns, many times over: two waiters that
# both see the dead pid must not both break the lock (the second breaking the first's
# fresh one), or two checkouts get one N. INSTANCE_TRIALS sets the count.
TRIALS=${INSTANCE_TRIALS:-40}; bad=0; why=""
for i in $(seq 1 16); do co "s$i" >/dev/null; done
for t in $(seq 1 "$TRIALS"); do
  rm -rf "$STATE"; mkdir -p "$STATE/.lock"
  (exit 0) & dead=$!; wait "$dead"; echo "$dead" > "$STATE/.lock/pid"
  for i in $(seq 1 16); do (inst assign JSW-27 --checkout "$LAB/co/s$i" 2>/dev/null | val instance > "$LAB/s$i.n") & done
  wait
  n=$(cat "$LAB"/s*.n | grep -c .); u=$(cat "$LAB"/s*.n | sort -un | grep -c .)
  if [ "$n" != 16 ] || [ "$u" != 16 ]; then bad=$((bad + 1)); why="trial $t: $n Ns, $u distinct"; fi
done
is "$TRIALS trials of 16 assigns past a dead pid: every N distinct" "$bad${why:+ ($why)}" 0
[ ! -e "$STATE/.lock" ] && [ ! -e "$STATE/.lock.break" ] && ok "both locks released" || no "a lock was left: $(ls -A "$STATE")"

rm -rf "$STATE"; mkdir -p "$STATE/.lock"; touch -t 202001010000 "$STATE/.lock"
is "a lock with no pid for 10 s is broken" "$(timeout 20 bash -c "cd '$LAB' && bash '$INST' assign JSW-27 --checkout '$H' --conf '$CONF'" | val instance)" 120
rm -rf "$STATE"; mkdir -p "$STATE/.lock"
timeout 2 bash -c "cd '$LAB' && bash '$INST' assign JSW-27 --checkout '$H' --conf '$CONF'" >/dev/null 2>&1
[ -d "$STATE/.lock" ] && [ "$(inst lookup --checkout "$H" | val instance)" = none ] \
  && ok "a fresh one with no pid (a holder about to write it) is waited on" || no "a fresh pid-less lock was broken"

# A run whose lock was taken from it must leave the new holder's lock alone on exit:
# a docker that sleeps holds the run inside the lock while the lock changes hands.
rm -rf "$STATE"; mkdir -p "$LAB/bin"; printf '#!/bin/sh\nsleep 2\n' > "$LAB/bin/docker"; chmod +x "$LAB/bin/docker"
(PATH="$LAB/bin:$PATH" inst assign JSW-27 --checkout "$H" >/dev/null 2>&1) & run=$!
for _ in $(seq 1 50); do [ -s "$STATE/.lock/pid" ] && break; sleep 0.1; done
sleep 30 & other=$!
mv "$STATE/.lock" "$STATE/.lock.taken"; mkdir "$STATE/.lock"; echo "$other" > "$STATE/.lock/pid"
wait "$run"
is "on exit a run leaves a lock that isn't its own" "$(cat "$STATE/.lock/pid" 2>/dev/null)" "$other"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
