#!/usr/bin/env bash
# feature_report.sh [<json-path>]
#
# Report-builder half of the feature roll-up: consumes the collect_feature JSON
# and renders a markdown feature report from it. The pipeline is
#   collect_feature.sh <KEY>  ->  JSON  ->  feature_report.sh  ->  markdown
# collect_feature is the single OWNER of the JSON schema
# (see ../../references/feature-report-schema.md); this script only READS it and
# never re-measures — every number rendered here is a value the collector already
# emitted.
#
# It renders BOTH feature types the collector emits, detected from the JSON:
#   * single-step (feature-report@2, flat)  -> the flat template.
#   * multistep  (feature-report@3, nested) -> a parent summary, one section per
#     CHILD feature with that child's conversations in-place, then feature-wide
#     totals + the by-skill / by-provenance / timeframe roll-ups and pie(s) across
#     the whole feature. Detection is the presence of `children` / a `@3` schema
#     tag; @1/@2 JSON (no `children`) renders through the untouched single-step
#     path, so there is no regression on existing single-step reports.
#
# Input — a path and/or stdin (whichever is given):
#   feature_report.sh report.json > report.md      # from a file
#   collect_feature.sh JST-93 | feature_report.sh > report.md   # from stdin
# A '-' path also means stdin. With no path and no piped input it prints usage
# and exits 1 rather than blocking on the console.
#
# Output: the markdown report on stdout, nothing else. Read-only: it neither
# writes files nor touches Jira/git.
#
# POSIX twin of ../win/feature_report.ps1 — same CLI, same stdout, same exit
# codes. The heavy JSON parsing + rendering runs in python3 (advanced parsing,
# mirroring sync_conversations.sh's python core); this bash shim only hands it
# the script's args and stdin.
#
# Exit: 0 = markdown emitted   1 = usage / unreadable-or-invalid JSON

set -u

command -v python3 >/dev/null 2>&1 || {
  printf 'feature_report: python3 is required but not on PATH.\n' >&2; exit 1; }

PROG=$(cat <<'PYEOF'
import sys, os, json
from datetime import datetime, timezone

def fail(msg):
    sys.stderr.write("feature_report: %s\n" % msg)
    sys.exit(1)

# ---- read the JSON (path arg, or stdin) -------------------------------------
args = sys.argv[1:]
path_arg = args[0] if args else ''
raw = None
if path_arg and path_arg != '-':
    if not os.path.isfile(path_arg):
        fail("no such JSON file: %s" % path_arg)
    with open(path_arg, encoding='utf-8', errors='replace') as fh:
        raw = fh.read()
elif path_arg == '-' or not sys.stdin.isatty():
    raw = sys.stdin.read()
else:
    fail("need collect_feature JSON: pass a path, or pipe it in "
         "(collect_feature.sh <KEY> | feature_report.sh).")
if raw is None or raw.strip() == '':
    fail("empty input -- no JSON to render.")
try:
    data = json.loads(raw)
except Exception:
    fail("input is not valid JSON (expected collect_feature output).")

# Feature type: multistep iff the collector emitted a `children` array (or tagged
# the schema @3). @1/@2 JSON has no `children` and renders through the single-step
# path below unchanged.
is_multi = (data.get('children') is not None) or \
           (bool(data.get('schema')) and str(data['schema']).rstrip().endswith('@3'))
if is_multi:
    if data.get('feature') is None or data.get('parent') is None \
       or data.get('children') is None or data.get('aggregate') is None:
        fail("multistep JSON is missing feature/parent/children/aggregate -- "
             "is this collect_feature @3 output?")
else:
    if data.get('feature') is None or data.get('conversations') is None \
       or data.get('aggregate') is None:
        fail("JSON is missing feature/conversations/aggregate -- "
             "is this collect_feature output?")

# ---- formatting helpers -----------------------------------------------------
# Only None / '' render as '-'; a measured 0 must render as 0.
def num(n):
    if n is None or (isinstance(n, str) and n == ''):
        return '-'
    return "{:,}".format(int(n))

def sec(n):
    if n is None or (isinstance(n, str) and n == ''):
        return '-'
    return "{:,.1f}".format(float(n))

# Bytes -> human size (KB/MB, one decimal; 1 KB = 1024 B). Absent -> '-', so
# older JSON without the field renders cleanly. Uses the same "{:,.1f}" idiom as
# sec() (win: '{0:N1}') so both hosts round the identical value the same way —
# the proven one-decimal parity pair. Rendered only; the collector measured it.
def size(b):
    if b is None or (isinstance(b, str) and b == ''):
        return '-'
    b = float(b)
    if b >= 1024 * 1024:
        return "{:,.1f} MB".format(b / (1024 * 1024))
    return "{:,.1f} KB".format(b / 1024)

def join_list(xs):
    if xs is None:
        return '-'
    a = list(xs)
    if len(a) == 0:
        return '-'
    return ', '.join(str(x) for x in a)

# Per-record tools list -> one table cell: "Bash:10, Read:7", a tool with
# errors flagged inline as "Bash:10(!2)". Absent (older JSON, or a record
# without metrics) -> '-'.
def tools_cell(tools):
    if not tools:
        return '-'
    parts = []
    for t in tools:
        e = int(t.get('errors') or 0)
        parts.append("%s:%s%s" % (t['name'], t['calls'], ("(!%d)" % e) if e else ''))
    return ', '.join(parts)

# Timestamps arrive as the raw ISO-8601 string (collect_feature copies them
# through verbatim). Render them as compact UTC "YYYY-MM-DD HH:MM:SSZ" (seconds
# precision, no 'T', no fractional) — matching the win/ port, whose ConvertFrom-Json
# parses the ISO-Z string to a DateTime that Ts then formats that way. An
# unparseable value falls back to the raw string, as Ts does.
def ts(v):
    if v is None or v == '':
        return '-'
    try:
        d = datetime.fromisoformat(str(v).strip().replace('Z', '+00:00'))
        return d.astimezone(timezone.utc).strftime('%Y-%m-%d %H:%M:%SZ')
    except Exception:
        return str(v)

# Seconds -> human span (collector-provided number, formatted only).
# The leading unit is round()ed, NOT truncated, to match the win/ port: its
# Dur() casts $t.TotalHours / $t.TotalMinutes with PowerShell's [int], which
# rounds half-to-even — and Python's round() is the same half-to-even rule, so
# e.g. 5400s renders "2h 30m 0s" on both hosts ([int]1.5 == round(1.5) == 2).
# The minute/second components stay truncated (int), mirroring the TimeSpan
# .Minutes / .Seconds integer components the win/ port reads.
# A zero span renders '-', matching the win/ port: its guard `$sec -eq ''` also
# catches a numeric 0 because PowerShell coerces the RHS ('') to the LHS's type,
# and `[double]0 -eq '' == True` — so Dur(0) returns '-' there, and here.
def dur(s):
    if s is None or s == '':
        return '-'
    s = float(s)
    if s == 0:
        return '-'
    if s / 3600 >= 1:
        return "%dh %dm %ds" % (round(s / 3600), int((s % 3600) // 60), int(s % 60))
    if s / 60 >= 1:
        return "%dm %ds" % (round(s / 60), int(s % 60))
    return "{:,.1f}s".format(s)

out = []

# Emit a GitHub-native mermaid pie of the (label,value) pairs whose value > 0.
# Skipped for < 2 slices (a single slice is always 100%). Labels are sanitized:
# quotes stripped and ';' -> ',' because a ';' silently truncates a mermaid line
# and breaks the whole diagram (see AGENTS.md).
def emit_pie(title, pairs):
    rows = [p for p in pairs if p['value'] is not None and float(p['value']) > 0]
    if len(rows) < 2:
        return
    out.append('```mermaid')
    out.append('pie showData')
    out.append('    title ' + title.replace(';', ','))
    for r in rows:
        lbl = str(r['label']).replace('"', '').replace(';', ',')
        out.append('    "%s" : %d' % (lbl, int(r['value'])))
    out.append('```')
    out.append('')

# ---- reusable section renderers ---------------------------------------------
def emit_tokens_section(conv, level='##'):
    out.append("%s Per-conversation — tokens" % level)
    out.append('')
    out.append('| conversation | provenance | skill | issue | model(s) | in | out | cache-read | cache-write | total | tool calls | elapsed (s) | size |')
    out.append('|---|---|---|---|---|--:|--:|--:|--:|--:|--:|--:|--:|')
    for c in conv:
        skill = c['skill'] if c.get('skill') else '_(no skill)_'
        issue = c['issue_key'] if c.get('issue_key') else '-'
        # A record with no measured metrics (skill_turns null: stub / unexpected /
        # no-skill) is listed for coverage but has no numbers — render its metric
        # cells as em-dashes and surface why, so a zero never reads as a real zero.
        if c.get('skill_turns') is not None:
            models = join_list(c.get('models'))
            t = c['tokens']
            out.append("| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                c['uuid'], c['provenance'], skill, issue, models,
                num(t['in']), num(t['out']), num(t['cache_read']), num(t['cache_write']),
                num(t['total']), num(c.get('tool_calls')), sec(c.get('wall_clock_s')),
                size(c.get('size_bytes'))))
        else:
            why = "_not analyzed: %s_" % c.get('key_status')
            out.append("| `%s` | %s | %s | %s | %s | — | — | — | — | — | — | — | — |" % (
                c['uuid'], c['provenance'], skill, issue, why))
    out.append('')
    # pie: total-token share per conversation (analyzed rows carrying tokens)
    conv_pie = []
    for c in conv:
        if c.get('skill_turns') is not None and c.get('tokens') is not None \
           and float(c['tokens']['total']) > 0:
            sk = c['skill'] if c.get('skill') else '(no skill)'
            uuid = str(c['uuid'])
            short = uuid[:8] if len(uuid) >= 8 else uuid
            conv_pie.append({'label': "%s · %s" % (sk, short), 'value': int(c['tokens']['total'])})
    emit_pie('Token consumption by conversation (total tokens)', conv_pie)

def emit_perf_section(conv, level='##'):
    out.append("%s Per-conversation — performance" % level)
    out.append('')
    out.append('| conversation | skill | skill turns | sidechain turns | tool calls | tool errors | tools used (calls) | elapsed (s) | first activity | last activity |')
    out.append('|---|---|--:|--:|--:|--:|---|--:|---|---|')
    for c in conv:
        skill = c['skill'] if c.get('skill') else '_(no skill)_'
        if c.get('skill_turns') is not None:
            out.append("| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                c['uuid'], skill, num(c.get('skill_turns')), num(c.get('sidechain_turns')),
                num(c.get('tool_calls')), num(c.get('tool_errors')), tools_cell(c.get('tools')),
                sec(c.get('wall_clock_s')), ts(c.get('first_ts')), ts(c.get('last_ts'))))
        else:
            out.append("| `%s` | %s | — | — | — | — | — | — | — | — |" % (c['uuid'], skill))
    out.append('')

def emit_by_skill(agg):
    bs = agg.get('by_skill')
    if bs is not None and len(bs) > 0:
        out.append('## Tokens by skill')
        out.append('')
        out.append('| skill | conversations | in | out | cache-read | cache-write | total |')
        out.append('|---|--:|--:|--:|--:|--:|--:|')
        for s in bs:
            t = s['tokens']
            out.append("| %s | %s | %s | %s | %s | %s | %s |" % (
                s['skill'], num(s['conversations']), num(t['in']), num(t['out']),
                num(t['cache_read']), num(t['cache_write']), num(t['total'])))
        out.append('')
        skill_pie = [{'label': str(s['skill']), 'value': int(s['tokens']['total'])}
                     for s in bs if s.get('tokens') is not None and float(s['tokens']['total']) > 0]
        emit_pie('Token consumption by skill (total tokens)', skill_pie)

def emit_by_tool(agg):
    bt = agg.get('by_tool')
    if bt is not None and len(bt) > 0:
        out.append('## Tool usage')
        out.append('')
        out.append('| tool | conversations | calls | errors |')
        out.append('|---|--:|--:|--:|')
        for t in bt:
            out.append("| %s | %s | %s | %s |" % (
                t['tool'], num(t.get('conversations')), num(t.get('calls')), num(t.get('errors'))))
        out.append('')
        tool_pie = [{'label': str(t['tool']), 'value': int(t['calls'])}
                    for t in bt if t.get('calls') is not None and float(t['calls']) > 0]
        emit_pie('Tool calls by tool', tool_pie)

def emit_by_provenance(agg):
    bp = agg.get('by_provenance')
    if bp is not None and len(bp) > 0:
        out.append('## Tokens by provenance')
        out.append('')
        out.append('| provenance | conversations | in | out | cache-read | cache-write | total |')
        out.append('|---|--:|--:|--:|--:|--:|--:|')
        for p in bp:
            t = p['tokens']
            out.append("| %s | %s | %s | %s | %s | %s | %s |" % (
                p['provenance'], num(p['conversations']), num(t['in']), num(t['out']),
                num(t['cache_read']), num(t['cache_write']), num(t['total'])))
        out.append('')

def emit_feature_totals(agg):
    out.append('## Feature totals')
    out.append('')
    out.append('| token bucket | tokens |')
    out.append('|---|--:|')
    t = agg['tokens']
    out.append("| input | %s |" % num(t['in']))
    out.append("| output | %s |" % num(t['out']))
    out.append("| cache read | %s |" % num(t['cache_read']))
    out.append("| cache write | %s |" % num(t['cache_write']))
    out.append("| **grand total** | **%s** |" % num(t['total']))
    out.append('')
    out.append("Models across the feature: **%s**" % join_list(agg.get('models')))
    out.append('')

def emit_timeframe(agg):
    tf = agg.get('timeframe')
    if tf and (tf.get('first_ts') or tf.get('last_ts')):
        out.append('## Activity timeframe')
        out.append('')
        out.append('| metric | value |')
        out.append('|---|---|')
        out.append("| First activity | %s |" % ts(tf.get('first_ts')))
        out.append("| Last activity | %s |" % ts(tf.get('last_ts')))
        out.append("| Span (first → last) | %s |" % dur(tf.get('span_s')))
        out.append('')
        out.append("_Span is wall-clock from the earliest to the latest measured turn across the feature — it includes idle gaps between sessions and human wait time, so it is not compute time and does not equal the sum of per-conversation elapsed._")
        out.append('')

if not is_multi:
    # =========================================================================
    # SINGLE-STEP (feature-report@1/@2) — the flat template
    # =========================================================================
    agg = data['aggregate']
    conv = list(data['conversations'])

    out.append("# Feature report — %s" % data['feature'])
    out.append('')
    analyzed = agg['analyzed_count'] if agg.get('analyzed_count') is not None else len(conv)
    out.append("_Generated by `feature_report` from `collect_feature` JSON — %d conversation(s), %s with measured metrics. Every figure is the collector's own; nothing is re-estimated._" % (len(conv), analyzed))
    out.append('')
    out.append('## Summary')
    out.append('')
    out.append('| metric | value |')
    out.append('|---|---|')
    out.append("| Feature | %s |" % data['feature'])
    out.append("| Conversations | %d (analyzed: %s) |" % (len(conv), analyzed))
    out.append("| **Total token consumption** | **%s** |" % num(agg['tokens']['total']))
    out.append("| — input | %s |" % num(agg['tokens']['in']))
    out.append("| — output | %s |" % num(agg['tokens']['out']))
    out.append("| — cache read | %s |" % num(agg['tokens']['cache_read']))
    out.append("| — cache write | %s |" % num(agg['tokens']['cache_write']))
    out.append("| Models used | %s |" % join_list(agg.get('models')))
    out.append("| Skills exercised | %s |" % join_list(agg.get('skills')))
    out.append("| Issue keys touched | %s |" % join_list(agg.get('issue_keys')))
    if agg.get('skill_turns') is not None:
        out.append("| Total skill turns | %s |" % num(agg['skill_turns']))
    if agg.get('tool_calls') is not None:
        out.append("| Total tool calls | %s (errors: %s) |" % (num(agg['tool_calls']), num(agg.get('tool_errors'))))
    if agg.get('by_tool'):
        out.append("| Distinct tools used | %d |" % len(agg['by_tool']))
    tf = agg.get('timeframe')
    if tf and tf.get('span_s') is not None:
        out.append("| Activity span | %s (%s → %s) |" % (dur(tf['span_s']), ts(tf.get('first_ts')), ts(tf.get('last_ts'))))
    out.append('')

    emit_tokens_section(conv)
    emit_perf_section(conv)
    emit_by_skill(agg)
    emit_by_provenance(agg)
    emit_by_tool(agg)
    emit_feature_totals(agg)
    emit_timeframe(agg)
else:
    # =========================================================================
    # MULTISTEP (feature-report@3) — parent + child features, in place
    # =========================================================================
    fagg = data['aggregate']
    parent = data['parent']
    children = list(data['children'])
    total_conv = data['conversation_count'] if data.get('conversation_count') is not None \
        else len(parent.get('conversations') or [])
    analyzed = fagg['analyzed_count'] if fagg.get('analyzed_count') is not None else total_conv

    out.append("# Feature report — %s (multistep)" % data['feature'])
    out.append('')
    out.append("_Generated by `feature_report` from `collect_feature` JSON — multistep feature: parent **%s** + %d child feature(s), %s conversation(s) feature-wide, %s with measured metrics. Every figure is the collector's own; nothing is re-estimated._" % (parent['key'], len(children), total_conv, analyzed))
    out.append('')
    out.append('## Feature summary')
    out.append('')
    out.append('| metric | value |')
    out.append('|---|---|')
    out.append("| Feature (parent) | %s |" % parent['key'])
    if parent.get('summary'):
        out.append("| Parent summary | %s |" % parent['summary'])
    out.append("| Child features | %d |" % len(children))
    out.append("| Conversations (feature-wide) | %s (analyzed: %s) |" % (total_conv, analyzed))
    out.append("| **Total token consumption** | **%s** |" % num(fagg['tokens']['total']))
    out.append("| — input | %s |" % num(fagg['tokens']['in']))
    out.append("| — output | %s |" % num(fagg['tokens']['out']))
    out.append("| — cache read | %s |" % num(fagg['tokens']['cache_read']))
    out.append("| — cache write | %s |" % num(fagg['tokens']['cache_write']))
    out.append("| Models used | %s |" % join_list(fagg.get('models')))
    out.append("| Skills exercised | %s |" % join_list(fagg.get('skills')))
    out.append("| Issue keys touched | %s |" % join_list(fagg.get('issue_keys')))
    if fagg.get('skill_turns') is not None:
        out.append("| Total skill turns | %s |" % num(fagg['skill_turns']))
    if fagg.get('tool_calls') is not None:
        out.append("| Total tool calls | %s (errors: %s) |" % (num(fagg['tool_calls']), num(fagg.get('tool_errors'))))
    if fagg.get('by_tool'):
        out.append("| Distinct tools used | %d |" % len(fagg['by_tool']))
    tf = fagg.get('timeframe')
    if tf and tf.get('span_s') is not None:
        out.append("| Activity span | %s (%s → %s) |" % (dur(tf['span_s']), ts(tf.get('first_ts')), ts(tf.get('last_ts'))))
    out.append('')

    # ---- token share by feature part (parent-own + each child) --------------
    out.append('## Token share by feature part')
    out.append('')
    out.append('| feature part | key | conversations | total tokens |')
    out.append('|---|---|--:|--:|')
    out.append("| parent (own) | %s | %s | %s |" % (parent['key'], num(parent['aggregate']['conversation_count']), num(parent['aggregate']['tokens']['total'])))
    for c in children:
        out.append("| child | %s | %s | %s |" % (c['key'], num(c['aggregate']['conversation_count']), num(c['aggregate']['tokens']['total'])))
    out.append('')
    part_pie = []
    if parent['aggregate'].get('tokens') is not None and float(parent['aggregate']['tokens']['total']) > 0:
        part_pie.append({'label': "parent · %s" % parent['key'], 'value': int(parent['aggregate']['tokens']['total'])})
    for c in children:
        if c['aggregate'].get('tokens') is not None and float(c['aggregate']['tokens']['total']) > 0:
            part_pie.append({'label': str(c['key']), 'value': int(c['aggregate']['tokens']['total'])})
    emit_pie('Token consumption by feature part (total tokens)', part_pie)

    # ---- parent's own conversations, in place -------------------------------
    out.append("## Parent feature — %s" % parent['key'])
    out.append('')
    if parent.get('summary'):
        out.append("_%s_" % parent['summary'])
        out.append('')
    pconv = list(parent.get('conversations') or [])
    if len(pconv) > 0:
        emit_tokens_section(pconv, '###')
        emit_perf_section(pconv, '###')
    else:
        out.append('_No conversations attributed to the parent itself (e.g. the creating assigner session was not resolved, or the parent has no worktree)._')
        out.append('')

    # ---- each child feature, conversations in place -------------------------
    for c in children:
        out.append("## Child feature — %s" % c['key'])
        out.append('')
        if c.get('summary'):
            out.append("_%s_" % c['summary'])
            out.append('')
        cconv = list(c.get('conversations') or [])
        if len(cconv) > 0:
            emit_tokens_section(cconv, '###')
            emit_perf_section(cconv, '###')
        else:
            out.append('_No conversations resolved for this child feature yet (no worktree, or no sessions in it)._')
            out.append('')

    # ---- feature-wide roll-ups ---------------------------------------------
    emit_by_skill(fagg)
    emit_by_provenance(fagg)
    emit_by_tool(fagg)
    emit_feature_totals(fagg)
    emit_timeframe(fagg)

# One joined string with a trailing newline — matches the win/ port's Out-File.
sys.stdout.write('\n'.join(out) + '\n')
sys.exit(0)
PYEOF
)

exec python3 -c "$PROG" "$@"
