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
# Windows (PowerShell 5.1+) only this round. The posix twin ships as a STUB
# (../posix/collect_feature.sh) that announces itself and exits non-zero — a
# deliberate, explicit parity gap (see the issue / the doc), not a silent one.
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

# ---- resolve this feature's conversations via sync_conversations ------------
# Read-only (no --attach). Its Write-Output (grouped listing + "=== attachment
# paths ===" block) is captured here; its own stderr notes flow straight to the
# console. A non-zero exit is fatal — it already explained why on stderr.
$SyncOut = & $SyncScript $Key
$SyncExit = $LASTEXITCODE
if ($SyncExit -ne 0) { Fail "sync_conversations.ps1 $Key failed (exit $SyncExit) -- see its message above. Nothing rolled up." }

# Echo the grouped listing (everything up to the machine block) to stderr, so a
# console run still shows sync_conversations' familiar view.
$SentinelIdx = -1
for ($i = 0; $i -lt $SyncOut.Count; $i++) {
    if ([string]$SyncOut[$i] -match '^=== attachment paths') { $SentinelIdx = $i; break }
}
Note ''
Note "collect_feature: rolling up $Key"
if ($SentinelIdx -ge 0) {
    for ($i = 0; $i -lt $SentinelIdx; $i++) { Note ([string]$SyncOut[$i]) }
} else {
    foreach ($l in $SyncOut) { Note ([string]$l) }
}

# The authoritative ordered path list comes from sync_conversations' machine
# block ("=== attachment paths ==="), not its human listing.
$Paths = New-Object System.Collections.Generic.List[string]
$inMachine = $false
foreach ($lnRaw in $SyncOut) {
    $ln = [string]$lnRaw
    if ($ln -match '^=== attachment paths') { $inMachine = $true; continue }
    if ($inMachine) {
        $t = $ln.Trim()
        if ($t -match '\.jsonl$') { $Paths.Add($t) }
    }
}

# Provenance (worktree vs main-checkout) is classified by the same two config
# folders sync_conversations uses — read the same way (env files, not $env),
# rather than scraping sync's human formatting. A path under the worktrees
# prefix is a worktree session; one under the main-repo folder is the assigner's.
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

if ($Paths.Count -eq 0) {
    Note "collect_feature: no conversation transcripts resolved for $Key -- emitting an empty roll-up."
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

# ---- run collect_run over each (conversation, skill) ------------------------
$Records = New-Object System.Collections.Generic.List[object]
foreach ($path in $Paths) {
    $provenance = Get-Provenance $path
    $uuid = [System.IO.Path]::GetFileNameWithoutExtension($path)
    $skills = Get-InvokedSkills $path

    if ($skills.Count -eq 0) {
        Note "collect_feature: $uuid invoked no analyzable skill -- recorded without metrics."
        $Records.Add([ordered]@{
            uuid = $uuid; transcript = $path; provenance = $provenance
            skill = $null; issue_key = $null; key_status = 'no-skill'
            models = @(); tokens = [ordered]@{ in = 0; out = 0; cache_read = 0; cache_write = 0; total = 0 }
            skill_turns = $null; sidechain_turns = $null; tool_calls = $null; tool_errors = $null
            wall_clock_s = $null; first_ts = $null; last_ts = $null
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

        $Records.Add([ordered]@{
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
            wall_clock_s   = $wall
            first_ts    = if ($hasMetrics -and $kv['FIRST_TS']) { $kv['FIRST_TS'] } else { $null }
            last_ts     = if ($hasMetrics -and $kv['LAST_TS'])  { $kv['LAST_TS'] }  else { $null }
        })
    }
}

# ---- aggregate: sum measured tokens, union models / skills / keys ------------
$agIn = 0L; $agOut = 0L; $agCr = 0L; $agCw = 0L
$mdlSet = New-Object System.Collections.Generic.List[string]
$sklSet = New-Object System.Collections.Generic.List[string]
$keySet = New-Object System.Collections.Generic.List[string]
$analyzed = 0
foreach ($r in $Records) {
    if ($r.key_status -eq 'expected' -or $r.key_status -eq 'given') {
        $analyzed++
        $agIn += [long]$r.tokens.in; $agOut += [long]$r.tokens.out
        $agCr += [long]$r.tokens.cache_read; $agCw += [long]$r.tokens.cache_write
    }
    foreach ($m in $r.models) { if ($m -and -not $mdlSet.Contains($m)) { $mdlSet.Add($m) } }
    if ($r.skill -and -not $sklSet.Contains($r.skill)) { $sklSet.Add($r.skill) }
    if ($r.issue_key -and -not $keySet.Contains($r.issue_key)) { $keySet.Add($r.issue_key) }
}
$agTot = $agIn + $agOut + $agCr + $agCw

$Root = [ordered]@{
    schema            = 'jira-sdlc/conversation-debugger/feature-report@1'
    feature           = $Key
    conversation_count = $Records.Count
    # [object[]] cast (not @(...)): a List[object] of OrderedDictionary trips an
    # "Argument types do not match" binding error when wrapped with @() inside an
    # [ordered] literal; the explicit cast sidesteps it and serializes the same.
    conversations     = [object[]]$Records
    aggregate         = [ordered]@{
        conversation_count = $Records.Count
        analyzed_count     = $analyzed
        tokens  = [ordered]@{ in = $agIn; out = $agOut; cache_read = $agCr; cache_write = $agCw; total = $agTot }
        models  = [string[]]($mdlSet | Sort-Object)
        skills  = [string[]]$sklSet
        issue_keys = [string[]]($keySet | Sort-Object)
    }
}

# ---- stdout: the JSON, and nothing else -------------------------------------
$Root | ConvertTo-Json -Depth 8

# ---- stderr: the human-readable metrics view --------------------------------
function Fmt([object]$n) { if ($null -eq $n) { return '-' }; return ('{0:N0}' -f [long]$n) }
Note ''
Note "### Feature roll-up — $Key"
Note ("  conversations: {0}   analyzed (with metrics): {1}" -f $Records.Count, $analyzed)
foreach ($r in $Records) {
    $sk = if ($r.skill) { $r.skill } else { '(no skill)' }
    Note ("  * {0}  [{1}]  {2}  key={3} ({4})" -f $r.uuid, $r.provenance, $sk, ($(if ($r.issue_key) { $r.issue_key } else { '-' })), $r.key_status)
    Note ("      models: {0}" -f ($(if ($r.models.Count) { $r.models -join ', ' } else { '-' })))
    Note ("      tokens  in={0}  out={1}  cache-read={2}  cache-write={3}  total={4}" -f (Fmt $r.tokens.in), (Fmt $r.tokens.out), (Fmt $r.tokens.cache_read), (Fmt $r.tokens.cache_write), (Fmt $r.tokens.total))
}
Note ''
Note "  === feature totals ==="
Note ("  tokens  in={0}  out={1}  cache-read={2}  cache-write={3}" -f (Fmt $agIn), (Fmt $agOut), (Fmt $agCr), (Fmt $agCw))
Note ("  TOTAL feature token consumption: {0}" -f (Fmt $agTot))
Note ("  models used across feature: {0}" -f ($(if ($mdlSet.Count) { ($mdlSet | Sort-Object) -join ', ' } else { '-' })))
Note ("  skills exercised: {0}" -f ($(if ($sklSet.Count) { $sklSet -join ', ' } else { '-' })))

exit 0
