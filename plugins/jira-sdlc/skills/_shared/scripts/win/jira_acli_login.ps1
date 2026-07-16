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
# ALWAYS LOGOUT, THEN LOGIN — no idempotency no-op. This script used to peek at
# ~/.config/acli/jira_config.yaml and skip logout+login when the active
# site+email already matched the role. That was unsafe: a revoked or rotated
# token silently survived, because a config-peek compares identity, not
# validity — and `acli jira auth status` keeps reporting authenticated from
# cache while real calls fail. So we now run `acli jira auth logout` then
# `auth login` on every call, unconditionally. The logout is mandatory: a second
# `auth login` does NOT overwrite an existing stored credential, so without it a
# stale credential would never be replaced.
#
# TIMEOUTS: login is capped at 180s and logout at 60s (aligned with the bash
# twin). Login gets the longer cap because `acli jira auth login` can take 2-3
# minutes against a real Jira instance; now that login is always-on it must not
# be capped at the shorter logout value.
#
# ⚠️ acli's credential store is machine-global and single-account: switching
# roles switches the active account for every other shell on this machine.
# Tokens: the raw API token VALUE, never a path. Fed to acli on stdin via a
# transient temp file + Start-Process -RedirectStandardInput (byte-clean on
# both PS 5.1 and 7; the native `$Token | & acli` pipe CRLF-corrupts on 5.1).
#
# Exit 0 — acli is now logged in as <role>'s identity.
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

# No idempotency short-circuit: we ALWAYS logout+login (see header). A
# config-peek would only confirm identity, never token validity, so a stale or
# revoked token would survive it — the exact failure this script now prevents by
# re-logging in unconditionally.

$Token = Get-Cfg "${Prefix}_TOKEN"
if (-not $Token) { $Token = Get-Cfg 'JIRA_TOKEN' }
if (-not $Token) {
    [Console]::Error.WriteLine("jira_acli_login: no token for role '$Role' ($Email) — set ${Prefix}_TOKEN (or JIRA_TOKEN) in $CfgDir/jira-sdlc-tools.local.env. It must be the raw API token value, not a path to a file.")
    exit 1
}

# logout FIRST — login does not overwrite an existing credential (see header).
# Capped at 60s (aligned with the bash twin's `timeout 60`) via Start-Process so
# a stalled logout can't hang the run; a logout failure is non-fatal (the bash
# twin's `|| true`) — the login below is what the exit code hinges on.
$logoutOut = [System.IO.Path]::GetTempFileName()
$logoutErr = [System.IO.Path]::GetTempFileName()
try {
    $logoutProc = Start-Process -FilePath acli `
        -ArgumentList @('jira','auth','logout') `
        -RedirectStandardOutput $logoutOut -RedirectStandardError $logoutErr `
        -NoNewWindow -PassThru
    if (-not $logoutProc.WaitForExit(60000)) {
        try { $logoutProc.Kill() } catch { }
    }
} catch { } finally {
    Remove-Item -LiteralPath $logoutOut,$logoutErr -Force -ErrorAction SilentlyContinue
}

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
