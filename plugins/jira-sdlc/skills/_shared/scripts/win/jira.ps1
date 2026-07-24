# jira.ps1 — Windows (PowerShell 5.1+) twin of jira.sh; the acli replacement.
#
# Contract pair with ../posix/jira.sh: same arguments, same stdout, same exit
# codes, same "jira: …" stderr. Edit one port, edit the other (AGENTS.md).
#
# Design & rationale:  ../../../../docs/rest-client-design.md
# Live-verified call shapes + status codes:  ../../../../docs/acli-to-rest-api-migration.md
#
# Four layers (see the design doc):
#   L1 config    — env files, --role→credential, cloud-id (cached), ADF encode, email→accountId
#   L2 transport — Invoke-Request(): the single HTTP choke point; status → semantic exit code
#   L3 ops       — Op-IssueView / Op-IssueCreate / Op-TransitionTo / …  (extend HERE)
#   L4 dispatch  — arg parsing + subcommand routing (bottom of file)
#
# Auth is per-request Basic (no login, no stored credential, no global state):
# --role picks which <ROLE>_EMAIL/<ROLE>_TOKEN pair the call uses, falling back
# to JIRA_ACCOUNT_EMAIL / JIRA_TOKEN. This replaces the whole jira_acli_login layer.
#
# Output contract:  read ops print raw JSON on stdout (caller parses it); write ops
# print nothing on success (REST returns 204, empty). Errors → stderr.
# Exit codes:  0 ok · 1 transport · 2 usage · 3 auth(401) · 4 not-found/perm(404)
#              · 5 validation(400) · 6 forbidden(403) · 7 unexpected · 8 no such transition

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$EX_OK = 0; $EX_ERR = 1; $EX_USAGE = 2; $EX_AUTH = 3; $EX_NOTFOUND = 4
$EX_VALIDATION = 5; $EX_FORBIDDEN = 6; $EX_UNEXPECTED = 7; $EX_NOTRANSITION = 8

# Globals populated by Invoke-Ready (L1).
$script:ROLE  = $env:JIRA_ROLE
$script:CRED  = ''; $script:SITE = ''; $script:CLOUD = ''; $script:BASE = ''
$script:RESP  = ''; $script:ACCT = ''; $script:CFGDIR = ''

function Die { param([int]$Code, [string]$Msg) [Console]::Error.WriteLine("jira: $Msg"); exit $Code }
function RoleName { if ($script:ROLE) { $script:ROLE } else { 'default' } }

function Usage {
    [Console]::Error.WriteLine(@'
usage: jira.sh [--role executor|assigner|reviewer] <command>

  whoami                                         who this credential authenticates as
  project exists  <KEY>                          is the project visible to this account?
  issue view      <KEY> [--fields a,b,c]         get an issue (raw JSON on stdout)
  issue create    --project K --type T --summary S
                  [--parent K] [--assignee email|@me]
                  [--desc-file FILE | --adf-file FILE]   -> prints the new key
  issue transition <KEY> --to "In Review"        transition by target status name
  issue assign     <KEY> (--to email|@me | --remove)
  issue comment add  <KEY> (--body-file FILE | --adf-file FILE)
  issue comment list <KEY>                       raw JSON on stdout
  issue delete     <KEY> [--with-subtasks]
  raw <METHOD> </PATH> [--data-file FILE]        escape hatch; PATH is under /rest/api/3 (e.g. /myself)

--desc-file/--body-file take PLAIN TEXT (one ADF paragraph per non-blank line).
--adf-file takes a bare ADF "doc" object (rich formatting you built yourself).
'@)
    exit $EX_USAGE
}

# ─── Layer 1: config resolution ─────────────────────────────────────────────

function Get-GitTop {
    try {
        $t = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $t) { return ([string]$t).Trim() }
    } catch { }
    return $null
}

# Same `NAME = value` parser + local-overrides-team precedence as jira.sh's _cfg
# (and jira_acli_login.ps1 / statuscheck.ps1). Last match in a file wins.
function Get-Cfg {
    param([string]$Name)
    foreach ($f in @('jira-sdlc-tools.local.env', 'jira-sdlc-tools.env')) {
        $path = Join-Path $script:CFGDIR $f
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $val = $null
        foreach ($line in Get-Content -LiteralPath $path) {
            if ($line -match "^\s*($Name)\s*=(.*)$") { $val = $Matches[2].Trim() }
        }
        if ($val) { return $val }
    }
    return $null
}

function UrlEnc { param([string]$V) [uri]::EscapeDataString($V) }
function JsonStr { param([string]$V) ConvertTo-Json -InputObject ([string]$V) -Compress }

# Resolve the <role> credential pair. Email and token fall back to the default
# account INDEPENDENTLY (a role may set only its email, sharing the default token).
function Resolve-Cred {
    $prefix = ''
    switch ($script:ROLE) {
        'executor' { $prefix = 'JIRA_EXECUTOR' }
        'assigner' { $prefix = 'JIRA_ASSIGNER' }
        'reviewer' { $prefix = 'JIRA_REVIEWER' }
        ''         { $prefix = '' }
        $null      { $prefix = '' }
        default    { Die $EX_USAGE "role must be executor|assigner|reviewer (got '$($script:ROLE)')" }
    }
    $email = ''; $token = ''
    if ($prefix) { $email = Get-Cfg "${prefix}_EMAIL"; $token = Get-Cfg "${prefix}_TOKEN" }
    if (-not $email) { $email = Get-Cfg 'JIRA_ACCOUNT_EMAIL' }
    if (-not $token) { $token = Get-Cfg 'JIRA_TOKEN' }
    if (-not $email) { Die $EX_ERR "no email for role '$(RoleName)' — set $(if ($prefix) { $prefix } else { 'JIRA_ACCOUNT' })_EMAIL in jira-sdlc-tools.local.env." }
    if (-not $token) { Die $EX_ERR "no token for role '$(RoleName)' — set $(if ($prefix) { $prefix } else { 'JIRA' })_TOKEN in jira-sdlc-tools.local.env (raw API token value, not a path)." }
    $script:CRED = "${email}:${token}"
}

# Cloud id never changes per site but the tenant_info hop is a network call, so
# cache it. On Windows the cache lives under %LOCALAPPDATA% (the ~/.cache analogue).
function Resolve-CloudId {
    $cacheRoot = $env:LOCALAPPDATA
    if (-not $cacheRoot) { $cacheRoot = $env:XDG_CACHE_HOME }
    if (-not $cacheRoot) { $cacheRoot = Join-Path $HOME '.cache' }
    $dir  = Join-Path $cacheRoot 'jira-sdlc'
    $file = Join-Path $dir "$($script:SITE).cloudid"
    if (Test-Path -LiteralPath $file) {
        $c = (Get-Content -LiteralPath $file -Raw).Trim()
        if ($c) { $script:CLOUD = $c; return }
    }
    try {
        $ti = Invoke-RestMethod -Uri "https://$($script:SITE)/_edge/tenant_info" -TimeoutSec 30
        $script:CLOUD = [string]$ti.cloudId
    } catch { Die $EX_ERR "could not reach https://$($script:SITE)/_edge/tenant_info to resolve the cloud id." }
    if (-not $script:CLOUD) { Die $EX_ERR "cloud id not found for site '$($script:SITE)'." }
    try {
        New-Item -ItemType Directory -Force -Path $dir -ErrorAction SilentlyContinue | Out-Null
        Set-Content -LiteralPath $file -Value $script:CLOUD -NoNewline
    } catch { }
}

function Invoke-Ready {
    $script:CFGDIR = Get-GitTop
    if (-not $script:CFGDIR) { $script:CFGDIR = (Get-Location).Path }
    $u = Get-Cfg 'JIRA_ACCOUNT_URL'
    if ($u) { $script:SITE = $u -replace '^[^/]*//', '' } else { $script:SITE = '' }
    if (-not $script:SITE) { Die $EX_ERR 'JIRA_ACCOUNT_URL is unset in jira-sdlc-tools.local.env.' }
    Resolve-Cred
    Resolve-CloudId
    $script:BASE = "https://api.atlassian.com/ex/jira/$($script:CLOUD)/rest/api/3"
}

# Plain-text FILE → a bare ADF "doc" object (JSON string; one paragraph per non-blank line).
function ConvertTo-AdfDoc {
    param([string]$File)
    $paras = @()
    foreach ($line in Get-Content -LiteralPath $File) {
        if (([string]$line).Length -gt 0) {
            $t = ConvertTo-Json -InputObject ([string]$line) -Compress
            $paras += '{"type":"paragraph","content":[{"type":"text","text":' + $t + '}]}'
        }
    }
    return '{"type":"doc","version":1,"content":[' + ($paras -join ',') + ']}'
}

# email → accountId (into $script:ACCT). '@me' short-circuits to the caller's own id.
# Returns a semantic exit code; 0 on success.
function Resolve-AccountId {
    param([string]$Who)
    if ($Who -eq '@me') {
        $rc = Invoke-Request GET '/myself'; if ($rc -ne 0) { return $rc }
        try { $script:ACCT = ($script:RESP | ConvertFrom-Json).accountId } catch { $script:ACCT = '' }
        return $EX_OK
    }
    $rc = Invoke-Request GET "/user/search?query=$(UrlEnc $Who)"; if ($rc -ne 0) { return $rc }
    $id = ''
    try { $id = @($script:RESP | ConvertFrom-Json)[0].accountId } catch { }
    if (-not $id) { [Console]::Error.WriteLine("jira: no Jira account found for `"$Who`""); return $EX_NOTFOUND }
    $script:ACCT = $id
    return $EX_OK
}

# ─── Layer 2: transport core (the single HTTP choke point) ──────────────────

# Invoke-Request METHOD PATH [JSON_BODY]   body → $script:RESP; returns a semantic exit code.
function Invoke-Request {
    param([string]$Method, [string]$Path, [string]$Body)
    $headers = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:CRED))
        Accept        = 'application/json'
    }
    $p = @{ Uri = "$($script:BASE)$Path"; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($Body) { $p['ContentType'] = 'application/json'; $p['Body'] = $Body }
    try {
        $resp = Invoke-WebRequest @p
        $script:RESP = [string]$resp.Content
        return $EX_OK
    } catch {
        $code = 0; $body = ''
        $r = $null
        try { $r = $_.Exception.Response } catch { }
        if ($r) { try { $code = [int]$r.StatusCode } catch { $code = 0 } }
        # PS7 surfaces the response body on ErrorDetails.Message; PS5.1 needs the stream.
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $body = [string]$_.ErrorDetails.Message
        } elseif ($r -and ($r -is [System.Net.HttpWebResponse])) {
            try {
                $sr = New-Object System.IO.StreamReader($r.GetResponseStream())
                $body = $sr.ReadToEnd(); $sr.Close()
            } catch { }
        }
        $script:RESP = $body
        switch ($code) {
            400 { return (Fail $EX_VALIDATION $code 'validation — bad body / unknown field or issue type') }
            401 { return (Fail $EX_AUTH       $code "unauthorized — token stale/invalid for role '$(RoleName)'") }
            403 { return (Fail $EX_FORBIDDEN  $code 'forbidden — permission') }
            404 { return (Fail $EX_NOTFOUND   $code 'not found (or no permission — Jira masks 403 as 404)') }
            0   { [Console]::Error.WriteLine("jira: transport error (curl failed) on $Method $Path"); return $EX_ERR }
            default { return (Fail $EX_UNEXPECTED $code 'unexpected status') }
        }
    }
}

function Fail {
    param([int]$Rc, [int]$Code, [string]$Desc)
    $detail = ''
    if ($script:RESP) {
        try {
            $o = $script:RESP | ConvertFrom-Json
            if     ($o.PSObject.Properties['errors']        -and $o.errors)        { $detail = ($o.errors        | ConvertTo-Json -Compress -Depth 20) }
            elseif ($o.PSObject.Properties['errorMessages'] -and $o.errorMessages) { $detail = ($o.errorMessages | ConvertTo-Json -Compress -Depth 20) }
            elseif ($o.PSObject.Properties['message']       -and $o.message)       { $detail = [string]$o.message }
        } catch { }
    }
    [Console]::Error.WriteLine("jira: HTTP $Code — ${Desc}: $detail")
    return $Rc
}

# Emit the raw response body to stdout with no added newline (the `cat $RESP_FILE` analogue).
function Write-Resp { [Console]::Out.Write($script:RESP); [Console]::Out.Flush() }

# ─── Layer 3: typed operations ──────────────────────────────────────────────

function Op-Whoami {
    $rc = Invoke-Request GET '/myself'; if ($rc -ne 0) { return $rc }
    Write-Resp; return $EX_OK
}

function Op-ProjectExists {
    param([string]$Key)
    $rc = Invoke-Request GET "/project/search?query=$(UrlEnc $Key)"; if ($rc -ne 0) { return $rc }
    $found = $false
    try { $found = @(($script:RESP | ConvertFrom-Json).values | Where-Object { $_.key -eq $Key }).Count -gt 0 } catch { }
    if (-not $found) { [Console]::Error.WriteLine("jira: project `"$Key`" not visible to this account"); return $EX_NOTFOUND }
    [Console]::Out.WriteLine($Key); return $EX_OK
}

function Op-IssueView {
    param([string]$Key, [string]$Fields)
    $path = "/issue/$Key"
    if ($Fields) { $path += "?fields=$(UrlEnc $Fields)" }
    $rc = Invoke-Request GET $path; if ($rc -ne 0) { return $rc }
    Write-Resp; return $EX_OK
}

function Op-IssueCreate {
    param([string]$Body)   # {"fields":…}
    $rc = Invoke-Request POST '/issue' $Body; if ($rc -ne 0) { return $rc }
    $k = ''
    try { $k = ($script:RESP | ConvertFrom-Json).key } catch { }
    [Console]::Out.WriteLine($k); return $EX_OK
}

function Op-TransitionTo {
    param([string]$Key, [string]$Status)
    $rc = Invoke-Request GET "/issue/$Key/transitions"; if ($rc -ne 0) { return $rc }
    $tid = $null
    try { $tid = (($script:RESP | ConvertFrom-Json).transitions | Where-Object { $_.to.name -eq $Status } | Select-Object -First 1).id } catch { }
    if (-not $tid) { [Console]::Error.WriteLine("jira: no transition to `"$Status`" from $Key's current status"); return $EX_NOTRANSITION }
    return (Invoke-Request POST "/issue/$Key/transitions" ('{"transition":{"id":"' + $tid + '"}}'))
}

function Op-Assign {
    param([string]$Key, [string]$Who)
    if ($Who -eq '--remove') {
        $body = '{"accountId":null}'
    } else {
        $rc = Resolve-AccountId $Who; if ($rc -ne 0) { return $rc }
        $body = '{"accountId":' + (JsonStr $script:ACCT) + '}'
    }
    return (Invoke-Request PUT "/issue/$Key/assignee" $body)
}

function Op-CommentAdd  { param([string]$Key, [string]$Body) return (Invoke-Request POST "/issue/$Key/comment" $Body) }  # {"body":…ADF…}

function Op-CommentList {
    param([string]$Key)
    $rc = Invoke-Request GET "/issue/$Key/comment"; if ($rc -ne 0) { return $rc }
    Write-Resp; return $EX_OK
}

function Op-IssueDelete {
    param([string]$Key, [bool]$WithSubtasks)
    $path = "/issue/$Key"
    if ($WithSubtasks) { $path += '?deleteSubtasks=true' }
    return (Invoke-Request DELETE $path)
}

function Op-Raw {
    param([string]$Method, [string]$Path, [string]$Body)
    $rc = Invoke-Request $Method $Path $Body; if ($rc -ne 0) { return $rc }
    if ($script:RESP) { Write-Resp }
    return $EX_OK
}

# ─── Layer 4: dispatch ──────────────────────────────────────────────────────

# Pull the global --role out of the arg list wherever it appears.
$rest = @()
$i = 0
while ($i -lt $args.Count) {
    $a = [string]$args[$i]
    if     ($a -eq '--role')   { $script:ROLE = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--role=*') { $script:ROLE = $a.Substring(7); $i += 1 }
    else   { $rest += $a; $i += 1 }
}

if ($rest.Count -lt 1) { Usage }
$group = $rest[0]
# Wrap the whole `if` in @(): a bare `$x = if(){ @(one) }` unrolls a one-element
# slice back to a scalar, and `$x.Count` then throws under StrictMode.
$tail  = @(if ($rest.Count -gt 1) { $rest[1..($rest.Count - 1)] } else { @() })

switch ($group) {
    { $_ -in @('help', '-h', '--help') } { Usage }

    'whoami' { Invoke-Ready; exit (Op-Whoami) }

    'project' {
        $verb = if ($tail.Count -ge 1) { $tail[0] } else { '' }
        switch ($verb) {
            'exists' { if ($tail.Count -ne 2) { Usage }; Invoke-Ready; exit (Op-ProjectExists $tail[1]) }
            default  { Usage }
        }
    }

    'raw' {
        if ($tail.Count -lt 2) { Usage }
        $method = $tail[0]; $path = $tail[1]
        if ($path -notlike '/*') { Die $EX_USAGE "raw PATH must start with '/' (got '$path')" }
        $body = ''; $j = 2
        while ($j -lt $tail.Count) {
            if ($tail[$j] -eq '--data-file') { $body = (Get-Content -LiteralPath $tail[$j + 1] -Raw); $j += 2 }
            else { Usage }
        }
        Invoke-Ready; exit (Op-Raw $method $path $body)
    }

    'issue' {
        $verb  = if ($tail.Count -ge 1) { $tail[0] } else { '' }
        $rest2 = @(if ($tail.Count -gt 1) { $tail[1..($tail.Count - 1)] } else { @() })
        switch ($verb) {
            'view' {
                if ($rest2.Count -lt 1) { Usage }
                $key = $rest2[0]; $fields = ''; $k = 1
                while ($k -lt $rest2.Count) { if ($rest2[$k] -eq '--fields') { $fields = $rest2[$k + 1]; $k += 2 } else { Usage } }
                Invoke-Ready; exit (Op-IssueView $key $fields)
            }
            'transition' {
                if ($rest2.Count -lt 1) { Usage }
                $key = $rest2[0]; $to = ''; $k = 1
                while ($k -lt $rest2.Count) { if ($rest2[$k] -eq '--to') { $to = $rest2[$k + 1]; $k += 2 } else { Usage } }
                if (-not $to) { Usage }
                Invoke-Ready; exit (Op-TransitionTo $key $to)
            }
            'assign' {
                if ($rest2.Count -lt 1) { Usage }
                $key = $rest2[0]; $who = ''; $k = 1
                while ($k -lt $rest2.Count) {
                    switch ($rest2[$k]) {
                        '--to'     { $who = $rest2[$k + 1]; $k += 2 }
                        '--remove' { $who = '--remove'; $k += 1 }
                        default    { Usage }
                    }
                }
                if (-not $who) { Usage }
                Invoke-Ready; exit (Op-Assign $key $who)
            }
            'delete' {
                if ($rest2.Count -lt 1) { Usage }
                $key = $rest2[0]; $subs = $false; $k = 1
                while ($k -lt $rest2.Count) { if ($rest2[$k] -eq '--with-subtasks') { $subs = $true; $k += 1 } else { Usage } }
                Invoke-Ready; exit (Op-IssueDelete $key $subs)
            }
            'create' {
                $project = ''; $type = ''; $summary = ''; $parent = ''; $assignee = ''; $descFile = ''; $adfFile = ''
                $k = 0
                while ($k -lt $rest2.Count) {
                    switch ($rest2[$k]) {
                        '--project'   { $project  = $rest2[$k + 1]; $k += 2 }
                        '--type'      { $type     = $rest2[$k + 1]; $k += 2 }
                        '--summary'   { $summary  = $rest2[$k + 1]; $k += 2 }
                        '--parent'    { $parent   = $rest2[$k + 1]; $k += 2 }
                        '--assignee'  { $assignee = $rest2[$k + 1]; $k += 2 }
                        '--desc-file' { $descFile = $rest2[$k + 1]; $k += 2 }
                        '--adf-file'  { $adfFile  = $rest2[$k + 1]; $k += 2 }
                        default       { Usage }
                    }
                }
                if (-not ($project -and $type -and $summary)) { Usage }
                if ($descFile -and $adfFile) { Die $EX_USAGE 'give --desc-file OR --adf-file, not both.' }
                Invoke-Ready
                $fields = '{"project":{"key":' + (JsonStr $project) + '},"issuetype":{"name":' + (JsonStr $type) + '},"summary":' + (JsonStr $summary)
                if ($parent) { $fields += ',"parent":{"key":' + (JsonStr $parent) + '}' }
                if ($assignee) {
                    $rc = Resolve-AccountId $assignee; if ($rc -ne 0) { exit $rc }
                    $fields += ',"assignee":{"accountId":' + (JsonStr $script:ACCT) + '}'
                }
                if     ($descFile) { $fields += ',"description":' + (ConvertTo-AdfDoc $descFile) }
                elseif ($adfFile)  { $fields += ',"description":' + (Get-Content -LiteralPath $adfFile -Raw) }
                $fields += '}'
                exit (Op-IssueCreate ('{"fields":' + $fields + '}'))
            }
            'comment' {
                $sub   = if ($rest2.Count -ge 1) { $rest2[0] } else { '' }
                $rest3 = @(if ($rest2.Count -gt 1) { $rest2[1..($rest2.Count - 1)] } else { @() })
                switch ($sub) {
                    'list' { if ($rest3.Count -ne 1) { Usage }; Invoke-Ready; exit (Op-CommentList $rest3[0]) }
                    'add'  {
                        if ($rest3.Count -lt 1) { Usage }
                        $key = $rest3[0]; $bodyFile = ''; $adfFile = ''; $k = 1
                        while ($k -lt $rest3.Count) {
                            switch ($rest3[$k]) {
                                '--body-file' { $bodyFile = $rest3[$k + 1]; $k += 2 }
                                '--adf-file'  { $adfFile  = $rest3[$k + 1]; $k += 2 }
                                default       { Usage }
                            }
                        }
                        if (-not ($bodyFile -or $adfFile)) { Usage }
                        if ($bodyFile -and $adfFile) { Die $EX_USAGE 'give --body-file OR --adf-file, not both.' }
                        Invoke-Ready
                        if ($bodyFile) { $doc = ConvertTo-AdfDoc $bodyFile } else { $doc = (Get-Content -LiteralPath $adfFile -Raw) }
                        exit (Op-CommentAdd $key ('{"body":' + $doc + '}'))
                    }
                    default { Usage }
                }
            }
            default { Usage }
        }
    }

    default { Usage }
}
