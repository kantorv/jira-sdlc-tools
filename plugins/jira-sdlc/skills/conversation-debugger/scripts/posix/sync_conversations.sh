#!/usr/bin/env bash
# sync_conversations.sh <ISSUE-KEY> [--title "<summary>"] [--created "<iso8601>"]
#
# Find the Claude Code conversation transcripts (.jsonl under ~/.claude/projects)
# that belong to a Jira issue, print them grouped, and end with a machine-readable
# list of the files to attach.
#
# The definitive set splits by provenance, because a session's transcript lives
# in a project folder named after that session's cwd:
#   • WORKTREE (certain, take ALL) — the executor and reviewer run inside
#     <WORKTREES_DIR>/worktree-<KEY>; every session in that folder is this
#     issue's. The folder persists in ~/.claude/projects even after the worktree
#     itself is removed.
#   • MAIN checkout (take exactly ONE — the session that CREATED the issue) — the
#     assigner runs here, interleaved with unrelated sessions. To pin the one
#     creating session out of "any session that ever mentioned <KEY>", layer three
#     signals, strongest last:
#       1. it invoked /jira-sdlc:jira-task-assigner  (structured <command-name>,
#          immune to the key/title merely being discussed in prose)
#       2. the issue TITLE appears in it  (the assigner was invoked with it)
#       3. the issue's Jira `created` instant falls inside the session's
#          first..last message-timestamp window  (the decisive tie-breaker: only
#          the session that was live at creation time actually created it)
#     --title / --created come from the caller's Jira fetch; without them the
#     script still runs but can only offer candidates, not pick the one.
#
# The two ~/.claude/projects transcript folders are pinned by config, not inferred
# from git / the cwd encoding: CONVERSATIONS_MAINREPO_PATH is the main checkout's
# folder (used as-is), and CONVERSATIONS_WORKTREES_PREFFIX is the prefix of the
# worktrees' folders — this issue's is <prefix>worktree-<KEY>. Both come from
# jira-sdlc-tools(.local).env and are validated below. Pinning them in config (vs.
# letting this script / the agent compute arbitrary paths) is deliberate: it scopes
# this read-only builtin to the configured trees and nothing else under
# ~/.claude/projects.
#
# Read-only: never writes, transitions, or uploads. Exit 1 only on a usage /
# environment error.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEY="" ; TITLE="" ; CREATED="" ; ATTACH="" ; DRYRUN=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --title)    TITLE="${2:-}"; shift 2 ;;
    --title=*)  TITLE="${1#--title=}"; shift ;;
    --created)  CREATED="${2:-}"; shift 2 ;;
    --created=*) CREATED="${1#--created=}"; shift ;;
    --attach)   ATTACH=1; shift ;;
    --dry-run)  DRYRUN=1; shift ;;
    *)          [ -z "$KEY" ] && KEY="$1"; shift ;;
  esac
done
case "$KEY" in
  [A-Za-z]*-[0-9]*) : ;;
  *) echo "sync_conversations: need an issue key, e.g. sync_conversations.sh JST-93 [--attach] [--dry-run] [--title ...] [--created ...] (got '${KEY:-<none>}')" >&2; exit 1 ;;
esac

# Resolve the two transcript folders from config. The env-file parser (cfg) is the
# same NAME = value grep / local-overrides-team precedence as statuscheck.sh and
# get_assignee_email.sh — keep them in sync. Reading these from the committed/local
# env files (not the process environment) is what makes the scoping trustworthy:
# the agent can't widen it by exporting a variable.
CFG_DIR=$(git rev-parse --show-toplevel 2>/dev/null || true)
CFG_DIR="${CFG_DIR:-$PWD}"
cfg() {
  local f v
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$CFG_DIR/$f" ] || continue
    v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$CFG_DIR/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}

MAIN_FOLDER=$(cfg CONVERSATIONS_MAINREPO_PATH || true)
WT_PREFIX=$(cfg CONVERSATIONS_WORKTREES_PREFFIX || true)
if [ -z "$MAIN_FOLDER" ] || [ ! -d "$MAIN_FOLDER" ]; then
  echo "sync_conversations: CONVERSATIONS_MAINREPO_PATH must name an existing directory (the main checkout's ~/.claude/projects transcript folder); set it in $CFG_DIR/jira-sdlc-tools.local.env. Got '${MAIN_FOLDER:-<unset>}'" >&2
  exit 1; fi
if [ -z "$WT_PREFIX" ]; then
  echo "sync_conversations: CONVERSATIONS_WORKTREES_PREFFIX is unset — set it in $CFG_DIR/jira-sdlc-tools.local.env (the ~/.claude/projects prefix of the worktrees' transcript folders; this issue's is <prefix>worktree-<KEY>)." >&2
  exit 1; fi
# This issue's worktree folder is the prefix + worktree-<KEY>. A missing folder
# means the issue never had a worktree (nothing to sync) — stop rather than guess.
WT_FOLDER="${WT_PREFIX}worktree-${KEY}"
if [ ! -d "$WT_FOLDER" ]; then
  echo "sync_conversations: no worktree transcript folder for $KEY at '$WT_FOLDER' (CONVERSATIONS_WORKTREES_PREFFIX + worktree-$KEY) — if $KEY never had a worktree there is nothing to sync." >&2
  exit 1; fi

# The two signals that pin the creating session (title + creation date) come
# from Jira. Self-fetch them so the caller doesn't have to — acli is already
# logged in as the executor by the time the skill runs this. --title/--created
# stay as overrides that skip the fetch, keeping the detector runnable offline.
if { [ -z "$TITLE" ] || [ -z "$CREATED" ]; } && command -v acli >/dev/null 2>&1; then
  _meta=$(acli jira workitem view "$KEY" --json --fields 'summary,created' 2>/dev/null || true)
  if [ -n "$_meta" ]; then
    _pick() { printf '%s' "$_meta" | python3 -c 'import sys,json;print((((json.load(sys.stdin) or {}).get("fields")) or {}).get("'"$1"'") or "")' 2>/dev/null || true; }
    [ -z "$TITLE" ]   && TITLE=$(_pick summary)
    [ -z "$CREATED" ] && CREATED=$(_pick created)
  fi
fi

# Emit the candidate files, tagged W (worktree, all) or M (main assigner-command
# session that also mentions the key). Selection among M happens in python.
# Both folders were validated as existing directories above.
gather() {
  for f in "$WT_FOLDER"/*.jsonl; do [ -f "$f" ] && printf 'W\t%s\n' "$f"; done
  grep -rlE 'command-name>/?jira-sdlc:jira-task-assigner' "$MAIN_FOLDER"/*.jsonl 2>/dev/null \
    | while IFS= read -r f; do grep -qwF "$KEY" "$f" && printf 'M\t%s\n' "$f"; done
}

OUT="$(gather | SC_KEY="$KEY" SC_TITLE="$TITLE" SC_CREATED="$CREATED" \
         SC_WT="${WT_FOLDER:-}" SC_MAIN="$MAIN_FOLDER" python3 -c '
import sys, os, re, json, time
from datetime import datetime

KEY     = os.environ.get("SC_KEY", "")
TITLE   = os.environ.get("SC_TITLE", "").strip()
CREATED = os.environ.get("SC_CREATED", "").strip()
TS_RE   = re.compile(r"\"timestamp\":\"([^\"]+)\"")

def to_epoch(s):
    """Parse both transcript (…Z) and Jira (…+0300) ISO forms to epoch seconds."""
    if not s: return None
    s = s.strip().replace("Z", "+00:00")
    m = re.search(r"([+-]\d{2})(\d{2})$", s)          # +0300 -> +03:00
    if m: s = s[:m.start()] + m.group(1) + ":" + m.group(2)
    try: return datetime.fromisoformat(s).timestamp()
    except Exception: return None

CREATED_E = to_epoch(CREATED)

def clean(text):
    m = re.search(r"<command-name>\s*/?([^<]+?)\s*</command-name>", text)
    if m: return m.group(1)[:52]
    m = re.search(r"running (/[A-Za-z0-9:_-]+)", text)
    if m: return m.group(1)[:52]
    return " ".join(re.sub(r"<[^>]+>", " ", text).split())[:52]

def summary(path):
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                try: o = json.loads(line)
                except Exception: continue
                if o.get("type") != "user": continue
                c = (o.get("message") or {}).get("content")
                t = c if isinstance(c, str) else None
                if isinstance(c, list):
                    for b in c:
                        if isinstance(b, str): t = b; break
                        if isinstance(b, dict) and b.get("type") == "text": t = b.get("text"); break
                if t and clean(t): return clean(t)
    except OSError: return "?"
    return "(no user message)"

def scan(path):
    """Return (has_title, first_epoch, last_epoch) for a main-folder candidate."""
    has_title, first, last = False, None, None
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                if TITLE and not has_title and TITLE in line: has_title = True
                m = TS_RE.search(line)
                if m:
                    e = to_epoch(m.group(1))
                    if e is not None:
                        if first is None: first = e
                        last = e
    except OSError: pass
    return has_title, first, last

wfiles, mfiles = [], []
for line in sys.stdin:
    line = line.rstrip("\n")
    if "\t" not in line: continue
    tag, path = line.split("\t", 1)
    (wfiles if tag == "W" else mfiles).append(path)

# --- pick the single creating session out of the main-checkout candidates -----
scored = []
for p in mfiles:
    ht, first, last = scan(p)
    brk = (first is not None and last is not None and CREATED_E is not None
           and first <= CREATED_E <= last)
    scored.append({"path": p, "title": ht, "bracket": brk, "first": first, "last": last})

tb = [s for s in scored if s["title"] and s["bracket"]]
br = [s for s in scored if s["bracket"]]
ti = [s for s in scored if s["title"]]
selected, reason = None, ""
if len(tb) == 1:      selected, reason = tb[0], "title + creation-time match"
elif len(br) == 1:    selected, reason = br[0], "creation-time bracket"
elif len(ti) == 1:    selected, reason = ti[0], "title match"
elif len(scored) == 1: selected, reason = scored[0], "only assigner session found"
elif tb:              selected, reason = tb[0], "title + creation-time match (multiple; took first)"

def fmt(path):
    try: st = os.stat(path)
    except OSError: return None
    dt = time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime))
    return f"  * {dt}  {round(st.st_size/1024):>5} KB  {summary(path)}\n    {path}", st.st_mtime

attach = []

if wfiles:
    print(f"\n### Worktree (worktree-{KEY}) — all sessions, attached")
    for line, _ in sorted((r for r in (fmt(p) for p in wfiles) if r), key=lambda r: r[1], reverse=True):
        print(line)
    attach += wfiles

print(f"\n### Main checkout — the assigner session that created {KEY}")
if selected:
    row = fmt(selected["path"])
    if row: print(row[0] + f"    ↳ selected by: {reason}")
    attach.append(selected["path"])
    others = [s for s in scored if s["path"] != selected["path"]]
    if others:
        print(f"\n  other assigner sessions mentioning {KEY} (NOT attached):")
        for s in others:
            row = fmt(s["path"])
            if row: print(row[0])
else:
    if not scored:
        print("  (none found — the issue may have been created without the assigner, "
              "e.g. an ad-hoc Bug; only the worktree sessions above apply)")
    else:
        print("  (could not pin a single creating session — candidates below need a "
              "human pick; pass --title and --created for an automatic match)")
        for s in scored:
            row = fmt(s["path"])
            if row: print(row[0])

print(f"\n=== attachment paths ({len(attach)}) ===")
for p in attach: print(p)
if not attach:
    print("(none)")
')"

# Always show the grouped detection + path list.
printf '%s\n' "$OUT"

# --attach: hand the computed paths straight to the idempotent uploader, so the
# caller never has to shuttle the path list around. Read-only without it.
if [ -n "$ATTACH" ]; then
  PATHS=()
  while IFS= read -r p; do [ -n "$p" ] && PATHS+=("$p"); done \
    < <(printf '%s\n' "$OUT" | awk '/^=== attachment paths/{f=1;next} f&&/^\//{print}')
  echo
  if [ "${#PATHS[@]}" -eq 0 ]; then
    echo "sync_conversations: nothing to attach."
  else
    bash "$SCRIPT_DIR/jira_attach.sh" ${DRYRUN:+--dry-run} "$KEY" "${PATHS[@]}"
  fi
fi
