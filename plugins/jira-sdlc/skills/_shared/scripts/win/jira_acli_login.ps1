# jira_acli_login.ps1 — Windows (PowerShell 5.1+) port of jira_acli_login.sh.
# Logs acli in as a role's Jira identity, idempotently. Mirrors the bash
# contract exactly: same messages, same exit codes, same idempotency rule.
#
# Usage: powershell -File jira_acli_login.ps1 <role>   # executor | assigner | reviewer
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
# Tokens: the raw API token VALUE, never a path. Fed to acli on stdin via a
# transient temp file + Start-Process -RedirectStandardInput (byte-clean on
# both PS 5.1 and 7; the native `$Token | & acli` pipe CRLF-corrupts on 5.1).
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
# acli records the active account here as `current_profile`, and on logout it
# blanks `current_profile` but LEAVES the profile entry (site/email) behind. So
# the profile's email/site is NOT proof of being logged in — only a non-empty
# `current_profile` is. Gate on it, or a logged-out stale profile reads as
# "already logged in" and the script skips the real login while acli stays
# unauthorized.
$AcliCfg = Join-Path (Join-Path (Join-Path $HOME '.config') 'acli') 'jira_config.yaml'
function Get-Yaml1 {
    param([string]$File, [string]$Key)
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match "^\s*-?\s*${Key}:\s*(.*)$") { return $Matches[1].Trim() }
    }
    return $null
}

$ActiveProfile = Get-Yaml1 $AcliCfg 'current_profile'
if ($ActiveProfile) { $ActiveProfile = $ActiveProfile.Trim('"') }
$ActiveEmail = Get-Yaml1 $AcliCfg 'email'
$ActiveSite  = Get-Yaml1 $AcliCfg 'site'
if ($ActiveProfile -and $ActiveEmail -and
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

# Feed the token to acli on stdin. The token is the raw API-token VALUE, never
# printed and never on the command line. We CANNOT use PowerShell's native
# string pipe ("$Token | & acli ... --token"): on Windows PowerShell 5.1 the
# piped bytes arrive CRLF-corrupted, so acli rejects the token, whereas the
# bash twin's `printf '%s' "$token"` is byte-clean (confirmed by running both on
# a real Windows box: bash login succeeds, the bare pipe fails). So we write the
# exact token bytes to a transient temp file (UTF-8, no BOM, no trailing newline
# — byte-identical to the bash pipe) and feed it to acli via Start-Process
# -RedirectStandardInput. Works on BOTH 5.1 and 7, with a 180s cap (acli login may take 2-3 minutes on a real Jira instance). stdout/stderr go to temp files (then deleted) so
# the script's own stdout stays a single confirmation line, matching the contract.
$tmp  = [System.IO.Path]::GetTempFileName()
$outF = [System.IO.Path]::GetTempFileName()
$errF = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllBytes($tmp, (New-Object System.Text.UTF8Encoding($false)).GetBytes($Token))
    $proc = Start-Process -FilePath acli `
        -ArgumentList @('jira','auth','login','--site',$Site,'--email',$Email,'--token') `
        -RedirectStandardInput $tmp -RedirectStandardOutput $outF -RedirectStandardError $errF `
        -NoNewWindow -PassThru
    # Cache the native handle NOW: a Start-Process -PassThru object cannot return
    # its .ExitCode after the process exits unless the handle was touched while it
    # was still alive — otherwise .ExitCode is $null, and "$null -ne 0" is $true,
    # so a successful login is misreported as a failure. See WaitForExit below.
    $null = $proc.Handle
    if (-not $proc.WaitForExit(180000)) {
        try { $proc.Kill() } catch { }
        [Console]::Error.WriteLine("jira_acli_login: 'acli jira auth login' timed out for $Role ($Email) at $Site — check ${Prefix}_TOKEN / JIRA_TOKEN in $CfgDir/jira-sdlc-tools.local.env (raw API token value, not a path). acli is now logged OUT.")
        exit 1
    }
    if ($proc.ExitCode -ne 0) {
        [Console]::Error.WriteLine("jira_acli_login: 'acli jira auth login' failed for $Role ($Email) at $Site — check ${Prefix}_TOKEN / JIRA_TOKEN in $CfgDir/jira-sdlc-tools.local.env (raw API token value, not a path). acli is now logged OUT.")
        exit 1
    }
} finally {
    Remove-Item -LiteralPath $tmp,$outF,$errF -Force -ErrorAction SilentlyContinue
}

Write-Output "jira_acli_login: acli is now $Role ($Email)."
exit 0
