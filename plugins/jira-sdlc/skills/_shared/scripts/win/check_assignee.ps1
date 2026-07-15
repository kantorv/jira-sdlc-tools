# check_assignee.ps1 — Windows (PowerShell 5.1+) port of check_assignee.sh.
# Is this issue assigned to the account acli is logged in as? Mirrors the bash
# contract exactly: same messages, same exit codes.
#
# Usage: powershell -File check_assignee.ps1 [ISSUE-KEY]
#        ISSUE-KEY defaults to the key derived from the current branch
#        (feature/<KEY>-<slug> / hotfix/<KEY>-<slug>).
#
# Run it AFTER jira_acli_login.ps1 <role> — it checks the issue against whoever
# acli is currently logged in as. Anything other than "assigned to me" halts.
#
# Exit 0 — the issue is assigned to the logged-in account: CONTINUE.
# Exit 1 — everything else: STOP. Reason + fix on stderr; relay verbatim.

param([string]$Key)

function Die { param([string]$Msg) [Console]::Error.WriteLine($Msg); exit 1 }

if (-not (Get-Command acli -ErrorAction SilentlyContinue)) {
    Die "check_assignee: acli is not installed."
}

# --- who is acli logged in as? ----------------------------------------------
# acli records the active profile here on login and clears it on logout, so this
# is an instant local read — and it reflects the identity that will actually
# make the Jira calls.
$AcliCfg = Join-Path (Join-Path (Join-Path $HOME '.config') 'acli') 'jira_config.yaml'
if (-not (Test-Path -LiteralPath $AcliCfg)) {
    Die "check_assignee: acli is not logged in (no $AcliCfg) — run jira_acli_login.ps1 <role> first."
}

function Get-Yaml1 {  # first `key: value` from acli's config
    param([string]$K)
    foreach ($line in Get-Content -LiteralPath $AcliCfg) {
        if ($line -match "^\s*-?\s*${K}:\s*(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

$Me = Get-Yaml1 'email'
# accountId is the identifier that actually works. Jira only exposes
# `emailAddress` on the assignee object for YOUR OWN account — for anyone else
# the field is absent, so an email comparison can never distinguish "assigned
# to someone else" from "unassigned". Compare on accountId instead.
$MyId = Get-Yaml1 'account_id'
if (-not $MyId) {
    Die "check_assignee: acli reports no active account — run jira_acli_login.ps1 <role> first."
}

$Site = Get-Yaml1 'site'

# --- which issue? ------------------------------------------------------------
if (-not $Key) {
    $Br = (& git branch --show-current 2>$null)
    if ($Br) { $Br = ([string]$Br).Trim() }
    $BrTail = $Br -replace '^[^/]*/', ''
    if ($BrTail -match '^([A-Za-z][A-Za-z0-9]*-[0-9]+)') { $Key = $Matches[1] }
    if (-not $Key) {
        $shown = if ($Br) { $Br } else { 'none' }
        Die "check_assignee: no issue key derivable from branch '$shown' — expected feature/<KEY>-<slug> or hotfix/<KEY>-<slug>. Run from the issue's worktree, or pass the key."
    }
}

# --- assigned to me? ---------------------------------------------------------
$View = (& acli jira workitem view $Key --json --fields 'assignee' 2>&1)
if ($LASTEXITCODE -ne 0) {
    $last = ($View | Select-Object -Last 1)
    Die "check_assignee: cannot read $Key as $Me — $last. The account may lack access to this project, or the Jira API timed out."
}

# -> "<accountId>|<displayName>", or empty when unassigned.
$Assignee = $null
try {
    $a = ($View | Out-String | ConvertFrom-Json).fields.assignee
    if ($a -and $a.accountId) {
        $name = if ($a.displayName) { $a.displayName } else { 'unknown' }
        $Assignee = "$($a.accountId)|$name"
    }
} catch { $Assignee = $null }

$Fixup = @"
Assign it and rerun:
  acli jira workitem assign --key $Key --assignee "$Me" --yes
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
