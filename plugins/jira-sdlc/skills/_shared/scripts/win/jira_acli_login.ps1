#!/usr/bin/env pwsh
# jira_acli_login.ps1 — Windows (PowerShell 7) port of jira_acli_login.sh.
# Logs acli in as a role's Jira identity, idempotently. Mirrors the bash
# contract exactly: same messages, same exit codes, same idempotency rule.
#
# Usage: pwsh jira_acli_login.ps1 <role>     # executor | assigner | reviewer
#
# Each role has an optional dedicated account; all three fall back to the
# default one (JIRA_ACCOUNT_EMAIL / JIRA_TOKEN). Email and token fall back
# INDEPENDENTLY. See the bash original for the full rationale.
#
# IDEMPOTENT: acli records the active account in ~/.config/acli/jira_config.yaml;
# if it already matches the role's site+email this is a no-op returning 0
# without touching the network. Otherwise it runs `acli jira auth logout` and
# then logs in — the logout is mandatory (a second login does NOT overwrite an
# existing stored credential).
#
# ⚠️ acli's credential store is machine-global and single-account: switching
# roles switches the active account for every other shell on this machine.
# Tokens: the raw API token VALUE, never a path. Piped to acli on stdin.
#
# Exit 0 — acli is now (or already was) logged in as <role>'s identity.
# Exit 1 — anything else, with the reason on stderr.

param([string]$Role)

switch ($Role) {
    'executor' { $Prefix = 'JIRA_EXECUTOR' }
    'assigner' { $Prefix = 'JIRA_ASSIGNER' }
    'reviewer' { $Prefix = 'JIRA_REVIEWER' }
    default {
        $shown = if ($Role) { $Role } else { '<none>' }
        [Console]::Error.WriteLine("jira_acli_login: role must be executor|assigner|reviewer (got '$shown').")
        exit 1
    }
}

if (-not (Get-Command acli -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("jira_acli_login: acli is not installed.")
    exit 1
}

function Get-GitTop {
    try {
        $t = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $t) { return ([string]$t).Trim() }
    } catch { }
    return $null
}

$CfgDir = Get-GitTop
if (-not $CfgDir) { $CfgDir = (Get-Location).Path }

# Same `NAME = value` parser and local-overrides-team precedence as
# statuscheck.sh. Keep them in sync; don't invent a second parser.
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

$Email = Get-Cfg "${Prefix}_EMAIL"
if (-not $Email) { $Email = Get-Cfg 'JIRA_ACCOUNT_EMAIL' }
if (-not $Email) {
    [Console]::Error.WriteLine("jira_acli_login: no email for role '$Role' — set ${Prefix}_EMAIL (or JIRA_ACCOUNT_EMAIL) in $CfgDir/jira-sdlc-tools.local.env.")
    exit 1
}

$Site = Get-Cfg 'JIRA_ACCOUNT_URL'
if (-not $Site) {
    [Console]::Error.WriteLine("jira_acli_login: JIRA_ACCOUNT_URL is unset in $CfgDir/jira-sdlc-tools.local.env.")
    exit 1
}

# --- idempotency: already this identity? then do nothing. --------------------
# acli writes the active profile here on login and clears it on logout, so a
# local read answers "who am I?" instantly and without the network.
$AcliCfg = Join-Path (Join-Path (Join-Path $HOME '.config') 'acli') 'jira_config.yaml'
function Get-Yaml1 {
    param([string]$File, [string]$Key)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match "^\s*-?\s*${Key}:\s*(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

$ActiveEmail = Get-Yaml1 $AcliCfg 'email'
$ActiveSite  = Get-Yaml1 $AcliCfg 'site'
if ($ActiveEmail -and
    ($ActiveEmail.ToLower() -eq $Email.ToLower()) -and
    ($ActiveSite.ToLower()  -eq $Site.ToLower())) {
    Write-Output "jira_acli_login: already $Role ($Email) — no re-login needed."
    exit 0
}

$Token = Get-Cfg "${Prefix}_TOKEN"
if (-not $Token) { $Token = Get-Cfg 'JIRA_TOKEN' }
if (-not $Token) {
    [Console]::Error.WriteLine("jira_acli_login: no token for role '$Role' ($Email) — set ${Prefix}_TOKEN (or JIRA_TOKEN) in $CfgDir/jira-sdlc-tools.local.env. It must be the raw API token value, not a path to a file.")
    exit 1
}

# logout FIRST — login does not overwrite an existing credential (see header).
& acli jira auth logout *> $null

# Token piped on stdin; never printed, never on a command line.
$Token | & acli jira auth login --site $Site --email $Email --token *> $null
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("jira_acli_login: 'acli jira auth login' failed for $Role ($Email) at $Site — check ${Prefix}_TOKEN / JIRA_TOKEN in $CfgDir/jira-sdlc-tools.local.env (raw API token value, not a path). acli is now logged OUT.")
    exit 1
}

Write-Output "jira_acli_login: acli is now $Role ($Email)."
exit 0
