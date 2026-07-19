# collect_run.ps1 <skill-name> <conversation-path> [issue-key]
#
# Windows (PowerShell 5.1+) port of ../posix/collect_run.sh. Mirrors the bash
# contract exactly: same arguments, same KEY=VALUE stdout block, same exit
# codes and stderr messages. The bash original shells out to `jq` for every
# JSON read; that dependency doesn't exist on a bare Windows box, so this port
# reimplements the JSONL parsing and jq pipeline natively with ConvertFrom-Json
# and .NET regex/collections — no bash, no jq on this path.
#
# Validates the transcript, profiles it, recovers the issue key from the
# place that skill is known to produce it, and — only once the key is
# trustworthy — creates conversations/<KEY>/ and copies the transcript in.
#
# Exit: 0 = filed under conversations/<KEY>/
#       1 = hard error (bad input, no repo, unusable transcript)
#       2 = nothing filed, a human has to decide (KEY_STATUS says why)
#
# Where the key comes from is not a guess — see the header comment in the
# bash twin (../posix/collect_run.sh) for the full rationale; this port
# reads the same three sites, in the same order.

$ErrorActionPreference = 'Stop'

function Fail([string]$msg) {
    [Console]::Error.WriteLine("collect_run: $msg")
    exit 1
}

# ---- arguments --------------------------------------------------------------
$Skill = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$Src = if ($args.Count -ge 2) { [string]$args[1] } else { '' }
$ForcedKey = if ($args.Count -ge 3) { [string]$args[2] } else { '' }

if (-not $Skill -or -not $Src) {
    Fail 'usage: collect_run.ps1 <skill-name> <conversation-path> [issue-key]'
}
if ($Skill -notin @('jira-task-assigner', 'jira-task-executor', 'jira-task-reviewer')) {
    Fail "'$Skill' is not one of the three analyzable skills (jira-task-assigner, jira-task-executor, jira-task-reviewer)."
}
if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) {
    Fail "no such transcript: $Src"
}

# ---- repo root: conversations/ always lives at the project root ------------
function Get-GitTop {
    try { $t = (& git rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -eq 0 -and $t) { return ([string]$t).Trim() } } catch { }
    return $null
}
$Root = Get-GitTop
if (-not $Root) { Fail 'not inside a git repository -- run this from the project checkout.' }
if (-not (Test-Path -LiteralPath (Join-Path $Root 'jira-sdlc-tools.env'))) {
    Fail "jira-sdlc-tools.env not found in $Root -- run this from the main checkout."
}

# ---- read + parse the transcript once ---------------------------------------
$rawLines = [System.IO.File]::ReadAllLines($Src)
$Lines = $rawLines.Count
$Uuid = [System.IO.Path]::GetFileNameWithoutExtension($Src)

$parsed = New-Object System.Collections.Generic.List[object]
foreach ($line in $rawLines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
        $obj = $line | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Fail "$Src is not valid JSON-lines."
    }
    # ConvertFrom-Json silently coerces an ISO-8601-looking string value into
    # [DateTime], which drops the offset/precision and reformats to a locale
    # string on ToString() -- capture the raw "timestamp" text straight off
    # the line instead of trusting the parsed field (same trap sync_conversations.ps1
    # works around the same way).
    $rawTs = $null
    $m = [regex]::Match($line, '"timestamp"\s*:\s*"([^"]+)"')
    if ($m.Success) { $rawTs = $m.Groups[1].Value }
    Add-Member -InputObject $obj -NotePropertyName '_rawTimestamp' -NotePropertyValue $rawTs -Force
    $parsed.Add($obj)
}

$Assistant = @($parsed | Where-Object { $_.type -eq 'assistant' }).Count
$CompactedN = @($parsed | Where-Object { $_.type -eq 'summary' }).Count
$Compacted = if ($CompactedN -gt 0) { 'yes' } else { 'no' }

$Invocations = 0
$RankFlat = ''

function Emit([string]$Status, [string]$Key, [string]$Source) {
    $isStub = if ($Assistant -eq 0) { 'yes' } else { 'no' }
    Write-Output "CONVERSATION_UUID=$Uuid"
    Write-Output "SKILL=$Skill"
    Write-Output "KEY_STATUS=$Status"
    Write-Output "ISSUE_KEY=$Key"
    Write-Output "KEY_SOURCE=$Source"
    Write-Output "KEY_RANKING=$RankFlat"
    Write-Output "LINES=$Lines"
    Write-Output "ASSISTANT_LINES=$Assistant"
    Write-Output "INVOCATIONS=$Invocations"
    Write-Output "IS_STUB=$isStub"
    Write-Output "COMPACTED=$Compacted"
}

# ---- is this transcript actually a run of <skill-name>? ---------------------
# The invocation need not be first: a session can open with /model, /usage,
# /context, /compact ... before the skill is ever called. Match namespaced
# and bare alike -- the command is /<plugin>:<skill> on a marketplace install
# but plain /<skill> when the skills are loose files or the plugin was renamed.
function Get-UserPromptTexts {
    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($o in $parsed) {
        if ($o.type -ne 'user') { continue }
        $c = $o.message.content
        if ($null -eq $c) { continue }
        if ($c -is [string]) {
            $texts.Add($c)
        } elseif ($c -is [System.Collections.IEnumerable]) {
            foreach ($b in $c) {
                if ($b -and $b.type -eq 'text') { $texts.Add([string]$b.text) }
            }
        }
    }
    return $texts
}
$AllUserText = [string]::Join("`n", (Get-UserPromptTexts))
$Cmds = @([regex]::Matches($AllUserText, '<command-name>/[^<]*</command-name>') | ForEach-Object { $_.Value })
$SkillPattern = '<command-name>/([^<:]*:)?' + [regex]::Escape($Skill) + '</command-name>'
$Invocations = @($Cmds | Where-Object { $_ -cmatch $SkillPattern }).Count

if ($Invocations -eq 0) {
    Emit 'no-invocation' '' "transcript contains no /$Skill invocation"
    [Console]::Error.WriteLine("collect_run: $Src contains no invocation of '$Skill' -- this is probably not that skill's run.")
    $Other = (@($Cmds | ForEach-Object { $_ -replace '<[^>]*>', '' } | Sort-Object -Unique)) -join ' '
    if ($Other.Trim()) {
        [Console]::Error.WriteLine("  commands this transcript does contain: $Other")
        [Console]::Error.WriteLine('  (a session may legitimately open with /model, /usage, /compact ... but the named skill must appear somewhere, and it doesn''t)')
    } else {
        [Console]::Error.WriteLine('  it contains no slash-command invocation at all.')
    }
    [Console]::Error.WriteLine('  ASK THE USER: analyze it as one of the skills listed above, or point at a different transcript. Nothing was filed.')
    exit 2
}

# ---- project key (same two spellings statuscheck.ps1 accepts) --------------
function Get-Cfg([string]$Pattern) {
    foreach ($f in @('jira-sdlc-tools.local.env', 'jira-sdlc-tools.env')) {
        $path = Join-Path $Root $f
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $val = $null
        foreach ($line in Get-Content -LiteralPath $path) {
            if ($line -match "^\s*($Pattern)\s*=(.*)$") { $val = $Matches[2].Trim() }
        }
        if ($val) { return $val }
    }
    return $null
}
$ProjectKey = Get-Cfg 'PROJECT[-_]KEY'
if (-not $ProjectKey) { Fail 'PROJECT-KEY unset in jira-sdlc-tools.env.' }

# every <PROJECT-KEY>-<n> in the file, by frequency -- context only, never
# the decision (anchored to the project key so line refs like L61-66 can't match)
$RankTop = ''
$KeyOccurrenceRe = '\b' + [regex]::Escape($ProjectKey) + '-[0-9]+\b'
$RawContent = [System.IO.File]::ReadAllText($Src)
$AllKeyHits = @([regex]::Matches($RawContent, $KeyOccurrenceRe) | ForEach-Object { $_.Value })
if ($AllKeyHits.Count -gt 0) {
    $Grouped = $AllKeyHits | Group-Object | Sort-Object Count -Descending
    $RankFlat = (($Grouped | ForEach-Object { "$($_.Count) $($_.Name)" }) -join '; ') + ';'
    $RankTop = $Grouped[0].Name
}

# ---- stub: no assistant turns, nothing to analyze ---------------------------
if ($Assistant -eq 0) {
    Emit 'stub' '' 'n/a -- stub transcript'
    [Console]::Error.WriteLine('collect_run: no assistant lines -- this is a STUB. Nothing filed. Write the short stub report and point at ~/.claude/projects/ to find the full session.')
    exit 2
}

# ---- shared tool_result helpers ---------------------------------------------
# Content blocks that are plain strings are returned as-is (preserves real
# newlines, e.g. statuscheck's markdown table). Blocks shaped as {type,text}
# contribute their .text; anything else falls back to compact JSON so a
# PROJECT-KEY-nn buried in it is still findable by regex.
function Get-ContentText($content) {
    if ($null -eq $content) { return '' }
    if ($content -is [string]) { return $content }
    if ($content -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($b in $content) {
            if ($b -is [string]) { $parts.Add($b) }
            elseif ($b -and $b.text) { $parts.Add([string]$b.text) }
            else { $parts.Add(($b | ConvertTo-Json -Compress)) }
        }
        return ($parts -join "`n")
    }
    return [string]$content
}
function Get-ToolResultFor([string]$Id) {
    foreach ($o in $parsed) {
        if ($o.type -ne 'user') { continue }
        $c = $o.message.content
        if ($c -isnot [System.Collections.IEnumerable] -or $c -is [string]) { continue }
        foreach ($b in $c) {
            if ($b -and $b.type -eq 'tool_result' -and [string]$b.tool_use_id -eq $Id) {
                return (Get-ContentText $b.content)
            }
        }
    }
    return ''
}
function Find-FirstToolResultLine([string]$Pattern) {
    foreach ($o in $parsed) {
        if ($o.type -ne 'user') { continue }
        $c = $o.message.content
        if ($c -isnot [System.Collections.IEnumerable] -or $c -is [string]) { continue }
        foreach ($b in $c) {
            if ($b -and $b.type -eq 'tool_result') {
                $text = Get-ContentText $b.content
                foreach ($ln in ($text -split "`n")) {
                    if ($ln -match $Pattern) { return $ln }
                }
            }
        }
    }
    return $null
}

# ---- recover the key from this skill's own anchor ---------------------------
$Key = ''; $Source = ''; $Status = ''
if ($ForcedKey) {
    $Key = $ForcedKey; $Source = 'explicit argument'; $Status = 'given'
} elseif ($Skill -eq 'jira-task-assigner') {
    # the assigner mints the key: first `workitem create` (not `comment create`)
    $CreateId = $null
    foreach ($o in $parsed) {
        if ($o.type -ne 'assistant') { continue }
        $content = $o.message.content
        if ($content -isnot [System.Collections.IEnumerable] -or $content -is [string]) { continue }
        foreach ($b in $content) {
            if ($b -and $b.type -eq 'tool_use' -and $b.name -eq 'Bash' -and ([string]$b.input.command) -match 'workitem\s+create') {
                $CreateId = [string]$b.id
                break
            }
        }
        if ($CreateId) { break }
    }
    if ($CreateId) {
        $Res = Get-ToolResultFor $CreateId
        $ParsedKey = $null
        try {
            $j = $Res | ConvertFrom-Json -ErrorAction Stop
            if ($j -and $j.key) { $ParsedKey = [string]$j.key }   # --json form
        } catch { }
        if (-not $ParsedKey) {
            $m = [regex]::Match($Res, $KeyOccurrenceRe)           # text/browse-URL form
            if ($m.Success) { $ParsedKey = $m.Value }
        }
        if ($ParsedKey) {
            $Key = $ParsedKey; $Status = 'expected'; $Source = 'acli workitem create result (the issue this run created)'
        } else {
            $Status = 'unexpected'; $Source = "workitem create ran but its result carried no $ProjectKey-<n> (create failed, or output was truncated)"
        }
    } else {
        $Status = 'unexpected'; $Source = "no 'acli jira workitem create' call in the transcript -- this run never created an issue"
    }
} else {
    # executor/reviewer derive the key from the branch -- statuscheck reports it
    $Row = Find-FirstToolResultLine '^\|\s*issue_key\s*\|'
    $Key1 = $null
    if ($Row) { $m = [regex]::Match($Row, $KeyOccurrenceRe); if ($m.Success) { $Key1 = $m.Value } }
    if ($Key1) {
        $Key = $Key1; $Status = 'expected'; $Source = "statuscheck issue_key row (derived from the worktree's branch)"
    } else {
        $Brow = Find-FirstToolResultLine '^\|\s*branch\s*\|'
        $Key2 = $null
        if ($Brow) { $m = [regex]::Match($Brow, $KeyOccurrenceRe); if ($m.Success) { $Key2 = $m.Value } }
        if ($Key2) {
            $Key = $Key2; $Status = 'expected'; $Source = 'statuscheck branch row (issue_key row carried no key)'
        } elseif ($Row) {
            $Status = 'unexpected'; $Source = "statuscheck ran but resolved no issue key: $Row"
        } else {
            $Status = 'unexpected'; $Source = 'no statuscheck issue_key row -- the run never got past the healthcheck, or it was truncated'
        }
    }
}

# ---- nothing trustworthy -> file nothing, hand it to the human -------------
if ($Status -ne 'expected' -and $Status -ne 'given') {
    Emit $Status '' $Source
    [Console]::Error.WriteLine('collect_run: could not recover the issue key where ' + $Skill + ' is supposed to produce it.')
    [Console]::Error.WriteLine("  reason : $Source")
    if ($RankFlat) {
        [Console]::Error.WriteLine("  the transcript does mention: $RankFlat")
        [Console]::Error.WriteLine('  -- but a mention is not the run''s subject (a run can cite an unrelated issue), so nothing was filed.')
    } else {
        [Console]::Error.WriteLine("  the transcript mentions no $ProjectKey-<n> at all.")
    }
    [Console]::Error.WriteLine('  ASK THE USER which issue key to file under, then re-run:')
    [Console]::Error.WriteLine("    collect_run.ps1 $Skill $Src <issue-key>")
    exit 2
}

# ---- run metrics --------------------------------------------------------
# All measured, none inferred. Two traps this avoids (same as the bash twin):
#  * one API response is split across several assistant lines (one per
#    content block), and every one of them carries the SAME usage object --
#    summing per line overcounts. Dedup by message.id.
#  * content blocks are NOT duplicated across those lines, so tool_use
#    blocks must be counted over every line, not the deduped set.
# Scope is the skill's own turns via attributionSkill, so pre/post-skill
# chatter and other skills in the same session don't pollute the numbers.
function Get-DedupByMessageId($list) {
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($o in $list) {
        $id = [string]$o.message.id
        if (-not $id) { $id = [string]([guid]::NewGuid()) }
        if ($seen.Add($id)) { $result.Add($o) }
    }
    return $result
}
function Get-Tally($items) {
    if (-not $items -or $items.Count -eq 0) { return '' }
    $grouped = $items | Group-Object -Property name | Sort-Object Count -Descending
    return (($grouped | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ' ')
}
function ConvertTo-EpochSeconds([string]$s) {
    if (-not $s) { return $null }
    try {
        $dto = [System.DateTimeOffset]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        return $dto.ToUnixTimeMilliseconds() / 1000.0
    } catch { return $null }
}

$MainList = New-Object System.Collections.Generic.List[object]   # non-sidechain assistant lines for this skill
$AllList = New-Object System.Collections.Generic.List[object]    # + sidechain, same skill
foreach ($o in $parsed) {
    if ($o.type -ne 'assistant') { continue }
    if (-not ([string]$o.attributionSkill).EndsWith($Skill)) { continue }
    $AllList.Add($o)
    if ($o.isSidechain -ne $true) { $MainList.Add($o) }
}
$DMain = Get-DedupByMessageId $MainList
$DSide = Get-DedupByMessageId (@($AllList | Where-Object { $_.isSidechain -eq $true }))

$Calls = New-Object System.Collections.Generic.List[object]
foreach ($o in $MainList) {
    $content = $o.message.content
    if ($content -isnot [System.Collections.IEnumerable] -or $content -is [string]) { continue }
    foreach ($b in $content) {
        if ($b -and $b.type -eq 'tool_use') { $Calls.Add([pscustomobject]@{ id = [string]$b.id; name = [string]$b.name }) }
    }
}
$ErrIds = New-Object System.Collections.Generic.HashSet[string]
foreach ($o in $parsed) {
    if ($o.type -ne 'user') { continue }
    $c = $o.message.content
    if ($c -isnot [System.Collections.IEnumerable] -or $c -is [string]) { continue }
    foreach ($b in $c) {
        if ($b -and $b.type -eq 'tool_result' -and $b.is_error -eq $true) { [void]$ErrIds.Add([string]$b.tool_use_id) }
    }
}
$ErrCalls = @($Calls | Where-Object { $ErrIds.Contains($_.id) })

$Tin = 0; $Tout = 0; $Tcr = 0; $Tcw = 0
$ModelSet = New-Object System.Collections.Generic.List[string]
foreach ($o in $DMain) {
    $u = $o.message.usage
    if ($u) {
        $Tin += [int]$u.input_tokens; $Tout += [int]$u.output_tokens
        $Tcr += [int]$u.cache_read_input_tokens; $Tcw += [int]$u.cache_creation_input_tokens
    }
    $mdl = [string]$o.message.model
    if ($mdl -and ($ModelSet -notcontains $mdl)) { $ModelSet.Add($mdl) }
}
$Models = ($ModelSet | Sort-Object) -join ' '

$Timestamps = @($AllList | ForEach-Object { $_._rawTimestamp } | Where-Object { $_ } | Sort-Object)
$First = ''; $Last = ''; $Span = 0
if ($Timestamps.Count -gt 0) {
    $First = $Timestamps[0]; $Last = $Timestamps[-1]
    $e1 = ConvertTo-EpochSeconds $First; $e2 = ConvertTo-EpochSeconds $Last
    if ($null -ne $e1 -and $null -ne $e2) { $Span = [math]::Round($e2 - $e1, 3) }
}

# ---- create + copy (idempotent) ---------------------------------------------
# Keep conversations/ out of git before anything lands in it -- same rationale
# as the bash twin: transcripts are raw session logs and this marketplace is
# public, so the guard ships with the script rather than relying on manual setup.
$ConversationsDir = Join-Path $Root 'conversations'
if (-not (Test-Path -LiteralPath $ConversationsDir)) { New-Item -ItemType Directory -Path $ConversationsDir -Force | Out-Null }
$GitignorePath = Join-Path $ConversationsDir '.gitignore'
if (-not (Test-Path -LiteralPath $GitignorePath)) {
    Set-Content -LiteralPath $GitignorePath -Value '*'
    [Console]::Error.WriteLine('collect_run: created conversations/.gitignore (*) -- transcripts stay local, never committed.')
}
$Dest = Join-Path $ConversationsDir $Key
if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force | Out-Null }
Copy-Item -LiteralPath $Src -Destination (Join-Path $Dest "$Uuid.jsonl") -Force

# Transcript byte size of the profiled source (Length is the byte count, matching
# the bash twin's `wc -c`). Measured HERE — the only layer that holds $Src — so
# collect_feature can thread it through and feature_report re-measures nothing.
$Bytes = (Get-Item -LiteralPath $Src).Length

$Rel = "conversations/$Key"
Emit $Status $Key $Source
Write-Output "REPORT_DIR=$Rel"
Write-Output "TRANSCRIPT_COPY=$Rel/$Uuid.jsonl"
Write-Output "TRANSCRIPT_BYTES=$Bytes"
Write-Output "SKILL_TURNS=$($DMain.Count)"
Write-Output "SKILL_LINES=$($AllList.Count)"
Write-Output "SIDECHAIN_TURNS=$($DSide.Count)"
Write-Output "TOKENS_IN=$Tin"
Write-Output "TOKENS_OUT=$Tout"
Write-Output "TOKENS_CACHE_READ=$Tcr"
Write-Output "TOKENS_CACHE_WRITE=$Tcw"
Write-Output "MODELS=$Models"
Write-Output "FIRST_TS=$First"
Write-Output "LAST_TS=$Last"
Write-Output "WALL_CLOCK_S=$Span"
Write-Output "TOOL_CALLS=$($Calls.Count)"
Write-Output "TOOLS_USED=$(Get-Tally $Calls)"
Write-Output "TOOL_ERRORS=$($ErrCalls.Count)"
Write-Output "TOOL_ERRORS_BY_TOOL=$(Get-Tally $ErrCalls)"

# an anchor key that isn't the loudest key is normal, not suspicious --
# say so once rather than letting the ranking raise a false alarm
if ($RankTop -and $RankTop -ne $Key) {
    [Console]::Error.WriteLine("collect_run: note -- '$RankTop' is mentioned more often than '$Key', but '$Key' is what this run acted on ($Source). Filed under '$Key'.")
}
[Console]::Error.WriteLine("collect_run: $Rel is git-ignored -- the transcript is a raw session log (absolute paths, emails, instance URLs, whatever the run printed) and stays local. Don't force-add it.")
