# get_assignee_email.ps1 — Windows (PowerShell 5.1+) port of get_assignee_email.sh.
# Mirrors the bash contract exactly: one line on stdout, same exit codes.
#
# Prints the email every issue should be assigned to: JIRA_EXECUTOR_EMAIL —
# required, with no fallback. No token is resolved or printed here.
#
# Exit 0 — the email is on stdout.
# Exit 1 — it isn't set; the reason is on stderr. The caller stops.
#
# The env-file parser mirrors statuscheck.sh's cfg(): same `NAME = value`
# match, same local-overrides-team precedence, last match in a file wins.

. (Join-Path $PSScriptRoot '_jst_root.ps1')   # Get-JstRoot: the project root, even from inside a member submodule

$CfgDir = Get-JstRoot
if (-not $CfgDir) { $CfgDir = (Get-Location).Path }
$CfgDir = Join-Path $CfgDir '.jst'

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

if (-not $Email) {
    [Console]::Error.WriteLine("get_assignee_email: no assignee email — set JIRA_EXECUTOR_EMAIL in $CfgDir/jira-sdlc-tools.local.env, then rerun.")
    exit 1
}

Write-Output $Email
