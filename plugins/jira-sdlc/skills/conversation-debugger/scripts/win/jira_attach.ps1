# jira_attach.ps1 [--dry-run] <ISSUE-KEY> <file> [<file> ...]
#
# Windows (PowerShell 5.1+) port of jira_attach.sh — the conversation-debugger
# attachment uploader. Mirrors the bash contract exactly: same arguments, same
# stdout lines (upload/skip/fail + summary), same exit codes, same env
# precedence. Verified runnable under both Windows PowerShell 5.1 and
# PowerShell 7 (pwsh).
#
# Upload one or more files to a Jira issue as attachments. --dry-run reports the
# upload/skip decision for each file without POSTing anything.
#
# `acli jira workitem attachment` only supports list/delete — it can't upload —
# so this goes through Jira Cloud's REST API on the api.atlassian.com gateway
# with the executor's basic auth (email:token), the same identity
# jira_acli_login.ps1 logs in as. (The keyring acli uses isn't reusable for raw
# REST, so we read the credentials straight from the env files here.)
#
# Reads, with the same `NAME = value` parser + local-overrides-team precedence
# as the other scripts: JIRA_ACCOUNT_URL and JIRA_EXECUTOR_EMAIL /
# JIRA_EXECUTOR_TOKEN (each falling back to JIRA_ACCOUNT_EMAIL / JIRA_TOKEN).
#
# Exit 0 if every file uploaded; exit 1 on any usage/auth/upload failure.
#
# Cross-runtime notes (why this isn't a naive translation of the curl calls):
#   - Multipart upload: PS 7's Invoke-WebRequest has -Form, but 5.1 does not, so
#     we build the multipart body as raw bytes (header + file bytes + footer)
#     and send it via -Body [byte[]] — binary-safe and identical on both.
#   - Error bodies differ: on a non-2xx, PS 7 surfaces the response text in
#     $_.ErrorDetails.Message while 5.1 exposes only a WebException whose
#     HttpWebResponse stream must be read by hand. Get-HttpError handles both.
#   - TLS: 5.1 may default below TLS 1.2, which Atlassian rejects — we opt in.

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$Arrow = [char]0x2192   # "→" built at runtime so this source stays pure ASCII

# --- args: [--dry-run] <KEY> <file...> --------------------------------------
$DryRun = $false
$rest = @($args)
if ($rest.Count -gt 0 -and $rest[0] -eq '--dry-run') {
    $DryRun = $true
    $rest = @($rest[1..($rest.Count - 1)])
}
$Key = if ($rest.Count -gt 0) { [string]$rest[0] } else { '' }
$Files = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }
if (-not $Key -or $Files.Count -eq 0) {
    [Console]::Error.WriteLine("usage: jira_attach.ps1 [--dry-run] <ISSUE-KEY> <file> [<file> ...]")
    exit 1
}

# --- config: same parser + local-overrides-team precedence as the siblings ---
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

$Site  = Get-Cfg 'JIRA_ACCOUNT_URL'
$Email = Get-Cfg 'JIRA_EXECUTOR_EMAIL'; if (-not $Email) { $Email = Get-Cfg 'JIRA_ACCOUNT_EMAIL' }
$Token = Get-Cfg 'JIRA_EXECUTOR_TOKEN'; if (-not $Token) { $Token = Get-Cfg 'JIRA_TOKEN' }
if (-not $Site -or -not $Email -or -not $Token) {
    [Console]::Error.WriteLine("jira_attach: missing JIRA_ACCOUNT_URL / executor email / token in $CfgDir/jira-sdlc-tools.local.env")
    exit 1
}

# JIRA_ACCOUNT_URL is stored WITHOUT a scheme (and maybe a trailing slash) —
# normalize before building URLs, or tenant_info 404s.
$Site = $Site -replace '^https?://', ''
$Site = $Site.TrimEnd('/')

$AuthHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${Email}:${Token}"))

# Pull the response text out of a failed Invoke-WebRequest, bridging the 5.1/7
# difference described in the header.
function Get-HttpError {
    param($ErrorRecord)
    $code = 0
    $body = ''
    $resp = $ErrorRecord.Exception.Response
    if ($resp) {
        try { $code = [int]$resp.StatusCode } catch { $code = 0 }
    }
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message           # PS 7
    } elseif ($resp -and ($resp.PSObject.Methods.Name -contains 'GetResponseStream')) {
        try {                                               # PS 5.1
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $reader.ReadToEnd(); $reader.Close()
        } catch { }
    }
    return [pscustomobject]@{ Code = $code; Body = $body }
}

# --- cloud id for the api.atlassian.com gateway path -------------------------
# The tenant_info edge endpoint redirects; Invoke-RestMethod follows by default.
$Cloud = $null
try {
    $info = Invoke-RestMethod -Uri "https://$Site/_edge/tenant_info" -Method Get -UseBasicParsing
    if ($info -and $info.cloudId) { $Cloud = [string]$info.cloudId }
} catch { $Cloud = $null }
if (-not $Cloud) {
    [Console]::Error.WriteLine("jira_attach: could not resolve cloudId from https://$Site/_edge/tenant_info")
    exit 1
}

$IssueApi = "https://api.atlassian.com/ex/jira/$Cloud/rest/api/3/issue/$Key"

# --- existing attachments (idempotent by filename) ---------------------------
# Jira does NOT dedupe — the same name uploaded twice yields two copies — so we
# fetch current attachments and match on basename. A failed listing is fatal
# rather than silently risking duplicates.
$Existing = @()
try {
    $issue = Invoke-RestMethod -Uri "${IssueApi}?fields=attachment" -Method Get -UseBasicParsing `
        -Headers @{ Authorization = $AuthHeader; Accept = 'application/json' }
    $att = $null
    if ($issue -and $issue.fields) { $att = $issue.fields.attachment }
    if ($att) { $Existing = @($att | ForEach-Object { $_.filename } | Where-Object { $_ }) }
} catch {
    [Console]::Error.WriteLine("jira_attach: could not read existing attachments on $Key — aborting to avoid duplicates")
    exit 1
}

# --- upload loop -------------------------------------------------------------
$rc = 0; $nUp = 0; $nSkip = 0
foreach ($f in $Files) {
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
        [Console]::Error.WriteLine("jira_attach: no such file: $f")
        $rc = 1; continue
    }
    $base = [System.IO.Path]::GetFileName($f)
    if ($Existing -contains $base) {
        Write-Output "already attached, skipped: $base"
        $nSkip++
        continue
    }
    if ($DryRun) {
        Write-Output "would upload: $base $Arrow $Key"
        $nUp++
        continue
    }

    # Build the multipart/form-data body as raw bytes: ASCII/UTF-8 header, the
    # file's exact bytes, then the closing boundary. Sent via -Body [byte[]] so
    # both runtimes transmit the payload unmodified (no -Form on 5.1).
    $boundary  = [Guid]::NewGuid().ToString()
    $fileBytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $f).Path)
    $enc = [System.Text.Encoding]::UTF8
    $LF = "`r`n"
    $header = "--$boundary$LF" +
              "Content-Disposition: form-data; name=`"file`"; filename=`"$base`"$LF" +
              "Content-Type: application/octet-stream$LF$LF"
    $footer = "$LF--$boundary--$LF"
    $headerBytes = $enc.GetBytes($header)
    $footerBytes = $enc.GetBytes($footer)
    $bodyBytes = New-Object byte[] ($headerBytes.Length + $fileBytes.Length + $footerBytes.Length)
    [Array]::Copy($headerBytes, 0, $bodyBytes, 0, $headerBytes.Length)
    [Array]::Copy($fileBytes, 0, $bodyBytes, $headerBytes.Length, $fileBytes.Length)
    [Array]::Copy($footerBytes, 0, $bodyBytes, $headerBytes.Length + $fileBytes.Length, $footerBytes.Length)

    $code = 0
    try {
        $resp = Invoke-WebRequest -Uri "$IssueApi/attachments" -Method Post -UseBasicParsing `
            -Headers @{ Authorization = $AuthHeader; 'X-Atlassian-Token' = 'no-check' } `
            -ContentType "multipart/form-data; boundary=$boundary" `
            -Body $bodyBytes
        $code = [int]$resp.StatusCode
    } catch {
        $e = Get-HttpError $_
        $code = $e.Code
        if ($code -eq 200 -or $code -eq 201) {
            # a 2xx that still threw (rare) — treat as success below
        } else {
            [Console]::Error.WriteLine("jira_attach: FAILED (HTTP $code) for $f")
            if ($e.Body) { [Console]::Error.WriteLine($e.Body) }
            $rc = 1; continue
        }
    }
    if ($code -eq 200 -or $code -eq 201) {
        Write-Output "attached: $base $Arrow $Key"
        $nUp++
    } else {
        [Console]::Error.WriteLine("jira_attach: FAILED (HTTP $code) for $f")
        $rc = 1
    }
}

$verb = if ($DryRun) { 'would upload' } else { 'uploaded' }
$suffix = if ($rc -ne 0) { ', some failed' } else { '' }
Write-Output "jira_attach: $verb $nUp, $nSkip already present$suffix"
exit $rc
