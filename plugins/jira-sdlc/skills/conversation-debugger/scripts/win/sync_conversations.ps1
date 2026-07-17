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
# Claude Code names each project folder after the session's cwd with every path
# separator replaced by '-'. On Windows that means '/', '.', ':' and '\' all map
# to '-' (verified: C:\Users\u\proj -> C--Users-u-proj); the bash twin, seeing
# only POSIX cwds, replaces just '/' and '.'. We reproduce the Windows mapping to
# locate the two folders precisely instead of guessing.
#
# --attach delegates to the shared uploader _shared/scripts/jira_attach.sh (kept
# in one place, no win twin), so --attach needs bash — found on PATH, or derived
# from the installed Git for Windows (Resolve-BashPath). The read-only detection
# path above needs neither bash nor python3. (jira_attach.sh itself still needs
# python3 + curl to reach Jira's REST API, exactly as on POSIX.)
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

# ---- transcript store ------------------------------------------------------
# Claude Code-specific by nature: it reads Claude Code's own transcript store.
# Other harnesses keep session logs elsewhere or not at all, so degrade honestly.
$Projects = $env:CLAUDE_PROJECTS_DIR
if (-not $Projects) { $Projects = Join-Path $HOME '.claude/projects' }
if (-not (Test-Path -LiteralPath $Projects -PathType Container)) {
    [Console]::Error.WriteLine("sync_conversations: no transcript store at $Projects — this builtin is specific to Claude Code (it attaches Claude Code conversation logs). Nothing to sync on this agent.")
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

# ---- locate the two project folders ----------------------------------------
# Main checkout root: the first entry of `git worktree list` is always the main
# checkout, even when this runs from inside a linked worktree.
$MainRoot = $null
try {
    $wl = & git worktree list --porcelain 2>$null
    foreach ($line in $wl) { if ($line -match '^worktree (.+)$') { $MainRoot = $Matches[1].Trim(); break } }
} catch { }
if (-not $MainRoot) {
    try { $t = (& git rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -eq 0 -and $t) { $MainRoot = ([string]$t).Trim() } } catch { }
}
if (-not $MainRoot) {
    [Console]::Error.WriteLine("sync_conversations: not inside a git repository (cwd: $($PWD.Path))")
    exit 1
}

# cwd -> project-folder name: replace every path separator with '-'. On Windows
# that is '/', '.', ':' and '\' (git prints C:/... forward-slash + drive colon).
function Convert-ToFolderName([string]$s) { return ($s -replace '[/.:\\]', '-') }

$MainFolder = Join-Path $Projects (Convert-ToFolderName $MainRoot)

# Worktree folder: a project folder whose name ends in exactly 'worktree-<KEY>'.
# The trailing anchor is boundary-safe (*worktree-JST-9 can't match ...worktree-JST-93).
$WtFolder = $null
$wtMatch = Get-ChildItem -LiteralPath $Projects -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*worktree-$Key" } | Select-Object -First 1
if ($wtMatch) { $WtFolder = $wtMatch.FullName }

# ---- gather candidate files ------------------------------------------------
# W = worktree (all sessions); M = main-checkout assigner-command session that
# also names the key. Selection among M happens below.
$wfiles = New-Object System.Collections.Generic.List[string]
if ($WtFolder) {
    Get-ChildItem -LiteralPath $WtFolder -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        ForEach-Object { $wfiles.Add($_.FullName) }
}

$mfiles = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $MainFolder -PathType Container) {
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

function Resolve-BashPath {
    # --attach delegates to the bash uploader, so find a bash. Prefer one on
    # PATH; otherwise derive it from git (git.exe in Git\cmd or Git\bin → the
    # sibling Git\bin\bash.exe), then fall back to the standard install roots.
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $root = Split-Path -Parent (Split-Path -Parent $git.Source)
        if ($root) { $cand = Join-Path $root 'bin\bash.exe'; if (Test-Path -LiteralPath $cand) { return $cand } }
    }
    foreach ($cand in @(
            (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe'))) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { return $cand }
    }
    return $null
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

# ---- --attach: hand the computed paths to the shared idempotent uploader ----
# The uploader has no win twin (see header), so this leg needs bash on PATH.
if ($DoAttach) {
    Write-Output ''
    if ($attach.Count -eq 0) {
        Write-Output 'sync_conversations: nothing to attach.'
    } else {
        $bashExe = Resolve-BashPath
        if (-not $bashExe) {
            [Console]::Error.WriteLine("sync_conversations: --attach needs bash (Git for Windows) to run the shared uploader jira_attach.sh, which has no PowerShell port. Install Git for Windows, or attach the paths above by hand.")
            exit 1
        }
        $attachScript = Join-Path $PSScriptRoot '..\..\..\_shared\scripts\jira_attach.sh'
        $attachScript = (Resolve-Path -LiteralPath $attachScript).Path -replace '\\', '/'
        $bargs = @($attachScript)
        if ($DryRun) { $bargs += '--dry-run' }
        $bargs += $Key
        foreach ($p in $attach) { $bargs += $p }
        & $bashExe @bargs
        exit $LASTEXITCODE
    }
}
