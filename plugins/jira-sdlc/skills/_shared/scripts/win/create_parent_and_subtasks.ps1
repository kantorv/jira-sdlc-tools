# create_parent_and_subtasks.ps1 — Windows (PowerShell 5.1+) twin of
# create_parent_and_subtasks.sh.
#
# Wraps `jira.ps1 issue create` (REST v3), the native Invoke-WebRequest port.
# See ../jira-api-reference.md.
#
# Create a Jira parent work item plus N sub-tasks, driven by a manifest.
# Reads <PROJECT-KEY> from .jst/jira-sdlc-tools.env (override with -Project or
# $env:PROJECT_KEY); run from within the repo/worktree — jira.ps1 resolves its
# config from the git top-level. Creates as -Role (default assigner) so the created issues'
# creator/reporter is that role's account.
#
# subtasks-dir must contain:
#   manifest.tsv   — one row per sub-task: <name>\t<summary>
#   <name>.md      — the sub-task body (one file per manifest row name)
#
# Usage:
#   pwsh -File create_parent_and_subtasks.ps1 `
#     -ParentSummary "..." -ParentBody ./parent.md -SubtasksDir ./sub `
#     [-ParentType Story] [-SubtaskType Subtask] `
#     [-Project PROJ] [-Role assigner] [-KeysOut ./keys.tsv] [-DryRun]

param(
    [string]$ParentSummary,
    [string]$ParentBody,
    [string]$SubtasksDir,
    [string]$ParentType  = 'Story',
    [string]$SubtaskType = 'Subtask',
    [string]$Project     = '',
    [string]$Role        = 'assigner',
    [string]$KeysOut     = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$jiraPs = Join-Path $PSScriptRoot 'jira.ps1'
$psExe  = $null
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExe = 'pwsh'
} elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
    $psExe = 'powershell'
}
if (-not $psExe) { [Console]::Error.WriteLine('create_parent_and_subtasks: no PowerShell runtime (pwsh/powershell) found to run jira.ps1.'); exit 1 }

# --- resolve project key from .jst/jira-sdlc-tools.env if not given ----------
# Anchored at the git top-level (like jira.ps1) rather than walked up from cwd,
# so it resolves the same from any subdirectory.
if (-not $Project) {
    $cfgRoot = $null
    try { $t = (& git rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -eq 0 -and $t) { $cfgRoot = ([string]$t).Trim() } } catch { }
    if (-not $cfgRoot) { $cfgRoot = (Get-Location).Path }
    $envfile = Join-Path $cfgRoot '.jst/jira-sdlc-tools.env'
    if (Test-Path -LiteralPath $envfile) {
        $m = $null
        foreach ($line in Get-Content -LiteralPath $envfile) {
            if ($line -match '^PROJECT[-_]KEY=(.+)$') { $m = $Matches[1].Trim() }
        }
        if ($m) { $Project = $m }
    }
    if (-not $Project -and $env:PROJECT_KEY) { $Project = $env:PROJECT_KEY }
}
if (-not $Project) {
    [Console]::Error.WriteLine('ERROR: no project key. Pass -Project or run inside a repo with .jst/jira-sdlc-tools.env.')
    exit 1
}

# --- validate args ----------------------------------------------------------
$miss = 0
if (-not $ParentSummary) { [Console]::Error.WriteLine('ERROR: -ParentSummary is required'); $miss = 1 }
if (-not $ParentBody)     { [Console]::Error.WriteLine('ERROR: -ParentBody is required');     $miss = 1 }
if (-not $SubtasksDir)   { [Console]::Error.WriteLine('ERROR: -SubtasksDir is required');    $miss = 1 }
if ($miss) { exit 1 }
if (-not (Test-Path -LiteralPath $ParentBody))                        { [Console]::Error.WriteLine("ERROR: parent body not found: $ParentBody"); exit 1 }
if (-not (Test-Path -LiteralPath $SubtasksDir -PathType Container))   { [Console]::Error.WriteLine("ERROR: subtasks dir not found: $SubtasksDir"); exit 1 }
$manifest = Join-Path $SubtasksDir 'manifest.tsv'
if (-not (Test-Path -LiteralPath $manifest))                          { [Console]::Error.WriteLine("ERROR: no manifest.tsv in $SubtasksDir"); exit 1 }
if (-not $KeysOut) { $KeysOut = Join-Path $SubtasksDir 'created-keys.tsv' }

function Test-IssueKey { param([string]$S) return ($S -match '^[A-Za-z][A-Za-z0-9]*-[0-9]+$') }

# jira.ps1 issue create prints the new key directly on success (runs in its own
# process — it calls `exit`). Errors go to stderr + a non-zero exit.
function New-Issue {
    param([string]$Type, [string]$Summary, [string]$Body, [string]$Parent = '')
    $a = @('-NoProfile', '-File', $jiraPs, '--role', $Role, 'issue', 'create',
           '--project', $Project, '--type', $Type, '--summary', $Summary, '--desc-file', $Body)
    if ($Parent) { $a += @('--parent', $Parent) }
    return (& $psExe @a 2>&1)
}

Write-Output "Project: $Project"
Write-Output "Parent type: $ParentType   sub-task type: $SubtaskType   role: $Role"
if ($DryRun) { Write-Output '(dry run — no issues will be created)' }
Write-Output ''

# --- create parent ----------------------------------------------------------
if ($DryRun) {
    $ParentKey = '<dry-run-parent>'
    Write-Output "[parent] jira.ps1 --role $Role issue create --project $Project --type $ParentType --summary ""$ParentSummary"" --desc-file $ParentBody"
} else {
    $out = (New-Issue $ParentType $ParentSummary $ParentBody 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not (Test-IssueKey $out)) {
        [Console]::Error.WriteLine('ERROR: could not create the parent. jira.ps1 said:')
        foreach ($l in ($out -split "`n")) { [Console]::Error.WriteLine("      $l") }
        exit 1
    }
    $ParentKey = $out
}
Write-Output "parent -> $ParentKey"
Write-Output ''

# --- create sub-tasks from manifest.tsv -------------------------------------
Set-Content -LiteralPath $KeysOut -Value $null -NoNewline
$ok = 0; $fail = 0
foreach ($line in Get-Content -LiteralPath $manifest) {
    if ($line -match '^\s*$') { continue }
    $parts   = $line -split "`t", 2
    $name    = $parts[0]
    $summary = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    if (-not $name) { continue }
    if ($name -like '#*') { continue }
    if (-not $summary) { [Console]::Error.WriteLine("WARN: manifest row '$name' has no summary; skipping"); continue }

    $body = Join-Path $SubtasksDir "$name.md"
    if (-not (Test-Path -LiteralPath $body)) {
        [Console]::Error.WriteLine("WARN: body file not found for '$name' ($body); skipping")
        Add-Content -LiteralPath $KeysOut -Value ("{0}`t{1}`t{2}" -f $name, 'MISSING', '-')
        $fail++; continue
    }

    if ($DryRun) {
        Write-Output "[subtask] $name -> jira.ps1 ... --type $SubtaskType --parent $ParentKey --summary ""$summary"" --desc-file $body"
        Add-Content -LiteralPath $KeysOut -Value ("{0}`t{1}`t{2}" -f $name, '<dry-run>', $summary)
        continue
    }

    $out = (New-Issue $SubtaskType $summary $body $ParentKey 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and (Test-IssueKey $out)) {
        Write-Output "  $name -> $out"
        Add-Content -LiteralPath $KeysOut -Value ("{0}`t{1}`t{2}" -f $name, $out, $summary)
        $ok++
    } else {
        Write-Output "  $name -> FAILED"
        foreach ($l in ($out -split "`n")) { Write-Output "      $l" }
        Add-Content -LiteralPath $KeysOut -Value ("{0}`t{1}`t{2}" -f $name, 'FAILED', $summary)
        $fail++
    }
}

Write-Output ''
Write-Output "done. parent=$ParentKey  created=$ok  failed=$fail"
Write-Output "keys: $KeysOut"
if (-not $DryRun) { Write-Output "view: jira.ps1 issue view $ParentKey --fields 'summary,description,issuetype,status,parent,subtasks,comment'" }
