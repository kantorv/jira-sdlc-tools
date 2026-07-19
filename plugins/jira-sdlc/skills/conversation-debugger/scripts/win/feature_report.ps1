# feature_report.ps1 [<json-path>]
#
# Report-builder half of the feature roll-up: consumes the collect_feature JSON
# and renders a markdown feature report from it. The pipeline is
#   collect_feature.ps1 <KEY>  ->  JSON  ->  feature_report.ps1  ->  markdown
# collect_feature is the single OWNER of the JSON schema
# (see references/feature-report-schema.md); this script only READS it and never
# re-measures — every number rendered here is a value the collector already
# emitted.
#
# It renders BOTH feature types the collector emits, detected from the JSON:
#   * single-step (feature-report@2, flat)  -> the current template, unchanged.
#   * multistep  (feature-report@3, nested) -> a parent summary, one section per
#     CHILD feature with that child's conversations in-place, then feature-wide
#     totals + the by-skill / by-provenance / timeframe roll-ups and pie(s) across
#     the whole feature. Detection is the presence of `children` / a `@3` schema
#     tag; @1/@2 JSON (no `children`) renders through the untouched single-step
#     path, so there is no regression on existing single-step reports.
#
# Input — a path and/or stdin (whichever is given):
#   feature_report.ps1 report.json > report.md      # from a file
#   collect_feature.ps1 JST-93 | feature_report.ps1 > report.md   # from stdin
# A '-' path also means stdin. With no path and no piped input it prints usage
# and exits 1 rather than blocking on the console.
#
# Output: the markdown report on stdout, nothing else. Read-only: it neither
# writes files nor touches Jira/git.
#
# This is the Windows (PowerShell 5.1+) half of a posix+win contract pair; the
# POSIX twin (../posix/feature_report.sh) is a full bash+python3 port with the
# same CLI, stdout, and exit codes. Callers dispatch by their runtime.
#
# Exit: 0 = markdown emitted   1 = usage / unreadable-or-invalid JSON

$ErrorActionPreference = 'Stop'
function Fail([string]$msg) { [Console]::Error.WriteLine("feature_report: $msg"); exit 1 }

# ---- read the JSON (path arg, or stdin) -------------------------------------
$PipedInput = @($input)   # capture the PS object pipeline before it's consumed
$PathArg = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$raw = $null
if ($PathArg -and $PathArg -ne '-') {
    if (-not (Test-Path -LiteralPath $PathArg -PathType Leaf)) { Fail "no such JSON file: $PathArg" }
    $raw = [System.IO.File]::ReadAllText($PathArg)
} elseif ($PipedInput.Count -gt 0) {
    # Invoked as a stage in a PowerShell pipeline (… | .\feature_report.ps1): the
    # JSON arrives as objects on the PS object pipeline, not the process's console
    # stdin, so [Console]::In is empty here. -join (not Out-String) rebuilds the
    # text without width-wrapping long JSON lines.
    $raw = ($PipedInput -join "`n")
} elseif ($PathArg -eq '-' -or [Console]::IsInputRedirected) {
    # Entry point of its own process with redirected stdin: pwsh -File … piped
    # from another process, or an explicit '-' path.
    $raw = [Console]::In.ReadToEnd()
} else {
    Fail 'need collect_feature JSON: pass a path, or pipe it in (collect_feature.ps1 <KEY> | feature_report.ps1).'
}
if ([string]::IsNullOrWhiteSpace($raw)) { Fail 'empty input -- no JSON to render.' }

try { $data = $raw | ConvertFrom-Json -ErrorAction Stop } catch { Fail 'input is not valid JSON (expected collect_feature output).' }

# Feature type: multistep iff the collector emitted a `children` array (or tagged
# the schema @3). @1/@2 JSON has no `children` and renders through the single-step
# path below unchanged.
$isMulti = ($null -ne $data.children) -or ($data.schema -and ([string]$data.schema).TrimEnd().EndsWith('@3'))
if ($isMulti) {
    if ($null -eq $data.feature -or $null -eq $data.parent -or $null -eq $data.children -or $null -eq $data.aggregate) {
        Fail 'multistep JSON is missing feature/parent/children/aggregate -- is this collect_feature @3 output?'
    }
} else {
    if ($null -eq $data.feature -or $null -eq $data.conversations -or $null -eq $data.aggregate) {
        Fail 'JSON is missing feature/conversations/aggregate -- is this collect_feature output?'
    }
}

# ---- formatting helpers -----------------------------------------------------
# Only $null / '' render as '-'; a measured 0 must render as 0. (Guard against
# PowerShell coercing '' to numeric 0 in `-eq`, which would hide real zeros.)
function Num([object]$n)  { if ($null -eq $n -or ($n -is [string] -and $n -eq '')) { return '-' }; return ('{0:N0}' -f [long]$n) }
function Sec([object]$n)  { if ($null -eq $n -or ($n -is [string] -and $n -eq '')) { return '-' }; return ('{0:N1}' -f [double]$n) }
function Join-List($xs)   { if ($null -eq $xs) { return '-' }; $a = @($xs); if ($a.Count -eq 0) { return '-' }; return ($a -join ', ') }
# Timestamps arrive as DateTime (ConvertFrom-Json auto-parses the ISO-Z strings)
# or, on older hosts, as the raw string — render either as compact UTC.
function Ts([object]$v)  {
    if ($null -eq $v -or $v -eq '') { return '-' }
    if ($v -is [datetime])       { return $v.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss'Z'") }
    if ($v -is [datetimeoffset]) { return $v.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss'Z'") }
    return [string]$v
}
# Seconds -> human span (collector-provided number, formatted only — not computed here).
function Dur([object]$sec) {
    if ($null -eq $sec -or $sec -eq '') { return '-' }
    $t = [timespan]::FromSeconds([double]$sec)
    if ($t.TotalHours   -ge 1) { return ('{0}h {1}m {2}s' -f [int]$t.TotalHours, $t.Minutes, $t.Seconds) }
    if ($t.TotalMinutes -ge 1) { return ('{0}m {1}s' -f [int]$t.TotalMinutes, $t.Seconds) }
    return ('{0:N1}s' -f [double]$sec)
}
$nl = "`n"
$out = New-Object System.Collections.Generic.List[string]
function W([string]$s) { $out.Add($s) }

# Emit a GitHub-native mermaid pie of the (label,value) pairs whose value > 0.
# Rendered from measured totals — no computation here. Skipped for < 2 slices (a
# single slice is always 100%, so it adds noise, not insight). Labels are
# sanitized: quotes stripped and ';' -> ',' because a ';' silently truncates a
# mermaid line and breaks the whole diagram (see AGENTS.md).
function Emit-Pie([string]$title, $pairs) {
    $rows = @($pairs | Where-Object { $null -ne $_.value -and [double]$_.value -gt 0 })
    if ($rows.Count -lt 2) { return }
    W '```mermaid'
    W 'pie showData'
    W ("    title {0}" -f ($title -replace ';', ','))
    foreach ($r in $rows) {
        $lbl = ([string]$r.label) -replace '"', '' -replace ';', ','
        W ('    "{0}" : {1}' -f $lbl, [long]$r.value)
    }
    W '```'
    W ''
}

# ---- reusable section renderers ---------------------------------------------
# One per markdown section so the single-step path and each multistep part render
# identical tables. $Level is the heading prefix: '##' for a top-level single-step
# section, '###' when nested under a multistep part header — the default '##'
# reproduces the single-step output byte-for-byte.
function Emit-TokensSection {
    param($conv, [string]$Level = '##')
    W "$Level Per-conversation — tokens"
    W ''
    W '| conversation | provenance | skill | issue | model(s) | in | out | cache-read | cache-write | total | tool calls | elapsed (s) |'
    W '|---|---|---|---|---|--:|--:|--:|--:|--:|--:|--:|'
    foreach ($c in $conv) {
        $skill = if ($c.skill) { $c.skill } else { '_(no skill)_' }
        $issue = if ($c.issue_key) { $c.issue_key } else { '-' }
        # A record with no measured metrics (skill_turns null: stub / unexpected /
        # no-skill) is listed for coverage but has no numbers — render its metric
        # cells as em-dashes and surface why, so a zero never reads as a real zero.
        $analyzedRow = ($null -ne $c.skill_turns)
        if ($analyzedRow) {
            $models = Join-List $c.models
            $t = $c.tokens
            W ("| ``{0}`` | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} | {10} | {11} |" -f `
                $c.uuid, $c.provenance, $skill, $issue, $models, `
                (Num $t.in), (Num $t.out), (Num $t.cache_read), (Num $t.cache_write), (Num $t.total), `
                (Num $c.tool_calls), (Sec $c.wall_clock_s))
        } else {
            $why = "_not analyzed: $($c.key_status)_"
            W ("| ``{0}`` | {1} | {2} | {3} | {4} | — | — | — | — | — | — | — |" -f `
                $c.uuid, $c.provenance, $skill, $issue, $why)
        }
    }
    W ''
    # pie: total-token share per conversation (analyzed rows carrying tokens)
    $convPie = foreach ($c in $conv) {
        if ($null -ne $c.skill_turns -and $null -ne $c.tokens -and [double]$c.tokens.total -gt 0) {
            $sk = if ($c.skill) { $c.skill } else { '(no skill)' }
            $short = if ($c.uuid -and ([string]$c.uuid).Length -ge 8) { ([string]$c.uuid).Substring(0, 8) } else { [string]$c.uuid }
            [pscustomobject]@{ label = "$sk · $short"; value = [long]$c.tokens.total }
        }
    }
    Emit-Pie 'Token consumption by conversation (total tokens)' @($convPie)
}

function Emit-PerfSection {
    param($conv, [string]$Level = '##')
    W "$Level Per-conversation — performance"
    W ''
    W '| conversation | skill | skill turns | sidechain turns | tool calls | tool errors | elapsed (s) | first activity | last activity |'
    W '|---|---|--:|--:|--:|--:|--:|---|---|'
    foreach ($c in $conv) {
        $skill = if ($c.skill) { $c.skill } else { '_(no skill)_' }
        if ($null -ne $c.skill_turns) {
            W ("| ``{0}`` | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |" -f `
                $c.uuid, $skill, (Num $c.skill_turns), (Num $c.sidechain_turns), `
                (Num $c.tool_calls), (Num $c.tool_errors), (Sec $c.wall_clock_s), `
                (Ts $c.first_ts), (Ts $c.last_ts))
        } else {
            W ("| ``{0}`` | {1} | — | — | — | — | — | — | — |" -f $c.uuid, $skill)
        }
    }
    W ''
}

function Emit-BySkillSection {
    param($agg)
    if ($null -ne $agg.by_skill -and @($agg.by_skill).Count -gt 0) {
        W '## Tokens by skill'
        W ''
        W '| skill | conversations | in | out | cache-read | cache-write | total |'
        W '|---|--:|--:|--:|--:|--:|--:|'
        foreach ($s in @($agg.by_skill)) {
            $t = $s.tokens
            W ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f `
                $s.skill, (Num $s.conversations), (Num $t.in), (Num $t.out), `
                (Num $t.cache_read), (Num $t.cache_write), (Num $t.total))
        }
        W ''
        # pie: total-token share per skill
        $skillPie = foreach ($s in @($agg.by_skill)) {
            if ($null -ne $s.tokens -and [double]$s.tokens.total -gt 0) {
                [pscustomobject]@{ label = [string]$s.skill; value = [long]$s.tokens.total }
            }
        }
        Emit-Pie 'Token consumption by skill (total tokens)' @($skillPie)
    }
}

function Emit-ByProvenanceSection {
    param($agg)
    if ($null -ne $agg.by_provenance -and @($agg.by_provenance).Count -gt 0) {
        W '## Tokens by provenance'
        W ''
        W '| provenance | conversations | in | out | cache-read | cache-write | total |'
        W '|---|--:|--:|--:|--:|--:|--:|'
        foreach ($p in @($agg.by_provenance)) {
            $t = $p.tokens
            W ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f `
                $p.provenance, (Num $p.conversations), (Num $t.in), (Num $t.out), `
                (Num $t.cache_read), (Num $t.cache_write), (Num $t.total))
        }
        W ''
    }
}

function Emit-FeatureTotals {
    param($agg)
    W '## Feature totals'
    W ''
    W '| token bucket | tokens |'
    W '|---|--:|'
    W "| input | $(Num $agg.tokens.in) |"
    W "| output | $(Num $agg.tokens.out) |"
    W "| cache read | $(Num $agg.tokens.cache_read) |"
    W "| cache write | $(Num $agg.tokens.cache_write) |"
    W "| **grand total** | **$(Num $agg.tokens.total)** |"
    W ''
    W "Models across the feature: **$(Join-List $agg.models)**"
    W ''
}

function Emit-Timeframe {
    param($agg)
    if ($agg.timeframe -and ($agg.timeframe.first_ts -or $agg.timeframe.last_ts)) {
        W '## Activity timeframe'
        W ''
        W '| metric | value |'
        W '|---|---|'
        W "| First activity | $(Ts $agg.timeframe.first_ts) |"
        W "| Last activity | $(Ts $agg.timeframe.last_ts) |"
        W "| Span (first → last) | $(Dur $agg.timeframe.span_s) |"
        W ''
        W "_Span is wall-clock from the earliest to the latest measured turn across the feature — it includes idle gaps between sessions and human wait time, so it is not compute time and does not equal the sum of per-conversation elapsed._"
        W ''
    }
}

if (-not $isMulti) {
    # =========================================================================
    # SINGLE-STEP (feature-report@1/@2) — the original template, unchanged
    # =========================================================================
    $agg = $data.aggregate
    $conv = @($data.conversations)

    # ---- header + summary ---------------------------------------------------
    W "# Feature report — $($data.feature)"
    W ''
    $analyzed = if ($null -ne $agg.analyzed_count) { $agg.analyzed_count } else { $conv.Count }
    W "_Generated by ``feature_report`` from ``collect_feature`` JSON — $($conv.Count) conversation(s), $analyzed with measured metrics. Every figure is the collector's own; nothing is re-estimated._"
    W ''
    W '## Summary'
    W ''
    W '| metric | value |'
    W '|---|---|'
    W "| Feature | $($data.feature) |"
    W "| Conversations | $($conv.Count) (analyzed: $analyzed) |"
    W "| **Total token consumption** | **$(Num $agg.tokens.total)** |"
    W "| — input | $(Num $agg.tokens.in) |"
    W "| — output | $(Num $agg.tokens.out) |"
    W "| — cache read | $(Num $agg.tokens.cache_read) |"
    W "| — cache write | $(Num $agg.tokens.cache_write) |"
    W "| Models used | $(Join-List $agg.models) |"
    W "| Skills exercised | $(Join-List $agg.skills) |"
    W "| Issue keys touched | $(Join-List $agg.issue_keys) |"
    if ($null -ne $agg.skill_turns)  { W "| Total skill turns | $(Num $agg.skill_turns) |" }
    if ($null -ne $agg.tool_calls)   { W "| Total tool calls | $(Num $agg.tool_calls) (errors: $(Num $agg.tool_errors)) |" }
    if ($agg.timeframe -and $null -ne $agg.timeframe.span_s) {
        W "| Activity span | $(Dur $agg.timeframe.span_s) ($(Ts $agg.timeframe.first_ts) → $(Ts $agg.timeframe.last_ts)) |"
    }
    W ''

    Emit-TokensSection $conv
    Emit-PerfSection $conv
    Emit-BySkillSection $agg
    Emit-ByProvenanceSection $agg
    Emit-FeatureTotals $agg
    Emit-Timeframe $agg
} else {
    # =========================================================================
    # MULTISTEP (feature-report@3) — parent + child features, in place
    # =========================================================================
    $fagg     = $data.aggregate
    $parent   = $data.parent
    $children = @($data.children)
    $totalConv = if ($null -ne $data.conversation_count) { $data.conversation_count } else { @($parent.conversations).Count }
    $analyzed  = if ($null -ne $fagg.analyzed_count) { $fagg.analyzed_count } else { $totalConv }

    # ---- header + feature summary ------------------------------------------
    W "# Feature report — $($data.feature) (multistep)"
    W ''
    W "_Generated by ``feature_report`` from ``collect_feature`` JSON — multistep feature: parent **$($parent.key)** + $($children.Count) child feature(s), $totalConv conversation(s) feature-wide, $analyzed with measured metrics. Every figure is the collector's own; nothing is re-estimated._"
    W ''
    W '## Feature summary'
    W ''
    W '| metric | value |'
    W '|---|---|'
    W "| Feature (parent) | $($parent.key) |"
    if ($parent.summary) { W "| Parent summary | $($parent.summary) |" }
    W "| Child features | $($children.Count) |"
    W "| Conversations (feature-wide) | $totalConv (analyzed: $analyzed) |"
    W "| **Total token consumption** | **$(Num $fagg.tokens.total)** |"
    W "| — input | $(Num $fagg.tokens.in) |"
    W "| — output | $(Num $fagg.tokens.out) |"
    W "| — cache read | $(Num $fagg.tokens.cache_read) |"
    W "| — cache write | $(Num $fagg.tokens.cache_write) |"
    W "| Models used | $(Join-List $fagg.models) |"
    W "| Skills exercised | $(Join-List $fagg.skills) |"
    W "| Issue keys touched | $(Join-List $fagg.issue_keys) |"
    if ($null -ne $fagg.skill_turns) { W "| Total skill turns | $(Num $fagg.skill_turns) |" }
    if ($null -ne $fagg.tool_calls)  { W "| Total tool calls | $(Num $fagg.tool_calls) (errors: $(Num $fagg.tool_errors)) |" }
    if ($fagg.timeframe -and $null -ne $fagg.timeframe.span_s) {
        W "| Activity span | $(Dur $fagg.timeframe.span_s) ($(Ts $fagg.timeframe.first_ts) → $(Ts $fagg.timeframe.last_ts)) |"
    }
    W ''

    # ---- token share by feature part (parent-own + each child) --------------
    W '## Token share by feature part'
    W ''
    W '| feature part | key | conversations | total tokens |'
    W '|---|---|--:|--:|'
    W "| parent (own) | $($parent.key) | $(Num $parent.aggregate.conversation_count) | $(Num $parent.aggregate.tokens.total) |"
    foreach ($c in $children) {
        W "| child | $($c.key) | $(Num $c.aggregate.conversation_count) | $(Num $c.aggregate.tokens.total) |"
    }
    W ''
    $partPie = @()
    if ($null -ne $parent.aggregate.tokens -and [double]$parent.aggregate.tokens.total -gt 0) {
        $partPie += [pscustomobject]@{ label = "parent · $($parent.key)"; value = [long]$parent.aggregate.tokens.total }
    }
    foreach ($c in $children) {
        if ($null -ne $c.aggregate.tokens -and [double]$c.aggregate.tokens.total -gt 0) {
            $partPie += [pscustomobject]@{ label = [string]$c.key; value = [long]$c.aggregate.tokens.total }
        }
    }
    Emit-Pie 'Token consumption by feature part (total tokens)' @($partPie)

    # ---- parent's own conversations, in place -------------------------------
    W "## Parent feature — $($parent.key)"
    W ''
    if ($parent.summary) { W "_$($parent.summary)_"; W '' }
    $pconv = @($parent.conversations)
    if ($pconv.Count -gt 0) {
        Emit-TokensSection $pconv '###'
        Emit-PerfSection $pconv '###'
    } else {
        W '_No conversations attributed to the parent itself (e.g. the creating assigner session was not resolved, or the parent has no worktree)._'
        W ''
    }

    # ---- each child feature, conversations in place -------------------------
    foreach ($c in $children) {
        W "## Child feature — $($c.key)"
        W ''
        if ($c.summary) { W "_$($c.summary)_"; W '' }
        $cconv = @($c.conversations)
        if ($cconv.Count -gt 0) {
            Emit-TokensSection $cconv '###'
            Emit-PerfSection $cconv '###'
        } else {
            W '_No conversations resolved for this child feature yet (no worktree, or no sessions in it)._'
            W ''
        }
    }

    # ---- feature-wide roll-ups ---------------------------------------------
    Emit-BySkillSection $fagg
    Emit-ByProvenanceSection $fagg
    Emit-FeatureTotals $fagg
    Emit-Timeframe $fagg
}

# ---- emit -------------------------------------------------------------------
# Emit on PowerShell's success stream (not [Console]::Out.Write), so `> file.md`
# captures the markdown whether this runs as its own process (pwsh -File …) or as
# a stage inside an existing session (… | .\feature_report.ps1). A direct console
# write bypasses the success stream, so in the pipeline-stage form `>` would
# redirect nothing and the markdown would land on the console with an empty file.
# One joined string keeps the LF line breaks intact (matches collect_feature,
# which emits its JSON the same way via ConvertTo-Json).
Write-Output ($out -join $nl)
exit 0
