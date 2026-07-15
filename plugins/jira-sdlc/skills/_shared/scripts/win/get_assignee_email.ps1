# get_assignee_email.ps1 — Windows (PowerShell 5.1+) port of get_assignee_email.sh.
# Mirrors the bash contract exactly: one line on stdout, same exit codes.
#
# Prints the email every issue should be assigned to: JIRA_EXECUTOR_EMAIL,
# falling back to JIRA_ACCOUNT_EMAIL. No token is resolved or printed here.
#
# Exit 0 — the email is on stdout.
# Exit 1 — neither is set; the reason is on stderr. The caller stops.
#
# The env-file parser mirrors statuscheck.sh's cfg(): same `NAME = value`
# match, same local-overrides-team precedence, last match in a file wins.

function Get-GitTop {
    try {
        $t = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $t) { return ([string]$t).Trim() }
    } catch { }
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

$Email = Get-Cfg 'JIRA_EXECUTOR_EMAIL'
if (-not $Email) { $Email = Get-Cfg 'JIRA_ACCOUNT_EMAIL' }

if (-not $Email) {
    [Console]::Error.WriteLine("get_assignee_email: no assignee email — set JIRA_EXECUTOR_EMAIL (or JIRA_ACCOUNT_EMAIL) in $CfgDir/jira-sdlc-tools.local.env, then rerun.")
    exit 1
}

Write-Output $Email
