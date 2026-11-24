# stack.d/lib.sh: the helpers ./stack uses (sourced, never run). Generic: nothing here knows
# the app; its names, ports and commands are in ./stack and stack.d/resources.conf.

# Progress goes to stderr; stdout is kept for what a caller reads (the URLs line, a report).
log() { printf '%s\n' "$*" >&2; }
refuse() { log "refused: $*"; exit 2; }

# step NAME COMMAND...: one named step of a verb (the stack contract): "::step::NAME" before
# it, "::step-failed::NAME (exit CODE)" if it fails, and the verb ends with that code. The
# command runs in a subshell with `set -e`: any failing line fails the step.
step() {
  local name=$1 rc
  shift
  printf '::step::%s\n' "$name" >&2
  set +e
  ( set -e; "$@" )
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '::step-failed::%s (exit %s)\n' "$name" "$rc" >&2
    exit "$rc"
  fi
}

# read_conf FILE: each KEY=value line as a shell variable; anything else refuses, so ./stack
# and every caller always read the same values.
read_conf() {
  local file=$1 line n=0
  [ -f "$file" ] || refuse "$file is missing"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case $line in '' | '#'*) continue ;; esac
    [[ $line =~ ^([A-Z][A-Z0-9_]*)=([^[:space:]\"\'\$\`\\]*)$ ]] \
      || refuse "$file line $n is not a plain KEY=value: $line"
    printf -v "${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
  done <"$file"
}

# a directory that exists and is not a symlink
real_dir() { [ -n "$1" ] && [ -d "$1" ] && [ ! -L "$1" ]; }

# the repository's main worktree (where the originals are), from any checkout of it
# The main checkout of the repo <dir> belongs to, from any of its worktrees. A plain repo's
# git common dir is <main>/.git. A submodule's is <superproject>/.git/modules/<member>,
# whose parent is not a checkout (and `git worktree list` names that gitdir, not the
# checkout): its checkout is core.worktree, relative to the gitdir.
main_worktree() {
  local common wt
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  wt=$(git config --file "$common/config" core.worktree 2>/dev/null || true)
  if [ -n "$wt" ]; then (cd "$common" && cd "$wt" && pwd); else dirname "$common"; fi
}

# --- services by PID file: each detached in its own process group (setsid), $RUN/<name>.pid,
# $LOGS/<name>.log, so stopping it reaches every child. ./stack sets RUN and LOGS.

pid_of() { if [ -f "$RUN/$1.pid" ]; then cat "$RUN/$1.pid"; fi; }
alive() { local p; p=$(pid_of "$1"); [[ $p =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; }
listening() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

# launch NAME DIR COMMAND...: start COMMAND detached in DIR (already running: nothing to do)
launch() {
  local name=$1 dir=$2
  shift 2
  if alive "$name"; then log "$name: already running (pid $(pid_of "$name"))"; return 0; fi
  ( cd "$dir" && exec setsid "$@" >>"$LOGS/$name.log" 2>&1 </dev/null ) &
  echo $! >"$RUN/$name.pid"
  log "$name: started (pid $!)"
}

# stop_svc NAME: TERM its process group, up to 30 s, then KILL
stop_svc() {
  local name=$1 pid
  if ! alive "$name"; then rm -f "$RUN/$name.pid"; log "$name: not running"; return 0; fi
  pid=$(pid_of "$name")
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    log "$name: killed (didn't stop in 30 s)"
  else
    log "$name: stopped"
  fi
  rm -f "$RUN/$name.pid"
}

# wait_http NAME URL CODE: up to 60 s for URL to answer CODE; fails if the service exits
wait_http() {
  local name=$1 url=$2 want=$3 code
  for _ in $(seq 120); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$url" 2>/dev/null || true)
    if [ "$code" = "$want" ]; then log "$name: answers ($code) $url"; return 0; fi
    alive "$name" || { log "$name: exited; see $LOGS/$name.log"; return 1; }
    sleep 0.5
  done
  log "$name: no answer on $url within 60 s; see $LOGS/$name.log"
  return 1
}
