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
#     is removed, so we read the folder directly, not `git worktree list`.
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
# Claude Code names each project folder after the session's cwd with every '/'
# replaced by '-' (verified: /home/u/proj -> -home-u-proj). We reproduce that
# mapping to locate the two folders precisely instead of guessing.
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

# Claude Code–specific by nature: it reads Claude Code's own transcript store.
# Other harnesses (Codex, Cursor, Kilo, OpenCode, …) keep session logs elsewhere
# or not at all, so degrade honestly instead of erroring cryptically — the three
# core skills stay harness-neutral; only this builtin knows about transcripts.
PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
[ -d "$PROJECTS" ] || {
  echo "sync_conversations: no transcript store at $PROJECTS — this builtin is specific to Claude Code (it attaches Claude Code conversation logs). Nothing to sync on this agent." >&2
  exit 1; }

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

# Main checkout root: the first entry of `git worktree list` is always the main
# checkout, even when this runs from inside a linked worktree.
MAIN_ROOT=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
[ -n "$MAIN_ROOT" ] || MAIN_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$MAIN_ROOT" ] || { echo "sync_conversations: not inside a git repository (cwd: $PWD)" >&2; exit 1; }

enc() { printf '%s' "$1" | sed 's#[/.]#-#g'; }   # cwd -> project-folder name
MAIN_FOLDER="$PROJECTS/$(enc "$MAIN_ROOT")"

# Worktree folder: a project folder ending in exactly 'worktree-<KEY>'. The
# trailing-anchored glob is boundary-safe (`*worktree-JST-9` can't match
# `…worktree-JST-93`). May legitimately be absent.
WT_FOLDER=""
for d in "$PROJECTS"/*"worktree-$KEY"; do
  [ -d "$d" ] && { WT_FOLDER="$d"; break; }
done

# Emit the candidate files, tagged W (worktree, all) or M (main assigner-command
# session that also mentions the key). Selection among M happens in python.
gather() {
  if [ -n "$WT_FOLDER" ]; then
    for f in "$WT_FOLDER"/*.jsonl; do [ -f "$f" ] && printf 'W\t%s\n' "$f"; done
  fi
  if [ -d "$MAIN_FOLDER" ]; then
    grep -rlE 'command-name>/?jira-sdlc:jira-task-assigner' "$MAIN_FOLDER"/*.jsonl 2>/dev/null \
      | while IFS= read -r f; do grep -qwF "$KEY" "$f" && printf 'M\t%s\n' "$f"; done
  fi
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
    bash "$SCRIPT_DIR/../../../_shared/scripts/jira_attach.sh" ${DRYRUN:+--dry-run} "$KEY" "${PATHS[@]}"
  fi
fi
