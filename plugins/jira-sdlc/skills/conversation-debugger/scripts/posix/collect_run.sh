#!/usr/bin/env bash
# collect_run.sh — step 0 of conversation-debugger, in one call.
#
# Validates the transcript, profiles it, recovers the issue key from the
# place that skill is known to produce it, and — only once the key is
# trustworthy — creates conversations/<KEY>/ and copies the transcript in.
# Prints a KEY=VALUE block for the skill to read.
#
# Usage: collect_run.sh <skill-name> <conversation-path> [issue-key]
#
# Exit: 0 = filed under conversations/<KEY>/
#       1 = hard error (bad input, no repo, unusable transcript)
#       2 = nothing filed, a human has to decide (KEY_STATUS says why)
#
# Where the key comes from is not a guess — each skill produces it at a
# known site in its own run, and a recorded transcript already contains
# that site:
#   jira-task-assigner  -> it *creates* the issue: the key is in the
#                          `acli jira workitem create` result (first create
#                          = the top-level issue; sub-task creates follow).
#   jira-task-executor  -> it *derives* the key from the branch: the key is
#   jira-task-reviewer     in statuscheck's `issue_key` row (branch row as
#                          fallback; the reviewer may then climb to a parent).
# A key found anywhere else is not the run's subject — a transcript can
# mention JST-nn for unrelated reasons ("do it like JST-nn"), and naming a
# directory after that would file the report under the wrong issue. So
# frequency is never used to decide; it is only reported as context.
set -euo pipefail

die() { printf 'collect_run: %s\n' "$1" >&2; exit 1; }

SKILL="${1:-}"
SRC="${2:-}"
FORCED_KEY="${3:-}"
[ -n "$SKILL" ] && [ -n "$SRC" ] \
  || die "usage: collect_run.sh <skill-name> <conversation-path> [issue-key]"
case "$SKILL" in
  jira-task-assigner|jira-task-executor|jira-task-reviewer) ;;
  *) die "'$SKILL' is not one of the three analyzable skills (jira-task-assigner, jira-task-executor, jira-task-reviewer)." ;;
esac
[ -f "$SRC" ] || die "no such transcript: $SRC"
command -v jq >/dev/null || die "jq is required but not on PATH."

# --- repo root: conversations/ always lives at the project root ----------
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "not inside a git repository — run this from the project checkout."
[ -f "$ROOT/jira-sdlc-tools.env" ] \
  || die "jira-sdlc-tools.env not found in $ROOT — run this from the main checkout."

# --- validate + profile --------------------------------------------------
jq -e . "$SRC" >/dev/null 2>&1 || die "$SRC is not valid JSON-lines."
LINES=$(wc -l < "$SRC" | tr -d ' ')
ASSISTANT=$(jq -r 'select(.type=="assistant")|.uuid' "$SRC" 2>/dev/null | wc -l | tr -d ' ')
COMPACTED_N=$(jq -r 'select(.type=="summary")|.type' "$SRC" 2>/dev/null | wc -l | tr -d ' ')
UUID=$(basename "$SRC" .jsonl)
COMPACTED=$([ "$COMPACTED_N" -gt 0 ] && echo yes || echo no)

emit() { # emit <status> <key> <source>
  cat <<EOF
CONVERSATION_UUID=$UUID
SKILL=$SKILL
KEY_STATUS=$1
ISSUE_KEY=${2:-}
KEY_SOURCE=$3
KEY_RANKING=${RANK_FLAT:-}
LINES=$LINES
ASSISTANT_LINES=$ASSISTANT
INVOCATIONS=${INVOCATIONS:-0}
IS_STUB=$([ "$ASSISTANT" -eq 0 ] && echo yes || echo no)
COMPACTED=$COMPACTED
EOF
}

# --- is this transcript actually a run of <skill-name>? ------------------
# The invocation need not be first: a session can open with /model, /usage,
# /context, /compact … before the skill is ever called. So count the skill's
# own invocations anywhere in the file rather than reading the first command.
# Match namespaced and bare alike — the command is /<plugin>:<skill> on a
# marketplace install but plain /<skill> when the skills are loose files or
# the plugin was renamed.
user_prompts() {
  jq -r 'select(.type=="user")|.message.content
        | if type=="string" then . else (.[]? | select(.type=="text") | .text // "") end' "$SRC" 2>/dev/null
}
CMDS=$(user_prompts | grep -oE '<command-name>/[^<]*</command-name>' || true)
INVOCATIONS=$(printf '%s\n' "$CMDS" | grep -cE "<command-name>/([^<:]*:)?${SKILL}</command-name>" || true)
if [ "${INVOCATIONS:-0}" -eq 0 ]; then
  emit no-invocation "" "transcript contains no /${SKILL} invocation"
  {
    echo "collect_run: $SRC contains no invocation of '$SKILL' — this is probably not that skill's run."
    OTHER=$(printf '%s\n' "$CMDS" | sed -e 's/<[^>]*>//g' | sort -u | tr '\n' ' ' | sed 's/  */ /g')
    if [ -n "${OTHER// /}" ]; then
      echo "  commands this transcript does contain: $OTHER"
      echo "  (a session may legitimately open with /model, /usage, /compact … — but the named skill must appear somewhere, and it doesn't)"
    else
      echo "  it contains no slash-command invocation at all."
    fi
    echo "  ASK THE USER: analyze it as one of the skills listed above, or point at a different transcript. Nothing was filed."
  } >&2
  exit 2
fi

# --- project key (same two spellings statuscheck.sh accepts) -------------
cfg() {
  local f v
  for f in jira-sdlc-tools.local.env jira-sdlc-tools.env; do
    [ -f "$ROOT/$f" ] || continue
    v=$(grep -E "^[[:space:]]*($1)[[:space:]]*=" "$ROOT/$f" 2>/dev/null \
        | tail -1 | sed -e 's/^[^=]*=[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  done
  return 1
}
PROJECT_KEY=$(cfg 'PROJECT[-_]KEY' || true)
[ -n "$PROJECT_KEY" ] || die "PROJECT-KEY unset in jira-sdlc-tools.env."

# every <PROJECT-KEY>-<n> in the file, by frequency — context only, never
# the decision (anchored to the project key so line refs like L61-66 can't match)
RANK=$(grep -oE "\\b${PROJECT_KEY}-[0-9]+\\b" "$SRC" 2>/dev/null | sort | uniq -c | sort -rn || true)
RANK_FLAT=$(printf '%s' "$RANK" | tr '\n' ';' | sed -e 's/  */ /g' -e 's/^ //')

# --- stub: no assistant turns, nothing to analyze ------------------------
if [ "$ASSISTANT" -eq 0 ]; then
  emit stub "" "n/a — stub transcript"
  echo "collect_run: no assistant lines — this is a STUB. Nothing filed. Write the short stub report and point at ~/.claude/projects/ to find the full session." >&2
  exit 2
fi

# --- recover the key from this skill's own anchor -------------------------
tool_result_for() { # tool_result_for <tool_use_id>
  jq -r --arg id "$1" 'select(.type=="user")|.message.content
        | if type=="array" then .[] else empty end
        | select(.type=="tool_result" and .tool_use_id==$id)
        | .content | tostring' "$SRC"
}
all_tool_results() {
  jq -r 'select(.type=="user")|.message.content
        | if type=="array" then .[] else empty end
        | select(.type=="tool_result") | .content | tostring' "$SRC"
}

KEY=""; SOURCE=""; STATUS=""
if [ -n "$FORCED_KEY" ]; then
  KEY="$FORCED_KEY"; SOURCE="explicit argument"; STATUS=given
elif [ "$SKILL" = "jira-task-assigner" ]; then
  # the assigner mints the key: first `workitem create` (not `comment create`).
  # Matched by command text, never the tool's name — the shell tool is "Bash" on
  # POSIX but "PowerShell" on Windows (and may be renamed again), while only
  # shell-type tools carry .input.command at all. The result parse below then
  # validates the match, so a false positive cannot file a wrong key.
  CREATE_ID=$(jq -r 'select(.type=="assistant")|.message.content[]?
        | select(.type=="tool_use")
        | select((.input.command? // "") | test("workitem[[:space:]]+create"))
        | .id' "$SRC" 2>/dev/null | head -1)
  if [ -n "${CREATE_ID:-}" ]; then
    RES=$(tool_result_for "$CREATE_ID")
    KEY=$(printf '%s' "$RES" | jq -r '.key // empty' 2>/dev/null || true)   # --json form
    [ -n "$KEY" ] || KEY=$(printf '%s' "$RES" | grep -oE "\\b${PROJECT_KEY}-[0-9]+\\b" | head -1 || true)  # text/browse-URL form
    if [ -n "$KEY" ]; then
      STATUS=expected; SOURCE="acli workitem create result (the issue this run created)"
    else
      STATUS=unexpected; SOURCE="workitem create ran but its result carried no ${PROJECT_KEY}-<n> (create failed, or output was truncated)"
    fi
  else
    STATUS=unexpected; SOURCE="no 'acli jira workitem create' call in the transcript — this run never created an issue"
  fi
else
  # executor/reviewer derive the key from the branch — statuscheck reports it
  ROW=$(all_tool_results | grep -E '^\|[[:space:]]*issue_key[[:space:]]*\|' | head -1 || true)
  KEY=$(printf '%s' "$ROW" | grep -oE "\\b${PROJECT_KEY}-[0-9]+\\b" | head -1 || true)
  if [ -n "$KEY" ]; then
    STATUS=expected; SOURCE="statuscheck issue_key row (derived from the worktree's branch)"
  else
    BROW=$(all_tool_results | grep -E '^\|[[:space:]]*branch[[:space:]]*\|' | head -1 || true)
    KEY=$(printf '%s' "$BROW" | grep -oE "\\b${PROJECT_KEY}-[0-9]+\\b" | head -1 || true)
    if [ -n "$KEY" ]; then
      STATUS=expected; SOURCE="statuscheck branch row (issue_key row carried no key)"
    elif [ -n "$ROW" ]; then
      STATUS=unexpected; SOURCE="statuscheck ran but resolved no issue key: ${ROW}"
    else
      STATUS=unexpected; SOURCE="no statuscheck issue_key row — the run never got past the healthcheck, or it was truncated"
    fi
  fi
fi

# --- nothing trustworthy → file nothing, hand it to the human ------------
if [ "$STATUS" != "expected" ] && [ "$STATUS" != "given" ]; then
  emit "$STATUS" "" "$SOURCE"
  {
    echo "collect_run: could not recover the issue key where $SKILL is supposed to produce it."
    echo "  reason : $SOURCE"
    if [ -n "$RANK_FLAT" ]; then
      echo "  the transcript does mention: $RANK_FLAT"
      echo "  — but a mention is not the run's subject (a run can cite an unrelated issue), so nothing was filed."
    else
      echo "  the transcript mentions no ${PROJECT_KEY}-<n> at all."
    fi
    echo "  ASK THE USER which issue key to file under, then re-run:"
    echo "    collect_run.sh $SKILL $SRC <issue-key>"
  } >&2
  exit 2
fi

# --- run metrics ---------------------------------------------------------
# All measured, none inferred. Two traps this avoids:
#  * one API response is split across several assistant lines (one per
#    content block), and every one of them carries the SAME usage object —
#    summing per line overcounts (2.6x on a real run). Dedup by message.id.
#  * content blocks are NOT duplicated across those lines, so tool_use
#    blocks must be counted over every line, not the deduped set.
# Scope is the skill's own turns via attributionSkill (present on every
# assistant line in all transcripts checked), so pre/post-skill chatter and
# other skills in the same session don't pollute the numbers.
METRICS=$(jq -s -r --arg skill "$SKILL" '
  def dedup: group_by(.message.id // "") | map(.[0]);
  def secs: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
  def tally: group_by(.name) | map({name: .[0].name, n: length}) | sort_by(-.n)
             | map("\(.name):\(.n)") | join(" ");
  [ .[] | select(.type=="assistant")
        | select(((.attributionSkill // "") | endswith($skill))) ] as $all
  | ($all | map(select(.isSidechain != true))) as $main
  | ($main | dedup) as $d
  | [ $main[] | .message.content[]? | select(.type=="tool_use") | {id, name} ] as $calls
  | ([ .[] | select(.type=="user") | .message.content
       | if type=="array" then .[] else empty end
       | select(.type=="tool_result" and .is_error == true) | .tool_use_id ] | unique) as $errids
  | ($calls | map(select(.id as $i | $errids | index($i) != null))) as $errcalls
  | {
      turns:      ($d | length),
      lines:      ($all | length),
      side:       ($all | map(select(.isSidechain == true)) | dedup | length),
      tin:        ($d | map(.message.usage.input_tokens // 0) | add // 0),
      tout:       ($d | map(.message.usage.output_tokens // 0) | add // 0),
      tcr:        ($d | map(.message.usage.cache_read_input_tokens // 0) | add // 0),
      tcw:        ($d | map(.message.usage.cache_creation_input_tokens // 0) | add // 0),
      models:     ($d | map(.message.model // empty) | unique | join(" ")),
      first:      ($all | map(.timestamp) | min // ""),
      last:       ($all | map(.timestamp) | max // ""),
      span:       (if ($all|length) > 0
                   then (($all | map(.timestamp) | max | secs) - ($all | map(.timestamp) | min | secs))
                   else 0 end),
      toolcalls:  ($calls | length),
      tools:      ($calls | tally),
      errs:       ($errcalls | length),
      errtools:   ($errcalls | tally)
    }
  | "SKILL_TURNS=\(.turns)\nSKILL_LINES=\(.lines)\nSIDECHAIN_TURNS=\(.side)\nTOKENS_IN=\(.tin)\nTOKENS_OUT=\(.tout)\nTOKENS_CACHE_READ=\(.tcr)\nTOKENS_CACHE_WRITE=\(.tcw)\nMODELS=\(.models)\nFIRST_TS=\(.first)\nLAST_TS=\(.last)\nWALL_CLOCK_S=\(.span)\nTOOL_CALLS=\(.toolcalls)\nTOOLS_USED=\(.tools)\nTOOL_ERRORS=\(.errs)\nTOOL_ERRORS_BY_TOOL=\(.errtools)"
' "$SRC" 2>/dev/null || true)

# --- create + copy (idempotent) ------------------------------------------
# Keep conversations/ out of git before anything lands in it. Transcripts are
# raw session logs (absolute paths, emails, instance URLs, whatever the run
# printed) and this marketplace is public, so the guard has to ship with the
# script rather than rely on each machine having been set up by hand. `*`
# ignores the ignore-file itself, which is what we want: nothing here is ever
# committed, and a fresh clone gets the same protection on its first run.
mkdir -p "$ROOT/conversations"
if [ ! -e "$ROOT/conversations/.gitignore" ]; then
  printf '*\n' > "$ROOT/conversations/.gitignore"
  echo "collect_run: created conversations/.gitignore (*) — transcripts stay local, never committed." >&2
fi

DEST="$ROOT/conversations/$KEY"
mkdir -p "$DEST"
cp "$SRC" "$DEST/$UUID.jsonl"
chmod 644 "$DEST/$UUID.jsonl"   # source is 0600 in ~/.claude/projects

# Transcript byte size of the profiled source (portable: wc -c, not stat, whose
# flags differ across GNU/BSD). Measured HERE — the only layer that holds $SRC —
# so collect_feature can thread it through and feature_report re-measures nothing.
BYTES=$(wc -c < "$SRC" | tr -d ' ')

REL="conversations/$KEY"
emit "$STATUS" "$KEY" "$SOURCE"
cat <<EOF
REPORT_DIR=$REL
TRANSCRIPT_COPY=$REL/$UUID.jsonl
TRANSCRIPT_BYTES=$BYTES
$METRICS
EOF

# an anchor key that isn't the loudest key is normal, not suspicious —
# say so once rather than letting the ranking raise a false alarm
TOP=$(printf '%s\n' "$RANK" | awk 'NR==1{print $2}')
if [ -n "${TOP:-}" ] && [ "$TOP" != "$KEY" ]; then
  echo "collect_run: note — '$TOP' is mentioned more often than '$KEY', but '$KEY' is what this run acted on ($SOURCE). Filed under '$KEY'." >&2
fi
echo "collect_run: $REL is git-ignored — the transcript is a raw session log (absolute paths, emails, instance URLs, whatever the run printed) and stays local. Don't force-add it." >&2
