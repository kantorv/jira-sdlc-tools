# sync_conversations.ps1 <ISSUE-KEY> [--title "<summary>"] [--created "<iso8601>"]
#                        [--attach] [--dry-run]
#
# Windows (PowerShell 5.1+) port of ../posix/sync_conversations.sh. Mirrors the
# bash contract exactly: same arguments, same grouped-listing + "=== attachment
# paths ===" stdout shape, same exit codes. The heavy detection logic the bash
# original delegates to an embedded python3 program is reimplemented natively
# here (ConvertFrom-Json, [DateTimeOffset]) — no bash, no python3 on this path.
#
# Find the Claude Code conversation transcripts (.jsonl under ~/.claude/projects)
# that belong to a Jira issue, print them grouped, and end with a machine-readable
# list of the files to attach — splitting by provenance exactly as the bash twin:
#   * WORKTREE (certain, take ALL) — every session filed under the issue's
#     worktree folder is this issue's.
#   * MAIN checkout (take exactly ONE — the assigner session that CREATED the
#     issue) — pinned by layering three signals, strongest last: it invoked
#     /jira-sdlc:jira-task-assigner, the issue TITLE appears in it, and the Jira
#     `created` instant falls inside the session's first..last timestamp window.
#
# The two ~/.claude/projects transcript folders are pinned by config, not inferred
# from git / the cwd encoding: CONVERSATIONS_MAINREPO_PATH is the main checkout's
# folder (used as-is), and CONVERSATIONS_WORKTREES_PREFFIX is the prefix of the
# worktrees' folders — this issue's is <prefix>worktree-<KEY>. Both come from
# jira-sdlc-tools(.local).env and are validated below. Pinning them in config (vs.
# letting this port / the agent compute arbitrary paths) is deliberate: it scopes
# this read-only builtin to the configured trees and nothing else under
# ~/.claude/projects.
#
# --attach delegates to the sibling uploader jira_attach.ps1 (in this same win/
# folder), so this path is fully native — no bash, no python3, just the same
# PowerShell runtime already running us. (jira_attach.ps1 does its own Jira REST
# calls via Invoke-WebRequest, the win twin of jira_attach.sh's curl.)
#
# NOTE on the offline overrides: pass --title/--created as SPACE-separated quoted
# tokens (--created "2026-01-01T00:00:00Z"). Under `pwsh -File`, the glued
# `--created=<value>` form is split by PowerShell's own CLI parser at any colon
# in the value before this script sees it — the bash twin's `=` form is fine, the
# ps1's is not. The skill never passes these (it self-fetches via acli), so this
# only affects manual/offline runs.
#
# Read-only without --attach: never writes, transitions, or uploads. Exit 1 only
# on a usage / environment error.

$ErrorActionPreference = 'Stop'

# ---- arguments -------------------------------------------------------------
$Key = ''; $Title = ''; $Created = ''; $DoAttach = $false; $DryRun = $false
$argv = @($args)
for ($i = 0; $i -lt $argv.Count; $i++) {
    $a = [string]$argv[$i]
    switch -Regex ($a) {
        '^--title='   { $Title   = $a.Substring(8); continue }
        '^--title$'   { if ($i + 1 -lt $argv.Count) { $Title   = [string]$argv[++$i] } continue }
        '^--created=' { $Created = $a.Substring(10); continue }
        '^--created$' { if ($i + 1 -lt $argv.Count) { $Created = [string]$argv[++$i] } continue }
        '^--attach$'  { $DoAttach = $true; continue }
        '^--dry-run$' { $DryRun  = $true; continue }
        default       { if (-not $Key) { $Key = $a } continue }
    }
}

if ($Key -notmatch '^[A-Za-z]*-[0-9]*$' -or $Key -eq '-') {
    $got = if ($Key) { $Key } else { '<none>' }
    [Console]::Error.WriteLine("sync_conversations: need an issue key, e.g. sync_conversations.ps1 JST-93 [--attach] [--dry-run] [--title ...] [--created ...] (got '$got')")
    exit 1
}

# ---- transcript folders: pinned by config, both mandatory ------------------
# Resolve from jira-sdlc-tools(.local).env, not the process environment: the
# Get-Cfg parser mirrors statuscheck.ps1 / get_assignee_email.ps1 (same NAME =
# value match, local-overrides-team, last match in a file wins). Reading config
# files rather than $env is what keeps the scoping trustworthy — the agent can't
# widen it by setting a variable.
function Get-GitTop {
    try { $t = (& git rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -eq 0 -and $t) { return ([string]$t).Trim() } } catch { }
    return $null
}
$CfgDir = Get-GitTop
if (-not $CfgDir) { $CfgDir = (Get-Location).Path }
function Get-Cfg {
    param([string]$Pattern)
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

$MainFolder = Get-Cfg 'CONVERSATIONS_MAINREPO_PATH'
$WtPrefix   = Get-Cfg 'CONVERSATIONS_WORKTREES_PREFFIX'
if (-not $MainFolder -or -not (Test-Path -LiteralPath $MainFolder -PathType Container)) {
    $got = if ($MainFolder) { $MainFolder } else { '<unset>' }
    [Console]::Error.WriteLine("sync_conversations: CONVERSATIONS_MAINREPO_PATH must name an existing directory (the main checkout's ~/.claude/projects transcript folder); set it in $CfgDir/jira-sdlc-tools.local.env. Got '$got'")
    exit 1
}
if (-not $WtPrefix) {
    [Console]::Error.WriteLine("sync_conversations: CONVERSATIONS_WORKTREES_PREFFIX is unset — set it in $CfgDir/jira-sdlc-tools.local.env (the ~/.claude/projects prefix of the worktrees' transcript folders; this issue's is <prefix>worktree-<KEY>).")
    exit 1
}
# This issue's worktree folder is the prefix + worktree-<KEY>. A missing folder
# means the issue never had a worktree (nothing to sync) — stop rather than guess.
$WtFolder = "${WtPrefix}worktree-$Key"
if (-not (Test-Path -LiteralPath $WtFolder -PathType Container)) {
    [Console]::Error.WriteLine("sync_conversations: no worktree transcript folder for $Key at '$WtFolder' (CONVERSATIONS_WORKTREES_PREFFIX + worktree-$Key) — if $Key never had a worktree there is nothing to sync.")
    exit 1
}

# ---- self-fetch title/created from Jira (both pin the creating session) -----
# --title/--created stay as overrides that skip the fetch, keeping the detector
# runnable offline.
if ((-not $Title -or -not $Created) -and (Get-Command acli -ErrorAction SilentlyContinue)) {
    try {
        $rawMeta = (& acli jira workitem view $Key --json --fields 'summary,created' 2>$null) -join "`n"
        if (-not $Title) {
            $meta = $rawMeta | ConvertFrom-Json
            if ($meta -and $meta.fields) { $Title = [string]$meta.fields.summary }
        }
        if (-not $Created) {
            # Pull `created` from the raw JSON, NOT via ConvertFrom-Json: PowerShell
            # coerces an ISO-8601 date string to [datetime], dropping the offset and
            # reformatting to a locale string ConvertTo-Epoch can't reparse.
            $cm = [regex]::Match($rawMeta, '"created"\s*:\s*"([^"]+)"')
            if ($cm.Success) { $Created = $cm.Groups[1].Value }
        }
    } catch { }
}

# ---- gather candidate files ------------------------------------------------
# W = worktree (all sessions); M = main-checkout assigner-command session that
# also names the key. Selection among M happens below. Both folders were
# validated as existing directories above.
$wfiles = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath $WtFolder -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
    ForEach-Object { $wfiles.Add($_.FullName) }

$mfiles = New-Object System.Collections.Generic.List[string]
# word-boundary key match, mirroring `grep -wF` (word chars = [A-Za-z0-9_]).
# -cmatch (case-sensitive) to mirror grep -E / -wF, not the case-insensitive -match.
$keyRe = '(?<![A-Za-z0-9_])' + [regex]::Escape($Key) + '(?![A-Za-z0-9_])'
Get-ChildItem -LiteralPath $MainFolder -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object {
    $content = $null
    try { $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop } catch { }
    if ($content -and
        $content -cmatch 'command-name>/?jira-sdlc:jira-task-assigner' -and
        $content -cmatch $keyRe) {
        $mfiles.Add($_.FullName)
    }
}

# ---- helpers (native reimplementation of the bash python block) ------------
function ConvertTo-Epoch([string]$s) {
    # Parse both transcript (…Z) and Jira (…+0300) ISO forms to epoch seconds.
    if (-not $s) { return $null }
    $s = $s.Trim().Replace('Z', '+00:00')
    if ($s -match '([+-]\d{2})(\d{2})$') { $s = $s.Substring(0, $s.Length - 5) + $Matches[1] + ':' + $Matches[2] }
    try {
        $dto = [System.DateTimeOffset]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
        return $dto.ToUnixTimeMilliseconds() / 1000.0
    } catch { return $null }
}

$CreatedE = ConvertTo-Epoch $Created

function Get-Clean([string]$text) {
    $m = [regex]::Match($text, '<command-name>\s*/?([^<]+?)\s*</command-name>')
    if ($m.Success) { $v = $m.Groups[1].Value; return $v.Substring(0, [Math]::Min(52, $v.Length)) }
    $m = [regex]::Match($text, 'running (/[A-Za-z0-9:_-]+)')
    if ($m.Success) { $v = $m.Groups[1].Value; return $v.Substring(0, [Math]::Min(52, $v.Length)) }
    $v = (($text -replace '<[^>]+>', ' ') -split '\s+' | Where-Object { $_ -ne '' }) -join ' '
    return $v.Substring(0, [Math]::Min(52, $v.Length))
}

function Get-Summary([string]$path) {
    try {
        foreach ($line in [System.IO.File]::ReadLines($path)) {
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if ($o.type -ne 'user') { continue }
            $c = $null
            if ($o.message) { $c = $o.message.content }
            $t = $null
            if ($c -is [string]) {
                $t = $c
            } elseif ($c -is [System.Collections.IEnumerable]) {
                foreach ($b in $c) {
                    if ($b -is [string]) { $t = $b; break }
                    if ($b -and $b.type -eq 'text') { $t = $b.text; break }
                }
            }
            if ($t) { $cl = Get-Clean $t; if ($cl) { return $cl } }
        }
    } catch [System.IO.IOException] { return '?' }
      catch { return '?' }
    return '(no user message)'
}

function Get-Scan([string]$path) {
    # Return @{ title=<bool>; first=<epoch?>; last=<epoch?> } for a main candidate.
    $hasTitle = $false; $first = $null; $last = $null
    try {
        foreach ($line in [System.IO.File]::ReadLines($path)) {
            if ($Title -and -not $hasTitle -and $line.Contains($Title)) { $hasTitle = $true }
            $m = [regex]::Match($line, '"timestamp":"([^"]+)"')
            if ($m.Success) {
                $e = ConvertTo-Epoch $m.Groups[1].Value
                if ($null -ne $e) { if ($null -eq $first) { $first = $e }; $last = $e }
            }
        }
    } catch { }
    return @{ title = $hasTitle; first = $first; last = $last }
}

function Format-Row([string]$path) {
    # Returns @{ text=<two-line string>; mtime=<DateTime> } or $null on stat error.
    try { $item = Get-Item -LiteralPath $path -ErrorAction Stop } catch { return $null }
    $dt = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
    $kb = [Math]::Round($item.Length / 1024.0, [System.MidpointRounding]::ToEven)
    $sz = ('{0,5}' -f [int]$kb)
    $summary = Get-Summary $path
    return @{ text = "  * $dt  $sz KB  $summary`n    $path"; mtime = $item.LastWriteTime }
}

# ---- pick the single creating session out of the main candidates ------------
$scored = New-Object System.Collections.Generic.List[object]
foreach ($p in $mfiles) {
    $s = Get-Scan $p
    $brk = ($null -ne $s.first -and $null -ne $s.last -and $null -ne $CreatedE -and
            $s.first -le $CreatedE -and $CreatedE -le $s.last)
    $scored.Add([pscustomobject]@{ path = $p; title = [bool]$s.title; bracket = [bool]$brk; first = $s.first; last = $s.last })
}

$tb = @($scored | Where-Object { $_.title -and $_.bracket })
$br = @($scored | Where-Object { $_.bracket })
$ti = @($scored | Where-Object { $_.title })
$selected = $null; $reason = ''
if     ($tb.Count -eq 1)     { $selected = $tb[0]; $reason = 'title + creation-time match' }
elseif ($br.Count -eq 1)     { $selected = $br[0]; $reason = 'creation-time bracket' }
elseif ($ti.Count -eq 1)     { $selected = $ti[0]; $reason = 'title match' }
elseif ($scored.Count -eq 1) { $selected = $scored[0]; $reason = 'only assigner session found' }
elseif ($tb.Count -gt 0)     { $selected = $tb[0]; $reason = 'title + creation-time match (multiple; took first)' }

# ---- build the grouped output ----------------------------------------------
$out = New-Object System.Collections.Generic.List[string]
$attach = New-Object System.Collections.Generic.List[string]

if ($wfiles.Count -gt 0) {
    $out.Add('')
    $out.Add("### Worktree (worktree-$Key) — all sessions, attached")
    $rows = @()
    foreach ($p in $wfiles) { $r = Format-Row $p; if ($r) { $rows += $r } }
    foreach ($r in ($rows | Sort-Object { $_.mtime } -Descending)) { $out.Add($r.text) }
    foreach ($p in $wfiles) { $attach.Add($p) }
}

$out.Add('')
$out.Add("### Main checkout — the assigner session that created $Key")
if ($selected) {
    $r = Format-Row $selected.path
    if ($r) { $out.Add($r.text + "    ↳ selected by: $reason") }
    $attach.Add($selected.path)
    $others = @($scored | Where-Object { $_.path -ne $selected.path })
    if ($others.Count -gt 0) {
        $out.Add('')
        $out.Add("  other assigner sessions mentioning $Key (NOT attached):")
        foreach ($s in $others) { $r = Format-Row $s.path; if ($r) { $out.Add($r.text) } }
    }
} else {
    if ($scored.Count -eq 0) {
        $out.Add('  (none found — the issue may have been created without the assigner, e.g. an ad-hoc Bug; only the worktree sessions above apply)')
    } else {
        $out.Add('  (could not pin a single creating session — candidates below need a human pick; pass --title and --created for an automatic match)')
        foreach ($s in $scored) { $r = Format-Row $s.path; if ($r) { $out.Add($r.text) } }
    }
}

$out.Add('')
$out.Add("=== attachment paths ($($attach.Count)) ===")
foreach ($p in $attach) { $out.Add($p) }
if ($attach.Count -eq 0) { $out.Add('(none)') }

# Always show the grouped detection + path list.
foreach ($line in $out) { Write-Output $line }

# ---- --attach: hand the computed paths to the sibling idempotent uploader ---
# jira_attach.ps1 lives beside this script (win/), so this leg is fully native —
# no bash, same PowerShell runtime that is already running us.
if ($DoAttach) {
    Write-Output ''
    if ($attach.Count -eq 0) {
        Write-Output 'sync_conversations: nothing to attach.'
    } else {
        $attachScript = Join-Path $PSScriptRoot 'jira_attach.ps1'
        $pargs = @()
        if ($DryRun) { $pargs += '--dry-run' }
        $pargs += $Key
        foreach ($p in $attach) { $pargs += $p }
        & $attachScript @pargs
        exit $LASTEXITCODE
    }
}
