#!/usr/bin/env bash
# conversation_metrics.sh — print a markdown table of what a Claude Code run
# actually cost: turns, tokens, cache hits, wall clock, tool calls, tool errors.
#
# Written for the demo workflows in .github/workflows/, which pipe its stdout
# straight into a `gh issue comment` / `gh pr comment` body:
#
#   { printf '### 2 · executor — conversation metrics\n\n'
#     bash .github/scripts/conversation_metrics.sh
#   } > "$BODY"
#
# CI-only and POSIX-only *by decision*, which is why it lives here and not
# under plugins/jira-sdlc/skills/_shared/scripts/ — that location carries
# AGENTS.md's win/*.ps1 parity rule, and GitHub runners are Linux. Don't move
# it there without also porting it.
#
# Usage: conversation_metrics.sh [transcript.jsonl ...]
#   No argument → glob $HOME/.claude/projects/*/*.jsonl, the same discovery the
#   GIF steps use. Each job runs on a fresh VM with no shared filesystem, so
#   there is normally exactly one transcript and it is that job's own skill run.
#   An explicit path is for testing this script against a known transcript.
#
# NEVER fails its caller. A missing transcript, unusable JSON, or an absent jq
# degrades to an explanatory line and exit 0 — metrics are a nicety, and a
# green run must not redden because the nicety was unavailable. Hence
# `set -uo pipefail` with no `-e`.
set -uo pipefail

# The measurement itself, lifted from the conversation-debugger skill's
# collect_run.sh (its `run metrics` block) where it was measured against real
# transcripts. Two traps it exists to avoid — both survive verbatim:
#  * one API response is split across several assistant lines (one per content
#    block), and every one of them carries the SAME usage object — summing per
#    line overcounts (2.6x on a real run). Dedup by message.id before summing.
#  * content blocks are NOT duplicated across those lines, so tool_use blocks
#    must be counted over every line, not over the deduped set.
#
# One deliberate departure from collect_run.sh: no attributionSkill filter, so
# the scope is the WHOLE conversation. The runner's filesystem isn't shared
# between jobs, so the only conversation present already IS the executed
# skill's run; filtering would only add a silent-empty-table failure mode
# (headless `claude -p` isn't confirmed to set that field).
metrics_filter='
  def dedup: group_by(.message.id // "") | map(.[0]);
  def secs: sub("\\.[0-9]+Z$";"Z") | fromdateiso8601;
  def tally: group_by(.name) | map({name: .[0].name, n: length}) | sort_by(-.n)
             | map("\(.name):\(.n)") | join(" ");
  def dur: (./3600|floor) as $h | ((.%3600)/60|floor) as $m | (.%60|floor) as $s
           | if $h > 0 then "\($h)h \($m)m \($s)s"
             elif $m > 0 then "\($m)m \($s)s"
             else "\($s)s" end;
  [ .[] | select(.type=="assistant") ] as $all
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
  | "| metric | value |",
    "|---|---|",
    "| turns | \(.turns) |",
    "| assistant lines | \(.lines) |",
    "| sidechain turns | \(.side) |",
    "| tokens in | \(.tin) |",
    "| tokens out | \(.tout) |",
    "| tokens cache read | \(.tcr) |",
    "| tokens cache write | \(.tcw) |",
    "| models | \(if .models == "" then "—" else .models end) |",
    "| first timestamp | \(if .first == "" then "—" else .first end) |",
    "| last timestamp | \(if .last == "" then "—" else .last end) |",
    "| wall clock | \(.span | dur) |",
    "| tool calls | \(.toolcalls) |",
    "| tools used | \(if .tools == "" then "—" else .tools end) |",
    "| tool errors | \(.errs) |",
    "| tool errors by tool | \(if .errtools == "" then "—" else .errtools end) |"
'

# The footnote is part of the numbers, not decoration: `turns`, the token
# totals and the tool counts are main-chain only, with subagent work reported
# separately as `sidechain turns`. Without this line the table quietly reads as
# a whole-session total.
FOOTNOTE='_Turns, tokens and tool calls cover the main chain — subagent (sidechain) work is reported as its own row. Token totals are deduped by `message.id`: one API response spans several transcript lines that all repeat the same usage object._'

if ! command -v jq >/dev/null 2>&1; then
  echo "_Conversation metrics unavailable — \`jq\` is not installed on this runner._"
  exit 0
fi

if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  shopt -s nullglob
  FILES=("$HOME"/.claude/projects/*/*.jsonl)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "_No Claude session transcript found on this runner — nothing to measure._"
  exit 0
fi

rendered=0
for f in "${FILES[@]}"; do
  if [ ! -s "$f" ]; then
    echo "_Transcript \`$(basename "$f")\` is missing or empty — nothing to measure._"
    echo ""
    continue
  fi
  # jq -s slurps the whole JSONL; a single malformed line aborts it, which is
  # a degrade case rather than a failure. Capture, then check.
  TABLE=$(jq -s -r "$metrics_filter" "$f" 2>/dev/null)
  if [ -z "$TABLE" ]; then
    echo "_Transcript \`$(basename "$f")\` could not be parsed — no metrics for this run._"
    echo ""
    continue
  fi
  # Normally exactly one transcript per job; name them only when that
  # assumption turns out not to hold, so the usual comment stays clean.
  if [ "${#FILES[@]}" -gt 1 ]; then
    echo "#### \`$(basename "$f")\`"
    echo ""
  fi
  echo "$TABLE"
  echo ""
  rendered=$((rendered + 1))
done

[ "$rendered" -gt 0 ] && echo "$FOOTNOTE"
exit 0
