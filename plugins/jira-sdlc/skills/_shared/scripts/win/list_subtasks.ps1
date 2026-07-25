# list_subtasks.ps1 — Windows (PowerShell 5.1+) twin of list_subtasks.sh.
# Wraps `jira.ps1 issue view <KEY> --fields subtasks,issuetype` (REST v3), the
# native Invoke-WebRequest port. Mirrors the bash helper's flags, output, and
# exit codes; parses the response with ConvertFrom-Json (no jq needed).
#
# Requires jira.ps1 working (a valid credential; ../jira-api-reference.md). Run
# from within the repo/worktree — jira.ps1 resolves its config from the git top-level.
# Reads <PROJECT-KEY> from jira-sdlc-tools.env (override with -EnvPath or
# $env:PROJECT_KEY); the project is a printed label only, never sent to the API.
#
# Usage:
#   pwsh -File list_subtasks.ps1 -Parent <PARENT-KEY> [-Role <role>] [-EnvPath ./jira-sdlc-tools.env] [-Json]
#   (positional works too: pwsh -File list_subtasks.ps1 <PARENT-KEY> [-Json])
#
# -Role defaults to assigner (as create_parent_and_subtasks.ps1 does): reading a
# parent's sub-tasks is the assigner's job, and jira.ps1 has no default
# credential to fall back to.
#
# Exit 0      — listed sub-tasks (or reported "none").
# Exit 1      — -Parent missing, or the response wasn't JSON.
# Exit <code> — the `jira.ps1 issue view` call failed (its stderr is relayed).

param([string]$Parent, [string]$Role = 'assigner', [string]$EnvPath = './jira-sdlc-tools.env', [switch]$Json)

if (-not $Parent) {
    [Console]::Error.WriteLine('list_subtasks: missing required -Parent <PARENT-KEY>')
    [Console]::Error.WriteLine('usage: pwsh -File list_subtasks.ps1 -Parent <PARENT-KEY> [-Role <role>] [-EnvPath ./jira-sdlc-tools.env] [-Json]')
    exit 1
}

$jiraPs = Join-Path $PSScriptRoot 'jira.ps1'
$psExe  = $null
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExe = 'pwsh'
} elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
    $psExe = 'powershell'
}
if (-not $psExe) {
    [Console]::Error.WriteLine('list_subtasks: no PowerShell runtime (pwsh/powershell) found to run jira.ps1.')
    exit 1
}

# --- resolve PROJECT-KEY (hyphen OR underscore form) ------------------------
function Get-ProjectKey {
    foreach ($p in @($EnvPath, 'jira-sdlc-tools.env', '../jira-sdlc-tools.env')) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        foreach ($line in Get-Content -LiteralPath $p) {
            if ($line -match '^\s*PROJECT[-_]KEY\s*=\s*(.+)$') { return $Matches[1].Trim() }
        }
    }
    return $env:PROJECT_KEY
}
$Project   = Get-ProjectKey
$ProjLabel = if ($Project) { "[$Project] " } else { '' }

# --- fetch the parent + its sub-tasks via jira.ps1 ---------------------------
# jira.ps1 runs in its OWN process (it calls `exit`). Clean JSON on stdout.
$argv = @('-NoProfile', '-File', $jiraPs, '--role', $Role,
          'issue', 'view', $Parent, '--fields', 'subtasks,issuetype')
$out  = (& $psExe @argv 2>&1)
$code = $LASTEXITCODE
if ($code -ne 0) {
    [Console]::Error.WriteLine(($out | Out-String).Trim())
    exit $code
}
$raw = $out | Out-String
try {
    $data = $raw | ConvertFrom-Json
} catch {
    [Console]::Error.WriteLine('list_subtasks: jira.ps1 issue view output had no JSON object')
    exit 1
}

$fields     = if ($data.fields) { $data.fields } else { $data }
$subtasks   = if ($fields.subtasks) { @($fields.subtasks) } else { @() }
$parentType = if ($fields.issuetype -and $fields.issuetype.name) { $fields.issuetype.name } else { '?' }

if ($Json) {
    $rows = @($subtasks | ForEach-Object {
        [pscustomobject]@{
            key     = if ($_.key)    { $_.key }             else { $null }
            summary = if ($_.fields) { $_.fields.summary }  else { $null }
        }
    })
    [pscustomobject]@{ parent = $Parent; parent_type = $parentType; subtasks = $rows } |
        ConvertTo-Json -Depth 8
    exit 0
}

Write-Output ("{0}parent {1} ({2}) — {3} sub-task(s):" -f $ProjLabel, $Parent, $parentType, $subtasks.Count)
if ($subtasks.Count -eq 0) {
    Write-Output "  (none — not a parent, or no sub-tasks attached)"
    exit 0
}
foreach ($s in $subtasks) {
    $k    = if ($s.key)                          { $s.key }            else { '?' }
    $summ = if ($s.fields -and $s.fields.summary) { $s.fields.summary } else { '' }
    Write-Output ("  {0}  {1}" -f $k, $summ)
}
exit 0
