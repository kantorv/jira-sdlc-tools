# collect_feature.ps1 <ISSUE-KEY>
#
# Feature-level roll-up collector for conversation-debugger. Where collect_run
# profiles ONE transcript, collect_feature profiles a whole FEATURE: it resolves
# every conversation that belongs to <ISSUE-KEY> the same way sync_conversations
# does (all worktree sessions + the single creating assigner session), runs
# collect_run over each, and rolls the measured per-conversation metrics up into
# per-feature totals — total token consumption and the union of executing models
# across the feature.
#
# TWO FEATURE TYPES (auto-detected from Jira):
#   * single-step  — one cohesive issue with its conversations. It has NO
#     sub-tasks. Emits the FLAT feature-report@2 JSON (unchanged behavior).
#   * multistep    — a PARENT story with CHILD features (sub-tasks), each child
#     with its own conversations. Emits the NESTED feature-report@3 JSON: the
#     parent's own conversations, a children[] array (each child carrying its own
#     conversations[] + per-child roll-up), and a feature-wide aggregate rolled up
#     across the parent AND all children.
# Detection is a single Jira fetch (acli jira workitem view <KEY> --json --fields
# 'summary,subtasks'; key is POSITIONAL, and 'subtasks' must be named explicitly
# since the default --json omits it). Non-empty subtasks -> multistep; otherwise
# single-step. The acli call is wrapped in a LONG TIMEOUT (the API can legitimately
# take minutes); an acli failure/timeout falls back to single-step with a loud WARN
# rather than aborting the read-only roll-up.
#
# It reuses the two sibling scripts rather than re-deriving anything:
#   * sync_conversations.ps1 <KEY>  -> the transcript path list (its machine-
#     readable "=== attachment paths ===" block) and the grouped human listing.
#   * collect_run.ps1 <skill> <path> -> the already-MEASURED per-conversation
#     metrics (KEY=VALUE). No metric is re-estimated here; every number is
#     collect_run's own.
#
# OUTPUT — two streams, deliberately split so the pipe stays clean:
#   * stdout = the feature-report JSON, and nothing else. This is the machine-
#     readable output the report-builder consumes:
#         collect_feature.ps1 JST-93 | feature_report.ps1 > report.md
#     The JSON schema is owned here (see references/feature-report-schema.md);
#     the report-builder only reads it.
#   * stderr = the human-readable view: sync_conversations' grouped listing plus
#     a per-conversation + totals metrics table, so a bare console run shows both
#     the listing and the metrics "along" it while stdout stays pipe-safe.
#
# This is the Windows (PowerShell 5.1+) half of a posix+win contract pair; the
# POSIX twin (../posix/collect_feature.sh) is a full bash+jq+python3 port with the
# same CLI, JSON/stderr split, and exit codes. Callers dispatch by their runtime.
#
# Exit: 0 = JSON emitted (even for a feature with zero conversations)
#       1 = usage / environment error, or sync_conversations failed
#
# Side effect: collect_run files each transcript under conversations/<KEY>/ as it
# profiles it (that is collect_run's normal behavior); conversations/ is
# git-ignored, so this stays local. Nothing is uploaded or posted to Jira.

$ErrorActionPreference = 'Stop'

function Note([string]$msg) { [Console]::Error.WriteLine($msg) }
function Fail([string]$msg) { [Console]::Error.WriteLine("collect_feature: $msg"); exit 1 }

# ---- arguments --------------------------------------------------------------
$Key = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
if ($Key -notmatch '^[A-Za-z]+-[0-9]+$') {
    $got = if ($Key) { $Key } else { '<none>' }
    Fail "need an issue key, e.g. collect_feature.ps1 JST-93 (got '$got')"
}

# ---- sibling scripts (same win/ folder) -------------------------------------
$SyncScript = Join-Path $PSScriptRoot 'sync_conversations.ps1'
$CollectRun = Join-Path $PSScriptRoot 'collect_run.ps1'
if (-not (Test-Path -LiteralPath $SyncScript)) { Fail "sibling sync_conversations.ps1 not found at $SyncScript" }
if (-not (Test-Path -LiteralPath $CollectRun)) { Fail "sibling collect_run.ps1 not found at $CollectRun" }

# ---- provenance config (worktree vs main-checkout) --------------------------
# Provenance is classified by the same two config folders sync_conversations uses —
# read the same way (env files, not $env), rather than scraping sync's human
# formatting. A path under the worktrees prefix is a worktree session; one under
# the main-repo folder is the assigner's.
function Get-GitTop {
    try { $t = (& git rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -eq 0 -and $t) { return ([string]$t).Trim() } } catch { }
    return $null
}
$CfgDir = Get-GitTop
if (-not $CfgDir) { $CfgDir = (Get-Location).Path }
function Get-Cfg([string]$Pattern) {
    foreach ($f in @('jira-sdlc-tools.local.env', 'jira-sdlc-tools.env')) {
        $path = Join-Path $CfgDir $f
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $val = $null
        foreach ($line in Get-Content -LiteralPath $path) {
            if ($line -match "^\s*($Pattern)\s*=(.*)$") { $val = $Matches[2].Trim() }
        }
        if ($val) { return $val }
    }
    return $null
}
$WtPrefix   = Get-Cfg 'CONVERSATIONS_WORKTREES_PREFIX'
$MainFolder = Get-Cfg 'CONVERSATIONS_MAINREPO_PATH'
function Get-Provenance([string]$p) {
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    if ($WtPrefix -and $p.StartsWith($WtPrefix, $cmp)) { return 'worktree' }
    if ($MainFolder -and $p.StartsWith($MainFolder, $cmp)) { return 'main-checkout' }
    return 'unknown'
}

# ---- KEY=VALUE parser for collect_run output --------------------------------
function ConvertFrom-Kv($lines) {
    $h = @{}
    foreach ($l in $lines) {
        $m = [regex]::Match([string]$l, '^([A-Za-z0-9_]+)=(.*)$')
        if ($m.Success) { $h[$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    return $h
}
function Get-KvInt($h, $k) { $v = 0; if ($h.ContainsKey($k)) { [void][int]::TryParse($h[$k], [ref]$v) }; return $v }

# collect_run's tally lines ("Bash:10 Read:7") -> records of name/calls. Split
# on the LAST ':' so a tool name containing ':' can't shift the count.
function ConvertFrom-Tally([string]$s) {
    $items = New-Object System.Collections.Generic.List[object]
    if (-not $s) { return ,$items }
    foreach ($part in ($s -split '\s+' | Where-Object { $_ })) {
        $idx = $part.LastIndexOf(':')
        if ($idx -le 0) { continue }
        $n = 0L
        if (-not [long]::TryParse($part.Substring($idx + 1), [ref]$n)) { continue }
        $items.Add([pscustomobject]@{ name = $part.Substring(0, $idx); calls = $n })
    }
    return ,$items
}

# Which of the 3 analyzable skills a transcript invoked, in first-seen order.
# Matches collect_run's own acceptance: namespaced (/jira-sdlc:jira-task-x) or
# bare (/jira-task-x), so we never claim a skill collect_run would then reject.
function Get-InvokedSkills([string]$path) {
    $content = $null
    try { $content = [System.IO.File]::ReadAllText($path) } catch { return @() }
    if (-not $content) { return @() }
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($content, '<command-name>/(?:[^<:]*:)?(jira-task-(?:assigner|executor|reviewer))</command-name>')) {
        $name = $m.Groups[1].Value
        if (-not $seen.Contains($name)) { $seen.Add($name) }
    }
    return @($seen)
}

# ---- resolve + profile one key's conversations ------------------------------
# The single-key collection unit reused by both feature types: run
# sync_conversations for $FKey, echo its grouped listing to stderr, then run
# collect_run over each resolved transcript and return one record per
# (conversation, skill). Returns a List[object] (empty on zero conversations).
#
# $Soft governs a sync_conversations non-zero exit: single-step passes $false so a
# sync failure is fatal (unchanged behavior); the multistep parent/children pass
# $true so a missing worktree for one part is a NOTE + zero conversations rather
# than aborting the whole feature roll-up.
function Get-FeatureRecords {
    param([string]$FKey, [bool]$Soft)
    $records = New-Object System.Collections.Generic.List[object]

    $syncOut = & $SyncScript $FKey
    $syncExit = $LASTEXITCODE
    if ($syncExit -ne 0) {
        if ($Soft) {
            Note "collect_feature: sync_conversations.ps1 $FKey exited $syncExit -- treating $FKey as contributing zero conversations (see its message above)."
            return ,$records
        }
        Fail "sync_conversations.ps1 $FKey failed (exit $syncExit) -- see its message above. Nothing rolled up."
    }

    # Echo the grouped listing (everything up to the machine block) to stderr, so a
    # console run still shows sync_conversations' familiar view.
    $sentinelIdx = -1
    for ($i = 0; $i -lt $syncOut.Count; $i++) {
        if ([string]$syncOut[$i] -match '^=== attachment paths') { $sentinelIdx = $i; break }
    }
    Note ''
    Note "collect_feature: rolling up $FKey"
    if ($sentinelIdx -ge 0) {
        for ($i = 0; $i -lt $sentinelIdx; $i++) { Note ([string]$syncOut[$i]) }
    } else {
        foreach ($l in $syncOut) { Note ([string]$l) }
    }

    # The authoritative ordered path list comes from sync_conversations' machine
    # block ("=== attachment paths ==="), not its human listing.
    $paths = New-Object System.Collections.Generic.List[string]
    $inMachine = $false
    foreach ($lnRaw in $syncOut) {
        $ln = [string]$lnRaw
        if ($ln -match '^=== attachment paths') { $inMachine = $true; continue }
        if ($inMachine) {
            $t = $ln.Trim()
            if ($t -match '\.jsonl$') { $paths.Add($t) }
        }
    }
    if ($paths.Count -eq 0) {
        Note "collect_feature: no conversation transcripts resolved for $FKey -- contributing an empty roll-up."
    }

    foreach ($path in $paths) {
        $provenance = Get-Provenance $path
        $uuid = [System.IO.Path]::GetFileNameWithoutExtension($path)
        $skills = Get-InvokedSkills $path

        if ($skills.Count -eq 0) {
            Note "collect_feature: $uuid invoked no analyzable skill -- recorded without metrics."
            $records.Add([ordered]@{
                uuid = $uuid; transcript = $path; provenance = $provenance
                skill = $null; issue_key = $null; key_status = 'no-skill'
                models = @(); tokens = [ordered]@{ in = 0; out = 0; cache_read = 0; cache_write = 0; total = 0 }
                skill_turns = $null; sidechain_turns = $null; tool_calls = $null; tool_errors = $null
                tools = $null; wall_clock_s = $null; first_ts = $null; last_ts = $null
                size_bytes = $null
            })
            continue
        }

        foreach ($skill in $skills) {
            $crOut = & $CollectRun $skill $path
            $crExit = $LASTEXITCODE
            if ($crExit -eq 1) {
                Note "collect_feature: collect_run.ps1 $skill $uuid hard-failed (exit 1) -- skipped. See its message above."
                continue
            }
            $kv = ConvertFrom-Kv $crOut
            $status = if ($kv.ContainsKey('KEY_STATUS')) { $kv['KEY_STATUS'] } else { 'unknown' }
            $hasMetrics = $kv.ContainsKey('TOKENS_IN')   # metrics block only prints on the expected/given path

            $tin = 0L; $tout = 0L; $tcr = 0L; $tcw = 0L
            if ($hasMetrics) {
                [void][long]::TryParse($kv['TOKENS_IN'], [ref]$tin)
                [void][long]::TryParse($kv['TOKENS_OUT'], [ref]$tout)
                [void][long]::TryParse($kv['TOKENS_CACHE_READ'], [ref]$tcr)
                [void][long]::TryParse($kv['TOKENS_CACHE_WRITE'], [ref]$tcw)
            }
            $ttot = $tin + $tout + $tcr + $tcw

            $models = @()
            if ($hasMetrics -and $kv['MODELS']) { $models = @($kv['MODELS'] -split '\s+' | Where-Object { $_ }) }

            $wall = $null
            if ($hasMetrics -and $kv.ContainsKey('WALL_CLOCK_S')) { $w = 0.0; [void][double]::TryParse($kv['WALL_CLOCK_S'], [ref]$w); $wall = $w }

            # Threaded straight from collect_run's TRANSCRIPT_BYTES — never
            # re-measured here (collect_feature owns nothing on disk). Absent
            # (a metric-less record, or an older collect_run) -> $null -> '-'.
            $sizeBytes = $null
            if ($kv.ContainsKey('TRANSCRIPT_BYTES')) { $sb = 0L; [void][long]::TryParse($kv['TRANSCRIPT_BYTES'], [ref]$sb); $sizeBytes = $sb }

            # Per-tool breakdown: collect_run's TOOLS_USED merged with its
            # TOOL_ERRORS_BY_TOOL (errors are a subset of calls, so the merge
            # never invents a tool). Re-sorted by (-calls, name) so both ports
            # order ties identically regardless of collect_run's own tie order.
            $tools = $null
            if ($hasMetrics) {
                $errsBy = @{}
                foreach ($t in (ConvertFrom-Tally $kv['TOOL_ERRORS_BY_TOOL'])) { $errsBy[$t.name] = $t.calls }
                $toolsList = @(foreach ($t in (ConvertFrom-Tally $kv['TOOLS_USED'])) {
                    $e = if ($errsBy.ContainsKey($t.name)) { [long]$errsBy[$t.name] } else { 0L }
                    [ordered]@{ name = $t.name; calls = $t.calls; errors = $e }
                })
                $tools = [object[]]@($toolsList | Sort-Object -Property @{Expression = { [long]$_.calls }; Descending = $true }, @{Expression = { [string]$_.name }; Descending = $false })
            }

            $records.Add([ordered]@{
                uuid        = $uuid
                transcript  = $path
                provenance  = $provenance
                skill       = $skill
                issue_key   = if ($kv.ContainsKey('ISSUE_KEY') -and $kv['ISSUE_KEY']) { $kv['ISSUE_KEY'] } else { $null }
                key_status  = $status
                models      = $models
                tokens      = [ordered]@{ in = $tin; out = $tout; cache_read = $tcr; cache_write = $tcw; total = $ttot }
                skill_turns    = if ($hasMetrics) { Get-KvInt $kv 'SKILL_TURNS' } else { $null }
                sidechain_turns = if ($hasMetrics) { Get-KvInt $kv 'SIDECHAIN_TURNS' } else { $null }
                tool_calls     = if ($hasMetrics) { Get-KvInt $kv 'TOOL_CALLS' } else { $null }
                tool_errors    = if ($hasMetrics) { Get-KvInt $kv 'TOOL_ERRORS' } else { $null }
                tools          = $tools
                wall_clock_s   = $wall
                first_ts    = if ($hasMetrics -and $kv['FIRST_TS']) { $kv['FIRST_TS'] } else { $null }
                last_ts     = if ($hasMetrics -and $kv['LAST_TS'])  { $kv['LAST_TS'] }  else { $null }
                size_bytes  = $sizeBytes
            })
        }
    }
    return ,$records
}

# ---- aggregate: sum measured tokens, union models / skills / keys ------------
# Token/turn/tool sums and the per-skill / per-provenance roll-ups are all over
# ANALYZED records only (key_status expected/given) — a metric-less record
# contributes nothing to a total but still appears in the per-conversation
# listings for coverage. Every number here is a plain sum / min / max of
# collect_run's own measured values; the report-builder renders these, it never
# recomputes them (span_s is the one derived value — a subtraction of two measured
# timestamps, kept here so the report stays a pure renderer). Reused verbatim for
# the single-step aggregate, each multistep child's per-child roll-up, and the
# multistep feature-wide aggregate — the "same shape as today's aggregate" the
# schema promises is literally one function.
function New-TokenAcc { return [ordered]@{ conversations = 0; in = 0L; out = 0L; cache_read = 0L; cache_write = 0L; total = 0L } }
function Add-ToTokenAcc($acc, $r) {
    $acc.conversations++
    $acc.in += [long]$r.tokens.in; $acc.out += [long]$r.tokens.out
    $acc.cache_read += [long]$r.tokens.cache_read; $acc.cache_write += [long]$r.tokens.cache_write
    $acc.total += [long]$r.tokens.total
}
function New-Aggregate {
    param($Records)
    $agIn = 0L; $agOut = 0L; $agCr = 0L; $agCw = 0L
    $agTurns = 0L; $agSide = 0L; $agCalls = 0L; $agErrs = 0L
    $mdlSet = New-Object System.Collections.Generic.List[string]
    $sklSet = New-Object System.Collections.Generic.List[string]
    $keySet = New-Object System.Collections.Generic.List[string]
    $bySkill = [ordered]@{}   # skill -> token accumulator
    $byProv  = [ordered]@{}   # provenance -> token accumulator
    $byTool  = [ordered]@{}   # tool name -> conversations/calls/errors accumulator
    $minFirst = $null; $maxLast = $null; $minFirstStr = $null; $maxLastStr = $null
    $analyzed = 0

    foreach ($r in $Records) {
        foreach ($m in $r.models) { if ($m -and -not $mdlSet.Contains($m)) { $mdlSet.Add($m) } }
        if ($r.skill -and -not $sklSet.Contains($r.skill)) { $sklSet.Add($r.skill) }
        if ($r.issue_key -and -not $keySet.Contains($r.issue_key)) { $keySet.Add($r.issue_key) }

        if ($r.key_status -ne 'expected' -and $r.key_status -ne 'given') { continue }
        $analyzed++
        $agIn += [long]$r.tokens.in; $agOut += [long]$r.tokens.out
        $agCr += [long]$r.tokens.cache_read; $agCw += [long]$r.tokens.cache_write
        $agTurns += [long]$r.skill_turns; $agSide += [long]$r.sidechain_turns
        $agCalls += [long]$r.tool_calls;  $agErrs += [long]$r.tool_errors

        $sk = if ($r.skill) { $r.skill } else { '(no skill)' }
        if (-not $bySkill.Contains($sk)) { $bySkill[$sk] = New-TokenAcc }
        Add-ToTokenAcc $bySkill[$sk] $r

        $pv = if ($r.provenance) { $r.provenance } else { 'unknown' }
        if (-not $byProv.Contains($pv)) { $byProv[$pv] = New-TokenAcc }
        Add-ToTokenAcc $byProv[$pv] $r

        foreach ($t in @($r.tools)) {
            if ($null -eq $t) { continue }
            $tn = [string]$t.name
            if (-not $byTool.Contains($tn)) { $byTool[$tn] = [ordered]@{ conversations = 0; calls = 0L; errors = 0L } }
            $byTool[$tn].conversations++
            $byTool[$tn].calls += [long]$t.calls
            $byTool[$tn].errors += [long]$t.errors
        }

        # timeframe: earliest first_ts, latest last_ts across the feature (UTC ISO-8601)
        if ($r.first_ts) { try { $f = [datetimeoffset]::Parse($r.first_ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal); if ($null -eq $minFirst -or $f -lt $minFirst) { $minFirst = $f; $minFirstStr = $r.first_ts } } catch { } }
        if ($r.last_ts)  { try { $l = [datetimeoffset]::Parse($r.last_ts,  [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal); if ($null -eq $maxLast  -or $l -gt $maxLast)  { $maxLast  = $l; $maxLastStr  = $r.last_ts } } catch { } }
    }
    $agTot = $agIn + $agOut + $agCr + $agCw
    $spanS = $null
    if ($null -ne $minFirst -and $null -ne $maxLast) { $spanS = [math]::Round(($maxLast - $minFirst).TotalSeconds, 1) }

    # ordered-dict roll-ups -> arrays of records for the JSON (@() so 0/1 entries
    # still serialize as an array, not null / a bare object)
    $bySkillArr = @(foreach ($k in $bySkill.Keys) {
        $a = $bySkill[$k]
        [ordered]@{ skill = $k; conversations = $a.conversations
            tokens = [ordered]@{ in = $a.in; out = $a.out; cache_read = $a.cache_read; cache_write = $a.cache_write; total = $a.total } }
    })
    $byProvArr = @(foreach ($k in $byProv.Keys) {
        $b = $byProv[$k]
        [ordered]@{ provenance = $k; conversations = $b.conversations
            tokens = [ordered]@{ in = $b.in; out = $b.out; cache_read = $b.cache_read; cache_write = $b.cache_write; total = $b.total } }
    })
    # per-tool roll-up over analyzed records, (-calls, name) like the per-record
    # tools list — a deterministic order both ports produce identically
    $byToolArr = @(foreach ($k in $byTool.Keys) {
        $t = $byTool[$k]
        [ordered]@{ tool = $k; conversations = $t.conversations; calls = $t.calls; errors = $t.errors }
    })
    $byToolArr = [object[]]@($byToolArr | Sort-Object -Property @{Expression = { [long]$_.calls }; Descending = $true }, @{Expression = { [string]$_.tool }; Descending = $false })

    # NB: $Records.Count, never @($Records).Count — @() on a System.Collections.
    # Generic.List[object] throws "Argument types do not match" on PowerShell 7,
    # while .Count and the [object[]] casts below are fine. Callers always pass a
    # List, so .Count is both correct and safe.
    return [ordered]@{
        conversation_count = $Records.Count
        analyzed_count     = $analyzed
        tokens  = [ordered]@{ in = $agIn; out = $agOut; cache_read = $agCr; cache_write = $agCw; total = $agTot }
        skill_turns     = $agTurns
        sidechain_turns = $agSide
        tool_calls      = $agCalls
        tool_errors     = $agErrs
        timeframe = [ordered]@{ first_ts = $minFirstStr; last_ts = $maxLastStr; span_s = $spanS }
        models  = [string[]]($mdlSet | Sort-Object)
        skills  = [string[]]$sklSet
        issue_keys = [string[]]($keySet | Sort-Object)
        by_skill      = [object[]]$bySkillArr
        by_provenance = [object[]]$byProvArr
        by_tool       = [object[]]$byToolArr
    }
}

# ---- human-readable stderr metrics view (per part) --------------------------
# Not part of the JSON contract or the no-regression byte check (only stdout JSON
# and the rendered markdown are) — a plain console view of one part's records +
# its aggregate. Reused for single-step, the multistep parent, and each child.
function Fmt([object]$n) { if ($null -eq $n) { return '-' }; return ('{0:N0}' -f [long]$n) }
function Write-HumanPart {
    param([string]$Heading, $Records, $Agg)
    Note ''
    Note "### $Heading"
    Note ("  conversations: {0}   analyzed (with metrics): {1}" -f $Records.Count, $Agg.analyzed_count)
    foreach ($r in $Records) {
        $sk = if ($r.skill) { $r.skill } else { '(no skill)' }
        Note ("  * {0}  [{1}]  {2}  key={3} ({4})" -f $r.uuid, $r.provenance, $sk, ($(if ($r.issue_key) { $r.issue_key } else { '-' })), $r.key_status)
        Note ("      models: {0}" -f ($(if ($r.models.Count) { $r.models -join ', ' } else { '-' })))
        Note ("      tokens  in={0}  out={1}  cache-read={2}  cache-write={3}  total={4}" -f (Fmt $r.tokens.in), (Fmt $r.tokens.out), (Fmt $r.tokens.cache_read), (Fmt $r.tokens.cache_write), (Fmt $r.tokens.total))
        Note ("      perf    turns={0}  sidechain={1}  tool-calls={2} (errors={3})  elapsed={4}s" -f (Fmt $r.skill_turns), (Fmt $r.sidechain_turns), (Fmt $r.tool_calls), (Fmt $r.tool_errors), ($(if ($null -ne $r.wall_clock_s) { '{0:N1}' -f [double]$r.wall_clock_s } else { '-' })))
        if ($r.tools -and @($r.tools).Count) {
            Note ("      tools   {0}" -f ((@($r.tools) | ForEach-Object { "$($_.name):$($_.calls)" }) -join ', '))
        }
    }
}
function Write-HumanTotals {
    param([string]$Label, $Agg)
    Note ''
    Note "  === $Label ==="
    Note ("  tokens  in={0}  out={1}  cache-read={2}  cache-write={3}" -f (Fmt $Agg.tokens.in), (Fmt $Agg.tokens.out), (Fmt $Agg.tokens.cache_read), (Fmt $Agg.tokens.cache_write))
    Note ("  TOTAL token consumption: {0}" -f (Fmt $Agg.tokens.total))
    Note ("  perf    skill-turns={0}  sidechain-turns={1}  tool-calls={2}  tool-errors={3}" -f (Fmt $Agg.skill_turns), (Fmt $Agg.sidechain_turns), (Fmt $Agg.tool_calls), (Fmt $Agg.tool_errors))
    Note ("  activity: {0} -> {1}{2}" -f ($(if ($Agg.timeframe.first_ts) { $Agg.timeframe.first_ts } else { '-' })), ($(if ($Agg.timeframe.last_ts) { $Agg.timeframe.last_ts } else { '-' })), ($(if ($null -ne $Agg.timeframe.span_s) { "  (span {0}s)" -f (Fmt $Agg.timeframe.span_s) } else { '' })))
    Note ("  models: {0}" -f ($(if (@($Agg.models).Count) { @($Agg.models) -join ', ' } else { '-' })))
    Note ("  skills: {0}" -f ($(if (@($Agg.skills).Count) { @($Agg.skills) -join ', ' } else { '-' })))
    if ($Agg.by_tool -and @($Agg.by_tool).Count) {
        Note ("  tools:  {0}" -f ((@($Agg.by_tool) | ForEach-Object { "$($_.tool):$($_.calls)" }) -join ', '))
    }
}

# ---- detect feature type: does <KEY> have sub-tasks? ------------------------
# One Jira fetch, wrapped in a LONG TIMEOUT (the API can legitimately take
# minutes). Run in a background job so a hung call can't wedge the roll-up; a
# timeout or any acli failure falls back to single-step with a loud WARN rather
# than aborting a read-only report. `subtasks` must be named explicitly in
# --fields since the default --json omits it (see docs/examples/acli-list-subtasks.py).
$AcliTimeoutSec = 300
function Get-Subtasks([string]$FKey) {
    # Returns @{ ok=$bool; summary=<string>; subtasks=@(@{key;summary}...) }.
    $result = @{ ok = $false; summary = $null; subtasks = @() }
    if (-not (Get-Command acli -ErrorAction SilentlyContinue)) {
        Note "collect_feature: acli not found -- cannot detect sub-tasks; treating $FKey as single-step."
        return $result
    }
    $raw = $null
    try {
        $job = Start-Job -ScriptBlock {
            param($k)
            & acli jira workitem view $k --json --fields 'summary,subtasks'
        } -ArgumentList $FKey
        if (Wait-Job $job -Timeout $AcliTimeoutSec) {
            $raw = (Receive-Job $job -ErrorAction SilentlyContinue) -join "`n"
        } else {
            Stop-Job $job -ErrorAction SilentlyContinue
            Note "collect_feature: acli sub-task lookup for $FKey timed out after ${AcliTimeoutSec}s -- treating as single-step."
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        Note "collect_feature: acli sub-task lookup for $FKey failed ($($_.Exception.Message)) -- treating as single-step."
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $result }
    # acli may print leading non-JSON lines; jump to the first '{'.
    $brace = $raw.IndexOf('{')
    if ($brace -lt 0) { return $result }
    $obj = $null
    try { $obj = $raw.Substring($brace) | ConvertFrom-Json } catch {
        Note "collect_feature: acli sub-task lookup for $FKey returned unparseable JSON -- treating as single-step."
        return $result
    }
    $fields = if ($obj.fields) { $obj.fields } else { $obj }
    $result.ok = $true
    $result.summary = [string]$fields.summary
    $subs = @()
    if ($fields.subtasks) {
        foreach ($s in @($fields.subtasks)) {
            $sSum = $null
            if ($s.fields) { $sSum = [string]$s.fields.summary }
            $subs += @{ key = [string]$s.key; summary = $sSum }
        }
    }
    $result.subtasks = @($subs)
    return $result
}

$detect = Get-Subtasks $Key

# =============================================================================
# SINGLE-STEP  (no sub-tasks) — flat feature-report@2, byte-for-byte unchanged
# =============================================================================
if (@($detect.subtasks).Count -eq 0) {
    $Records = Get-FeatureRecords $Key $false
    $agg = New-Aggregate $Records

    $Root = [ordered]@{
        schema            = 'jira-sdlc/conversation-debugger/feature-report@2'
        feature           = $Key
        conversation_count = $Records.Count
        # [object[]] cast (not @(...)): a List[object] of OrderedDictionary trips an
        # "Argument types do not match" binding error when wrapped with @() inside an
        # [ordered] literal; the explicit cast sidesteps it and serializes the same.
        conversations     = [object[]]$Records
        aggregate         = $agg
    }
    $Root | ConvertTo-Json -Depth 8

    Write-HumanPart "Feature roll-up — $Key" $Records $agg
    Write-HumanTotals 'feature totals' $agg
    exit 0
}

# =============================================================================
# MULTISTEP  (parent story + child sub-tasks) — nested feature-report@3
# =============================================================================
Note ''
Note ("collect_feature: $Key is a MULTISTEP parent ({0} sub-task(s): {1}) -- emitting nested feature-report@3." -f @($detect.subtasks).Count, ((@($detect.subtasks) | ForEach-Object { $_.key }) -join ', '))

# Parent's own conversations (the assigner session that created the feature, plus
# any sessions under the parent's own worktree). Soft: a parent with no worktree
# contributes zero rather than aborting the feature.
$parentRecords = Get-FeatureRecords $Key $true

# Dedup by transcript path, PARENT-PRIORITY. A multistep assigner session
# (main-checkout) mentions the parent AND every sub-task key, so it is resolved for
# each — attribute it to the parent (its true owner) and drop it from any child, so
# its tokens are counted exactly once feature-wide. Worktree sessions are
# folder-scoped per key and never overlap; only the assigner session does.
$seen = @{}
foreach ($r in $parentRecords) { $seen[([string]$r.transcript).ToLowerInvariant()] = $true }

$childrenArr = @()
foreach ($sub in @($detect.subtasks)) {
    $childRaw = Get-FeatureRecords $sub.key $true
    $childKept = New-Object System.Collections.Generic.List[object]
    foreach ($r in $childRaw) {
        $tp = ([string]$r.transcript).ToLowerInvariant()
        if ($seen.ContainsKey($tp)) {
            Note "collect_feature: $($r.uuid) already attributed (parent or an earlier child) -- not double-counting under $($sub.key)."
            continue
        }
        $seen[$tp] = $true
        $childKept.Add($r)
    }
    $childAgg = New-Aggregate $childKept
    $childrenArr += [ordered]@{
        key                = $sub.key
        summary            = $sub.summary
        conversation_count = $childKept.Count
        conversations      = [object[]]$childKept
        aggregate          = $childAgg
    }
    Write-HumanPart ("Child feature — {0}{1}" -f $sub.key, ($(if ($sub.summary) { " ($($sub.summary))" } else { '' }))) $childKept $childAgg
    Write-HumanTotals ("child {0} totals" -f $sub.key) $childAgg
}

# Feature-wide aggregate = parent's own records + every child's (deduped) records.
$allRecords = New-Object System.Collections.Generic.List[object]
foreach ($r in $parentRecords) { $allRecords.Add($r) }
foreach ($c in $childrenArr) { foreach ($r in @($c.conversations)) { $allRecords.Add($r) } }
$featureAgg = New-Aggregate $allRecords
$parentAgg  = New-Aggregate $parentRecords

$Root = [ordered]@{
    schema            = 'jira-sdlc/conversation-debugger/feature-report@3'
    feature           = $Key
    feature_type      = 'multistep'
    parent            = [ordered]@{
        key                = $Key
        summary            = $detect.summary
        conversation_count = $parentRecords.Count
        conversations      = [object[]]$parentRecords
        aggregate          = $parentAgg
    }
    children          = [object[]]$childrenArr
    conversation_count = $allRecords.Count
    aggregate         = $featureAgg
}
# Deeper than @2 (parent/children add a nesting level) -> a roomier -Depth.
$Root | ConvertTo-Json -Depth 12

# ---- stderr: parent view then feature totals (children already printed) ------
Write-HumanPart ("Parent (own conversations) — {0}{1}" -f $Key, ($(if ($detect.summary) { " ($($detect.summary))" } else { '' }))) $parentRecords $parentAgg
Write-HumanTotals "FEATURE-WIDE totals — $Key (parent + $(@($childrenArr).Count) child feature(s))" $featureAgg

exit 0
