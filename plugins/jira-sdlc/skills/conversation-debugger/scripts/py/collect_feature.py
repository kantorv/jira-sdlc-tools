#!/usr/bin/env python3
"""collect_feature.py <ISSUE-KEY>

Feature-level roll-up collector for conversation-debugger. Where collect_run
profiles ONE transcript, collect_feature profiles a whole FEATURE: it resolves
every conversation that belongs to <ISSUE-KEY> the same way sync_conversations
does (all worktree sessions + the single creating assigner session), runs
collect_run over each, and rolls the measured per-conversation metrics up into
per-feature totals — total token consumption and the union of executing models
across the feature.

TWO FEATURE TYPES (auto-detected from Jira):
  * single-step  — one cohesive issue with its conversations. It has NO
    sub-tasks. Emits the FLAT feature-report@2 JSON.
  * multistep    — a PARENT story with CHILD features (sub-tasks), each child
    with its own conversations. Emits the NESTED feature-report@3 JSON: the
    parent's own conversations, a children[] array (each child carrying its own
    conversations[] + per-child roll-up), and a feature-wide aggregate rolled up
    across the parent AND all children.
Detection is a single Jira fetch (acli jira workitem view <KEY> --json --fields
'summary,subtasks'; key is POSITIONAL, and 'subtasks' must be named explicitly
since the default --json omits it). Non-empty subtasks -> multistep; otherwise
single-step. The acli call is wrapped in a LONG TIMEOUT (the API can legitimately
take minutes); an acli failure/timeout falls back to single-step with a loud WARN
rather than aborting the read-only roll-up.

It reuses the two sibling scripts rather than re-deriving anything:
  * sync_conversations.sh <KEY>  -> the transcript path list (its machine-
    readable "=== attachment paths ===" block) and the grouped human listing.
  * collect_run.sh <skill> <path> -> the already-MEASURED per-conversation
    metrics (KEY=VALUE). No metric is re-estimated here; every number is
    collect_run's own.
The siblings live in ../posix/ by default (this file is the dual-use core
behind the ../posix/collect_feature.sh shim); CF_SCRIPT_DIR overrides the
sibling directory — that is both the historical shim contract and the seam the
golden-file harness uses to substitute stub siblings (../tests/).

OUTPUT — two streams, deliberately split so the pipe stays clean:
  * stdout = the feature-report JSON, and nothing else. This is the machine-
    readable output the report-builder consumes:
        collect_feature.sh JST-93 | feature_report.sh > report.md
    The JSON schema is owned here (see ../../references/feature-report-schema.md);
    the report-builder only reads it.
  * stderr = the human-readable view: sync_conversations' grouped listing plus
    a per-conversation + totals metrics table, so a bare console run shows both
    the listing and the metrics "along" it while stdout stays pipe-safe.

Dual-use core of a posix+win contract pair: ../posix/collect_feature.sh is a
thin shim over this file, and ../win/collect_feature.ps1 is the no-Python
native PowerShell port with the same CLI, JSON/stderr split, and exit codes.

Exit: 0 = JSON emitted (even for a feature with zero conversations)
      1 = usage / environment error, or sync_conversations failed

Side effect: collect_run files each transcript under conversations/<KEY>/ as it
profiles it (that is collect_run's normal behavior); conversations/ is
git-ignored, so this stays local. Nothing is uploaded or posted to Jira.
"""

import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime

ACLI_TIMEOUT_SEC = 300

# Sibling scripts: CF_SCRIPT_DIR (shim contract / harness seam) or ../posix.
SKILL_DIR = os.environ.get('CF_SCRIPT_DIR', '') or os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'posix'))
SYNC_SCRIPT = os.path.join(SKILL_DIR, 'sync_conversations.sh')
COLLECT_RUN = os.path.join(SKILL_DIR, 'collect_run.sh')

# Which of the 3 analyzable skills a transcript invoked. Matches collect_run's
# own acceptance: namespaced (/jira-sdlc:jira-task-x) or bare (/jira-task-x),
# so we never claim a skill collect_run would then reject.
SKILL_RE = re.compile(r'<command-name>/(?:[^<:]*:)?(jira-task-(?:assigner|executor|reviewer))</command-name>')


def note(msg):
    sys.stderr.flush()
    sys.stderr.write(str(msg) + "\n")
    sys.stderr.flush()


def fail(msg):
    note("collect_feature: " + msg)
    sys.exit(1)


# ---- provenance config (worktree vs main-checkout) --------------------------
# Provenance is classified by the same two config folders sync_conversations
# uses, read the same way (env files, not the process env). A path under the
# worktrees prefix is a worktree session; one under the main-repo folder is the
# assigner's.
def git_top():
    try:
        p = subprocess.run(['git', 'rev-parse', '--show-toplevel'],
                           capture_output=True, text=True)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout.strip()
    except Exception:
        pass
    return None


CFG_DIR = git_top() or os.getcwd()


def cfg(pattern):
    for f in ('jira-sdlc-tools.local.env', 'jira-sdlc-tools.env'):
        path = os.path.join(CFG_DIR, f)
        if not os.path.isfile(path):
            continue
        val = None
        try:
            with open(path, encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    m = re.match(r'^\s*(' + pattern + r')\s*=(.*)$', line)
                    if m:
                        val = m.group(2).strip()
        except OSError:
            continue
        if val:
            return val
    return None


WT_PREFIX = cfg('CONVERSATIONS_WORKTREES_PREFIX')
MAIN_FOLDER = cfg('CONVERSATIONS_MAINREPO_PATH')


def provenance(p):
    pl = p.lower()
    if WT_PREFIX and pl.startswith(WT_PREFIX.lower()):
        return 'worktree'
    if MAIN_FOLDER and pl.startswith(MAIN_FOLDER.lower()):
        return 'main-checkout'
    return 'unknown'


# ---- parsers for the sibling scripts' output --------------------------------
def parse_kv(text):
    """collect_run's KEY=VALUE stdout -> dict."""
    h = {}
    for line in text.splitlines():
        m = re.match(r'^([A-Za-z0-9_]+)=(.*)$', line)
        if m:
            h[m.group(1)] = m.group(2)
    return h


def kv_int(h, k):
    try:
        return int(h.get(k, '0'))
    except (ValueError, TypeError):
        return 0


def parse_tally(s):
    """collect_run's tally lines ("Bash:10 Read:7") -> [{'name','calls'}].

    Split on the LAST ':' so a tool name containing ':' can't shift the count.
    """
    items = []
    for part in (s or '').split():
        name, sep, n = part.rpartition(':')
        if not sep or not name:
            continue
        try:
            items.append({'name': name, 'calls': int(n)})
        except ValueError:
            continue
    return items


def invoked_skills(path):
    """The analyzable skills a transcript invoked, in first-seen order."""
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            content = fh.read()
    except OSError:
        return []
    if not content:
        return []
    seen = []
    for m in SKILL_RE.finditer(content):
        n = m.group(1)
        if n not in seen:
            seen.append(n)
    return seen


# ---- resolve + profile one key's conversations ------------------------------
# The single-key collection unit reused by both feature types: run
# sync_conversations for fkey, echo its grouped listing to stderr, then run
# collect_run over each resolved transcript and return one record per
# (conversation, skill). Returns a list (empty on zero conversations).
#
# soft governs a sync_conversations non-zero exit: single-step passes False so a
# sync failure is fatal (unchanged behavior); the multistep parent/children pass
# True so a missing worktree for one part is a NOTE + zero conversations rather
# than aborting the whole feature roll-up.
def run_sync(fkey, soft):
    """Run sync_conversations, echo its human listing, return the path list
    (or None when soft and sync failed)."""
    sys.stderr.flush()
    proc = subprocess.run(['bash', SYNC_SCRIPT, fkey], stdout=subprocess.PIPE,
                          stderr=None, text=True)
    sync_exit = proc.returncode
    sync_out = proc.stdout.splitlines()
    if sync_exit != 0:
        if soft:
            note("collect_feature: sync_conversations.sh %s exited %d -- treating %s as "
                 "contributing zero conversations (see its message above)." % (fkey, sync_exit, fkey))
            return None
        fail("sync_conversations.sh %s failed (exit %d) -- see its message above. "
             "Nothing rolled up." % (fkey, sync_exit))

    # Echo the grouped listing (everything up to the machine block) to stderr, so a
    # console run still shows sync_conversations' familiar view.
    sentinel_idx = -1
    for i, ln in enumerate(sync_out):
        if re.match(r'^=== attachment paths', ln):
            sentinel_idx = i
            break
    note('')
    note("collect_feature: rolling up %s" % fkey)
    for ln in (sync_out[:sentinel_idx] if sentinel_idx >= 0 else sync_out):
        note(ln)

    # The authoritative ordered path list comes from sync_conversations' machine
    # block ("=== attachment paths ==="), not its human listing.
    paths = []
    in_machine = False
    for ln in sync_out:
        if re.match(r'^=== attachment paths', ln):
            in_machine = True
            continue
        if in_machine:
            t = ln.strip()
            if t.endswith('.jsonl'):
                paths.append(t)
    if not paths:
        note("collect_feature: no conversation transcripts resolved for %s -- "
             "contributing an empty roll-up." % fkey)
    return paths


def no_skill_record(uuid, path, prov):
    """A transcript that never invoked an analyzable skill — listed for
    coverage, contributes nothing to any total."""
    return {
        'uuid': uuid, 'transcript': path, 'provenance': prov,
        'skill': None, 'issue_key': None, 'key_status': 'no-skill',
        'models': [],
        'tokens': {'in': 0, 'out': 0, 'cache_read': 0, 'cache_write': 0, 'total': 0},
        'skill_turns': None, 'sidechain_turns': None, 'tool_calls': None,
        'tool_errors': None, 'tools': None, 'wall_clock_s': None,
        'first_ts': None, 'last_ts': None,
        'size_bytes': None,
    }


def collect_run_record(uuid, path, prov, skill, kv):
    """One (conversation, skill) record from collect_run's parsed KEY=VALUE
    output — every metric is collect_run's own, copied verbatim."""
    status = kv.get('KEY_STATUS', 'unknown')
    has_metrics = 'TOKENS_IN' in kv   # metrics block only prints on the expected/given path

    tin = tout = tcr = tcw = 0
    if has_metrics:
        tin = kv_int(kv, 'TOKENS_IN')
        tout = kv_int(kv, 'TOKENS_OUT')
        tcr = kv_int(kv, 'TOKENS_CACHE_READ')
        tcw = kv_int(kv, 'TOKENS_CACHE_WRITE')
    ttot = tin + tout + tcr + tcw

    models = []
    if has_metrics and kv.get('MODELS'):
        models = kv['MODELS'].split()

    wall = None
    if has_metrics and 'WALL_CLOCK_S' in kv:
        try:
            wall = float(kv['WALL_CLOCK_S'])
        except (ValueError, TypeError):
            wall = 0.0

    # Threaded straight from collect_run's TRANSCRIPT_BYTES — never re-measured
    # here (collect_feature owns nothing on disk). Absent (a metric-less record,
    # or an older collect_run) -> None -> '-'.
    size_bytes = kv_int(kv, 'TRANSCRIPT_BYTES') if 'TRANSCRIPT_BYTES' in kv else None

    # Per-tool breakdown: collect_run's TOOLS_USED merged with its
    # TOOL_ERRORS_BY_TOOL (errors are a subset of calls, so the merge never
    # invents a tool). Re-sorted by (-calls, name) so both ports order ties
    # identically regardless of collect_run's own tie order.
    tools = None
    if has_metrics:
        errs_by = {t['name']: t['calls'] for t in parse_tally(kv.get('TOOL_ERRORS_BY_TOOL'))}
        tools = [{'name': t['name'], 'calls': t['calls'],
                  'errors': errs_by.get(t['name'], 0)}
                 for t in parse_tally(kv.get('TOOLS_USED'))]
        tools.sort(key=lambda t: (-t['calls'], t['name']))

    return {
        'uuid': uuid,
        'transcript': path,
        'provenance': prov,
        'skill': skill,
        'issue_key': kv['ISSUE_KEY'] if kv.get('ISSUE_KEY') else None,
        'key_status': status,
        'models': models,
        'tokens': {'in': tin, 'out': tout, 'cache_read': tcr, 'cache_write': tcw, 'total': ttot},
        'skill_turns': kv_int(kv, 'SKILL_TURNS') if has_metrics else None,
        'sidechain_turns': kv_int(kv, 'SIDECHAIN_TURNS') if has_metrics else None,
        'tool_calls': kv_int(kv, 'TOOL_CALLS') if has_metrics else None,
        'tool_errors': kv_int(kv, 'TOOL_ERRORS') if has_metrics else None,
        'tools': tools,
        'wall_clock_s': wall,
        'first_ts': kv['FIRST_TS'] if (has_metrics and kv.get('FIRST_TS')) else None,
        'last_ts': kv['LAST_TS'] if (has_metrics and kv.get('LAST_TS')) else None,
        'size_bytes': size_bytes,
    }


def feature_records(fkey, soft):
    records = []
    paths = run_sync(fkey, soft)
    if paths is None:
        return records

    for path in paths:
        prov = provenance(path)
        uuid = os.path.splitext(os.path.basename(path))[0]
        skills = invoked_skills(path)

        if not skills:
            note("collect_feature: %s invoked no analyzable skill -- recorded without metrics." % uuid)
            records.append(no_skill_record(uuid, path, prov))
            continue

        for skill in skills:
            sys.stderr.flush()
            cr = subprocess.run(['bash', COLLECT_RUN, skill, path], stdout=subprocess.PIPE,
                                stderr=None, text=True)
            if cr.returncode == 1:
                note("collect_feature: collect_run.sh %s %s hard-failed (exit 1) -- skipped. "
                     "See its message above." % (skill, uuid))
                continue
            records.append(collect_run_record(uuid, path, prov, skill, parse_kv(cr.stdout)))
    return records


# ---- aggregate: sum measured tokens, union models / skills / keys ------------
# Token/turn/tool sums and the per-skill / per-provenance roll-ups are all over
# ANALYZED records only (key_status expected/given) — a metric-less record
# contributes nothing to a total but still appears in the per-conversation
# listings for coverage. Every number here is a plain sum / min / max of
# collect_run's own measured values (span_s the one subtraction). Reused verbatim
# for the single-step aggregate, each multistep child's per-child roll-up, and the
# multistep feature-wide aggregate — one function, as the schema promises.
def parse_iso(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.strip().replace('Z', '+00:00'))
    except Exception:
        return None


def token_acc():
    return {'conversations': 0, 'in': 0, 'out': 0, 'cache_read': 0, 'cache_write': 0, 'total': 0}


def add_to_acc(a, r):
    a['conversations'] += 1
    a['in'] += int(r['tokens']['in'])
    a['out'] += int(r['tokens']['out'])
    a['cache_read'] += int(r['tokens']['cache_read'])
    a['cache_write'] += int(r['tokens']['cache_write'])
    a['total'] += int(r['tokens']['total'])


def union_sets(records):
    """models / skills / issue_keys unions — over ALL records (a metric-less
    record still names its skill and any recovered key), first-seen order."""
    mdl_set = []
    skl_set = []
    key_set = []
    for r in records:
        for m in r['models']:
            if m and m not in mdl_set:
                mdl_set.append(m)
        if r['skill'] and r['skill'] not in skl_set:
            skl_set.append(r['skill'])
        if r['issue_key'] and r['issue_key'] not in key_set:
            key_set.append(r['issue_key'])
    return mdl_set, skl_set, key_set


def group_tokens(analyzed, field, default, label):
    """Per-<field> token roll-up (by_skill / by_provenance), first-seen order."""
    table = {}
    order = []
    for r in analyzed:
        k = r[field] if r[field] else default
        if k not in table:
            table[k] = token_acc()
            order.append(k)
        add_to_acc(table[k], r)
    out = []
    for k in order:
        a = table[k]
        out.append({label: k, 'conversations': a['conversations'],
                    'tokens': {'in': a['in'], 'out': a['out'], 'cache_read': a['cache_read'],
                               'cache_write': a['cache_write'], 'total': a['total']}})
    return out


def group_tools(analyzed):
    """Per-tool roll-up over analyzed records, (-calls, name) like the
    per-record tools list — a deterministic order both ports produce
    identically."""
    by_tool = {}
    for r in analyzed:
        for t in (r.get('tools') or []):
            e = by_tool.setdefault(t['name'], {'conversations': 0, 'calls': 0, 'errors': 0})
            e['conversations'] += 1
            e['calls'] += int(t['calls'])
            e['errors'] += int(t.get('errors') or 0)
    arr = [{'tool': k, 'conversations': v['conversations'],
            'calls': v['calls'], 'errors': v['errors']}
           for k, v in by_tool.items()]
    arr.sort(key=lambda t: (-t['calls'], t['tool']))
    return arr


def timeframe(analyzed):
    """Earliest first_ts, latest last_ts, and the span between them."""
    min_first = max_last = None
    min_first_str = max_last_str = None
    for r in analyzed:
        f = parse_iso(r['first_ts'])
        if f is not None and (min_first is None or f < min_first):
            min_first = f
            min_first_str = r['first_ts']
        last = parse_iso(r['last_ts'])
        if last is not None and (max_last is None or last > max_last):
            max_last = last
            max_last_str = r['last_ts']
    span_s = None
    if min_first is not None and max_last is not None:
        span_s = round((max_last - min_first).total_seconds(), 1)
    return {'first_ts': min_first_str, 'last_ts': max_last_str, 'span_s': span_s}


def new_aggregate(records):
    analyzed = [r for r in records if r['key_status'] in ('expected', 'given')]
    mdl_set, skl_set, key_set = union_sets(records)

    ag_in = sum(int(r['tokens']['in']) for r in analyzed)
    ag_out = sum(int(r['tokens']['out']) for r in analyzed)
    ag_cr = sum(int(r['tokens']['cache_read']) for r in analyzed)
    ag_cw = sum(int(r['tokens']['cache_write']) for r in analyzed)

    return {
        'conversation_count': len(records),
        'analyzed_count': len(analyzed),
        'tokens': {'in': ag_in, 'out': ag_out, 'cache_read': ag_cr, 'cache_write': ag_cw,
                   'total': ag_in + ag_out + ag_cr + ag_cw},
        'skill_turns': sum(int(r['skill_turns'] or 0) for r in analyzed),
        'sidechain_turns': sum(int(r['sidechain_turns'] or 0) for r in analyzed),
        'tool_calls': sum(int(r['tool_calls'] or 0) for r in analyzed),
        'tool_errors': sum(int(r['tool_errors'] or 0) for r in analyzed),
        'timeframe': timeframe(analyzed),
        # models / issue_keys mirror the win/ port's `[string[]]($set | Sort-Object)`:
        # piping an empty set through Sort-Object yields $null, so an empty roll-up
        # serializes these two as null (not []). skills is a direct `[string[]]$set`
        # cast (no pipe), so it stays [] when empty — hence the asymmetry.
        'models': sorted(mdl_set) if mdl_set else None,
        'skills': skl_set,
        'issue_keys': sorted(key_set) if key_set else None,
        'by_skill': group_tokens(analyzed, 'skill', '(no skill)', 'skill'),
        'by_provenance': group_tokens(analyzed, 'provenance', 'unknown', 'provenance'),
        'by_tool': group_tools(analyzed),
    }


# ---- human-readable stderr metrics view (per part) --------------------------
# Not part of the JSON contract or the no-regression byte check (only stdout JSON
# and the rendered markdown are) — a plain console view of one part's records +
# its aggregate. Reused for single-step, the multistep parent, and each child.
def fmt(n):
    if n is None:
        return '-'
    return "{:,}".format(int(n))


def write_human_part(heading, records, agg):
    note('')
    note("### %s" % heading)
    note("  conversations: %d   analyzed (with metrics): %d" % (len(records), agg['analyzed_count']))
    for r in records:
        sk = r['skill'] if r['skill'] else '(no skill)'
        note("  * %s  [%s]  %s  key=%s (%s)" % (
            r['uuid'], r['provenance'], sk, (r['issue_key'] if r['issue_key'] else '-'), r['key_status']))
        note("      models: %s" % (', '.join(r['models']) if r['models'] else '-'))
        note("      tokens  in=%s  out=%s  cache-read=%s  cache-write=%s  total=%s" % (
            fmt(r['tokens']['in']), fmt(r['tokens']['out']), fmt(r['tokens']['cache_read']),
            fmt(r['tokens']['cache_write']), fmt(r['tokens']['total'])))
        wall = ("{:,.1f}".format(r['wall_clock_s']) if r['wall_clock_s'] is not None else '-')
        note("      perf    turns=%s  sidechain=%s  tool-calls=%s (errors=%s)  elapsed=%ss" % (
            fmt(r['skill_turns']), fmt(r['sidechain_turns']), fmt(r['tool_calls']),
            fmt(r['tool_errors']), wall))
        if r.get('tools'):
            note("      tools   %s" % ', '.join("%s:%d" % (t['name'], t['calls']) for t in r['tools']))


def write_human_totals(label, agg):
    note('')
    note("  === %s ===" % label)
    note("  tokens  in=%s  out=%s  cache-read=%s  cache-write=%s" % (
        fmt(agg['tokens']['in']), fmt(agg['tokens']['out']),
        fmt(agg['tokens']['cache_read']), fmt(agg['tokens']['cache_write'])))
    note("  TOTAL token consumption: %s" % fmt(agg['tokens']['total']))
    note("  perf    skill-turns=%s  sidechain-turns=%s  tool-calls=%s  tool-errors=%s" % (
        fmt(agg['skill_turns']), fmt(agg['sidechain_turns']), fmt(agg['tool_calls']), fmt(agg['tool_errors'])))
    span = ("  (span %ss)" % fmt(agg['timeframe']['span_s'])) if agg['timeframe']['span_s'] is not None else ''
    note("  activity: %s -> %s%s" % (
        agg['timeframe']['first_ts'] if agg['timeframe']['first_ts'] else '-',
        agg['timeframe']['last_ts'] if agg['timeframe']['last_ts'] else '-', span))
    note("  models: %s" % (', '.join(agg['models']) if agg['models'] else '-'))
    note("  skills: %s" % (', '.join(agg['skills']) if agg['skills'] else '-'))
    if agg.get('by_tool'):
        note("  tools:  %s" % ', '.join("%s:%d" % (t['tool'], t['calls']) for t in agg['by_tool']))


# ---- detect feature type: does <KEY> have sub-tasks? ------------------------
# One Jira fetch, wrapped in a LONG TIMEOUT (the API can legitimately take
# minutes). A timeout or any acli failure falls back to single-step with a loud
# WARN rather than aborting a read-only report. `subtasks` must be named
# explicitly in --fields since the default --json omits it.
def get_subtasks(fkey):
    result = {'ok': False, 'summary': '', 'subtasks': []}
    if not shutil.which('acli'):
        note("collect_feature: acli not found -- cannot detect sub-tasks; treating %s as single-step." % fkey)
        return result
    try:
        p = subprocess.run(['acli', 'jira', 'workitem', 'view', fkey, '--json', '--fields', 'summary,subtasks'],
                           capture_output=True, text=True, timeout=ACLI_TIMEOUT_SEC)
        raw = p.stdout
    except subprocess.TimeoutExpired:
        note("collect_feature: acli sub-task lookup for %s timed out after %ds -- treating as single-step." % (fkey, ACLI_TIMEOUT_SEC))
        return result
    except Exception as e:
        note("collect_feature: acli sub-task lookup for %s failed (%s) -- treating as single-step." % (fkey, e))
        return result
    if not raw or not raw.strip():
        return result
    # acli may print leading non-JSON lines; jump to the first '{'.
    brace = raw.find('{')
    if brace < 0:
        return result
    try:
        obj = json.loads(raw[brace:])
    except Exception:
        note("collect_feature: acli sub-task lookup for %s returned unparseable JSON -- treating as single-step." % fkey)
        return result
    fields = obj.get('fields') if obj.get('fields') is not None else obj
    result['ok'] = True
    fsum = fields.get('summary')
    result['summary'] = '' if fsum is None else str(fsum)
    subs = []
    for s in (fields.get('subtasks') or []):
        ssum = None
        if s.get('fields') is not None:
            v = (s.get('fields') or {}).get('summary')
            ssum = '' if v is None else str(v)
        subs.append({'key': s.get('key'), 'summary': ssum})
    result['subtasks'] = subs
    return result


# ---- emit: one path per feature type ----------------------------------------
def emit_json(root):
    sys.stdout.write(json.dumps(root, indent=2, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def emit_single_step(key):
    """No sub-tasks — flat feature-report@2."""
    records = feature_records(key, False)
    agg = new_aggregate(records)

    emit_json({
        'schema': 'jira-sdlc/conversation-debugger/feature-report@2',
        'feature': key,
        'conversation_count': len(records),
        'conversations': records,
        'aggregate': agg,
    })
    write_human_part("Feature roll-up — %s" % key, records, agg)
    write_human_totals('feature totals', agg)


def emit_multistep(key, detect):
    """Parent story + child sub-tasks — nested feature-report@3."""
    note('')
    note("collect_feature: %s is a MULTISTEP parent (%d sub-task(s): %s) -- emitting nested feature-report@3." % (
        key, len(detect['subtasks']), ', '.join(s['key'] for s in detect['subtasks'])))

    # Parent's own conversations (the assigner session that created the feature,
    # plus any sessions under the parent's own worktree). Soft: a parent with no
    # worktree contributes zero rather than aborting the feature.
    parent_records = feature_records(key, True)

    # Dedup by transcript path, PARENT-PRIORITY. A multistep assigner session
    # (main-checkout) mentions the parent AND every sub-task key, so it is resolved
    # for each — attribute it to the parent (its true owner) and drop it from any
    # child, so its tokens are counted exactly once feature-wide. Worktree sessions
    # are folder-scoped per key and never overlap; only the assigner session does.
    seen = {}
    for r in parent_records:
        seen[str(r['transcript']).lower()] = True

    children_arr = []
    for sub in detect['subtasks']:
        child_kept = []
        for r in feature_records(sub['key'], True):
            tp = str(r['transcript']).lower()
            if tp in seen:
                note("collect_feature: %s already attributed (parent or an earlier child) -- "
                     "not double-counting under %s." % (r['uuid'], sub['key']))
                continue
            seen[tp] = True
            child_kept.append(r)
        child_agg = new_aggregate(child_kept)
        children_arr.append({
            'key': sub['key'],
            'summary': sub['summary'],
            'conversation_count': len(child_kept),
            'conversations': child_kept,
            'aggregate': child_agg,
        })
        heading = "Child feature — %s%s" % (sub['key'], (" (%s)" % sub['summary']) if sub['summary'] else '')
        write_human_part(heading, child_kept, child_agg)
        write_human_totals("child %s totals" % sub['key'], child_agg)

    # Feature-wide aggregate = parent's own records + every child's (deduped) records.
    all_records = list(parent_records)
    for c in children_arr:
        all_records.extend(c['conversations'])
    feature_agg = new_aggregate(all_records)
    parent_agg = new_aggregate(parent_records)

    emit_json({
        'schema': 'jira-sdlc/conversation-debugger/feature-report@3',
        'feature': key,
        'feature_type': 'multistep',
        'parent': {
            'key': key,
            'summary': detect['summary'],
            'conversation_count': len(parent_records),
            'conversations': parent_records,
            'aggregate': parent_agg,
        },
        'children': children_arr,
        'conversation_count': len(all_records),
        'aggregate': feature_agg,
    })

    # stderr: parent view then feature totals (children already printed)
    write_human_part("Parent (own conversations) — %s%s" % (key, (" (%s)" % detect['summary']) if detect['summary'] else ''),
                     parent_records, parent_agg)
    write_human_totals("FEATURE-WIDE totals — %s (parent + %d child feature(s))" % (key, len(children_arr)), feature_agg)


def main(argv):
    key = argv[0] if argv else ''
    if not re.match(r'^[A-Za-z]+-[0-9]+$', key):
        fail("need an issue key, e.g. collect_feature.sh JST-93 (got '%s')" % (key if key else '<none>'))

    if not os.path.isfile(SYNC_SCRIPT):
        fail("sibling sync_conversations.sh not found at %s" % SYNC_SCRIPT)
    if not os.path.isfile(COLLECT_RUN):
        fail("sibling collect_run.sh not found at %s" % COLLECT_RUN)

    detect = get_subtasks(key)
    if len(detect['subtasks']) == 0:
        emit_single_step(key)
    else:
        emit_multistep(key, detect)
    sys.exit(0)


if __name__ == '__main__':
    main(sys.argv[1:])
