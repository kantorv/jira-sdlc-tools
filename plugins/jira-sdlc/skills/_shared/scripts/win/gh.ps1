# gh.ps1 — Windows (PowerShell 5.1+) twin of gh.sh: run gh as this project's
# GitHub identity, for one command only.
#
# Usage:  pwsh -NoProfile -File gh.ps1 <any gh arguments>
#
# Contract pair with ../posix/gh.sh: same arguments, same stdout, same exit
# codes, same "jst-gh: …" stderr. Edit one port, edit the other (AGENTS.md).
# gh.sh carries the full rationale (JST-331): GITHUB_PAT_TOKEN from
# .jst/jira-sdlc-tools.local.env becomes GH_TOKEN for that one gh process, so
# nothing global is written and gh's stored login is never a fallback.
#   127 — gh is not installed · 4 — GITHUB_PAT_TOKEN is unset · else gh's own.
#
# Two ways in:
#   run it      — the skills, and anything that wants a child process
#   dot-source  — `. (Join-Path $PSScriptRoot 'gh.ps1')` defines Invoke-JstGh,
#                 which statuscheck.ps1 and repos.ps1 call in place of `& gh`.
#                 It runs gh in-process (no extra pwsh start-up per call, and no
#                 second decode/re-encode of gh's output), so the caller's own
#                 `2> $file` / `2>$null` redirections apply to gh as usual.
#                 Docs: https://kantorv.github.io/jira-sdlc-tools/docs/gh-pat-session-login

. (Join-Path $PSScriptRoot '_jst_root.ps1')

# Get-JstGhEnvFile — the local env file the token comes from.
function Get-JstGhEnvFile {
    $root = Get-JstRoot
    if (-not $root) { $root = (Get-Location).Path }
    Join-Path (Join-Path $root '.jst') 'jira-sdlc-tools.local.env'
}

# Get-JstGhToken <file> — GITHUB_PAT_TOKEN, parsed rather than sourced (the
# file holds every role's secrets): last match wins, one quote pair stripped.
function Get-JstGhToken {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    $val = ''
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match '^\s*GITHUB_PAT_TOKEN\s*=(.*)$') { $val = $Matches[1].Trim() }
    }
    if ($val.Length -ge 2 -and (($val[0] -eq '"' -and $val[-1] -eq '"') -or ($val[0] -eq "'" -and $val[-1] -eq "'"))) {
        $val = $val.Substring(1, $val.Length - 2)
    }
    $val
}

# Invoke-JstGh <gh arguments> — gh with this project's PAT, in-process; sets
# $LASTEXITCODE like a native call. GH_TOKEN is restored afterwards, so it
# never outlives the one command.
function Invoke-JstGh {
    # A function, unlike a native command, receives an unquoted `a,b,c` as an
    # array, and splatting it would hand gh three arguments: `--json
    # number,state,url` then fails with "unknown arguments". Join each array
    # back into the one comma-separated argument `& gh` would have passed.
    $ghArgs = @(foreach ($a in $args) { if ($a -is [array]) { $a -join ',' } else { $a } })
    $tok = ''
    if (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue) {
        $tok = Get-JstGhToken (Get-JstGhEnvFile)
    }
    if (-not $tok) {
        # Not installed, or no token: the run-mode path below prints the
        # message as a native process would, so it lands wherever the caller
        # redirected stderr, and sets the exit code — one source for the text.
        & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'gh.ps1') @ghArgs
        return
    }
    $prev = $env:GH_TOKEN
    try {
        $env:GH_TOKEN = $tok
        & gh @ghArgs
    } finally {
        $env:GH_TOKEN = $prev
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced: functions only

if (-not (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('jst-gh: gh (GitHub CLI) is not installed — https://cli.github.com')
    exit 127
}
$envFile = Get-JstGhEnvFile
$token = Get-JstGhToken $envFile
if (-not $token) {
    [Console]::Error.WriteLine("jst-gh: GITHUB_PAT_TOKEN is unset in $envFile — gh runs only with this project's PAT, never gh's stored login")
    exit 4
}
$env:GH_TOKEN = $token   # this process only: run mode is always its own pwsh
& gh @args
exit $LASTEXITCODE
