# check_assignee.ps1 — Windows (PowerShell 5.1+) twin of check_assignee.sh.
# Is this issue assigned to the given role's account? Same args, messages, exit codes.
#
# Usage: pwsh -File check_assignee.ps1 [--role <role>] [ISSUE-KEY]
#   --role defaults to executor (its sole caller is the executor's ownership
#   gate) and is also read from $env:JIRA_ROLE; ISSUE-KEY defaults to the
#   branch-derived key. Identity comes from `jira.ps1 whoami` (GET /myself) —
#   per-request Basic auth, no config file to parse. Because the account is
#   chosen by --role rather than by switching a stored profile, there is no
#   multi-profile state to fall out of sync (JST-146): "who am I" is now the
#   token in hand.
#
# jira.ps1 calls `exit`, so it runs in its OWN pwsh process (never `&` in-process,
# which would exit this script too).
#
# Exit 0 — assigned to the role's account: CONTINUE.
# Exit 1 — everything else: STOP. Reason + fix on stderr; relay verbatim.

$ErrorActionPreference = 'Stop'

function Die { param([string]$Msg) [Console]::Error.WriteLine($Msg); exit 1 }

# --- args: optional --role, optional ISSUE-KEY -------------------------------
$Role = $env:JIRA_ROLE
$Key  = ''
$i = 0
while ($i -lt $args.Count) {
    $a = [string]$args[$i]
    if     ($a -eq '--role')    { $Role = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--role=*') { $Role = $a.Substring(7); $i += 1 }
    else   { $Key = $a; $i += 1 }
}
if (-not $Role) { $Role = 'executor' }

$jiraPs = Join-Path $PSScriptRoot 'jira.ps1'
$psExe  = $null
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExe = 'pwsh'
} elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
    $psExe = 'powershell'
}
if (-not $psExe) { Die "check_assignee: no PowerShell runtime (pwsh/powershell) found to run jira.ps1." }

# --- config (site for the fixup URL) -----------------------------------------
$CfgDir = $null
try { $t = (& git rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -eq 0 -and $t) { $CfgDir = ([string]$t).Trim() } } catch { }
if (-not $CfgDir) { $CfgDir = (Get-Location).Path }
$CfgDir = Join-Path $CfgDir '.jst'
function Get-Cfg {
    param([string]$Name)
    foreach ($f in @('jira-sdlc-tools.local.env', 'jira-sdlc-tools.env')) {
        $path = Join-Path $CfgDir $f
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $val = $null
        foreach ($line in Get-Content -LiteralPath $path) {
            if ($line -match "^\s*($Name)\s*=(.*)$") { $val = $Matches[2].Trim() }
        }
        if ($val) { return $val }
    }
    return $null
}
$Site = Get-Cfg 'JIRA_ACCOUNT_URL'
if ($Site) { $Site = $Site -replace '^[^/]*//', '' } else { $Site = '' }

# --- who is this role? (GET /myself via jira.ps1) ----------------------------
# accountId is the identifier that actually works: Jira exposes emailAddress on
# an assignee only for YOUR OWN account, so email can confirm a match but never
# distinguish "assigned to someone else" from "unassigned". Compare on accountId.
$whoami = ((& $psExe -NoProfile -File $jiraPs --role $Role whoami 2>$null) | Out-String)
if ($LASTEXITCODE -ne 0 -or -not $whoami.Trim()) {
    Die "check_assignee: could not authenticate as role '$Role' — check JIRA_$($Role.ToUpper())_EMAIL + _TOKEN in .jst/jira-sdlc-tools.local.env."
}
$MyId = ''; $Me = ''
try {
    $o = $whoami | ConvertFrom-Json
    $MyId = [string]$o.accountId
    $Me = if ($o.emailAddress) { [string]$o.emailAddress } elseif ($o.displayName) { [string]$o.displayName } else { '' }
} catch { }
if (-not $MyId) { Die "check_assignee: jira whoami returned no accountId for role '$Role'." }
if (-not $Me) { $Me = "role '$Role'" }

# --- which issue? ------------------------------------------------------------
if (-not $Key) {
    $br = (& git branch --show-current 2>$null); if ($br) { $br = ([string]$br).Trim() }
    $brTail = $br -replace '^[^/]*/', ''
    if ($brTail -match '^([A-Za-z][A-Za-z0-9]*-[0-9]+)') { $Key = $Matches[1] }
    if (-not $Key) {
        $shown = if ($br) { $br } else { 'none' }
        Die "check_assignee: no issue key derivable from branch '$shown' — expected feature/<KEY>-<slug> or hotfix/<KEY>-<slug>. Run from the issue's worktree, or pass the key."
    }
}

# --- assigned to me? ---------------------------------------------------------
$viewOut  = (& $psExe -NoProfile -File $jiraPs --role $Role issue view $Key --fields assignee 2>&1)
$viewRc   = $LASTEXITCODE
$viewText = ($viewOut | Out-String)
if ($viewRc -ne 0) {
    $last = ($viewOut | Select-Object -Last 1)
    Die "check_assignee: cannot read $Key as $Me — $last. The account may lack access to this project, or the Jira API timed out."
}

# -> "<accountId>|<displayName>", or empty when unassigned. With --fields
# assignee the only accountId/displayName in the payload is the assignee's.
$Assignee = ''
try {
    $a = ($viewText | ConvertFrom-Json).fields.assignee
    if ($a -and $a.accountId) {
        $name = if ($a.displayName) { $a.displayName } else { 'unknown' }
        $Assignee = "$($a.accountId)|$name"
    }
} catch { $Assignee = '' }

$Fixup = @"
Assign it and rerun:
  jira issue assign $Key --to "$Me"   (--role $Role; jira.sh on POSIX / jira.ps1 on Windows)
Or assign it by hand: https://$Site/browse/$Key
"@

if (-not $Assignee) {
    Die "check_assignee: $Key is UNASSIGNED — it must be assigned to $Me. STOP: do not transition, branch, commit, or comment.`n$Fixup"
}

$TheirId   = $Assignee.Split('|', 2)[0]
$TheirName = $Assignee.Split('|', 2)[1]

if ($TheirId -ne $MyId) {
    Die "check_assignee: $Key is assigned to someone else — $TheirName, not $Me. STOP: do not transition, branch, commit, or comment.`n$Fixup"
}

Write-Output "check_assignee: OK — $Key is assigned to $Me. Continue."
