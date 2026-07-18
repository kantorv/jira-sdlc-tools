# github_pat_auth.ps1 — Windows (PowerShell 5.1+) port of github_pat_auth.sh.
# Runs the skills' git/gh against GitHub as the agent's repo-scoped fine-grained
# PAT, without touching the human's persistent config. Mirrors the bash twin's
# contract exactly: same subcommands, same stdout/stderr text, same exit codes.
#
# Usage:
#   powershell -File github_pat_auth.ps1 remote-url      # print the HTTPS clone URL derived from origin
#   powershell -File github_pat_auth.ps1 verify         # PAT present + GitHub accepts it (repo-scoped); exit 0/1
#   powershell -File github_pat_auth.ps1 git <args...>  # run `git` with the PAT credential helper applied
#   powershell -File github_pat_auth.ps1 gh  <args...>   # run `gh` with GH_TOKEN=<PAT> for this one process
#   powershell -File github_pat_auth.ps1 fetch            # git fetch over the PAT-based HTTPS URL into refs/remotes/origin/*
#
# Token: read from GITHUB_PAT_TOKEN in jira-sdlc-tools.local.env (machine-specific,
# gitignored — same treatment as JIRA_TOKEN). local.env stores it with the
# `NAME = value` convention; a value wrapped in a single layer of surrounding
# " or ' quotes is stripped here (a literal quote pair breaks gh's Bearer header),
# so the env file may quote the token for readability. The token is NEVER printed
# to stdout, placed on a command line, or embedded in a URL.
#
# Option A (strategy doc §4) for git push/fetch/pull: the caller passes an
# explicit HTTPS URL (from `remote-url`) as one of the args, and this wrapper
# supplies the PAT via an INLINE, BY-NAME credential helper. On Windows the
# `!f(){ ... }; f` shell snippet runs under Git for Windows' bundled MSYS `sh`,
# and `$GITHUB_PAT_TOKEN` resolves in that shell from the git process's
# environment (set here via $env:), never in argv/the URL. For gh: the token is
# set as $env:GH_TOKEN for that one `gh` process only (env vars are passed to
# children via the process environment block, so this is byte-clean on BOTH
# PS 5.1 and 7 — unlike a native string pipe, which CRLF-corrupts on 5.1).
#
# Exit codes (match the bash twin): 0 on success / relayed child success,
# 1 on bad usage, missing/invalid PAT, gh-not-installed (verify), or a wrapped
# git/gh exiting non-zero (relayed as 1, whatever the child's actual code, so
# callers can `if ($LASTEXITCODE) { exit 1 }`).
#
# See ../../docs/github/GITHUB-AUTH-STRATEGY.md for the design and the *why*:
# the agent never writes persistent auth state — exactly one identity lives in
# persistent config, the human's.

param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)

$Sub = if ($Rest -and $Rest.Count -ge 1) { $Rest[0] } else { '' }
$SubArgs = if ($Rest -and $Rest.Count -gt 1) { $Rest[1..($Rest.Count-1)] } else { @() }

function Show-Usage {
    [Console]::Error.WriteLine("github_pat_auth.ps1 — PAT-scoped git/gh for the jira-sdlc skills.")
    [Console]::Error.WriteLine("Usage:")
    [Console]::Error.WriteLine("  powershell -File github_pat_auth.ps1 remote-url          print the HTTPS clone URL derived from origin")
    [Console]::Error.WriteLine("  powershell -File github_pat_auth.ps1 verify              check the PAT is present + GitHub accepts it")
    [Console]::Error.WriteLine("  powershell -File github_pat_auth.ps1 git <git-args...>   run git with the PAT credential helper")
    [Console]::Error.WriteLine("  powershell -File github_pat_auth.ps1 gh  <gh-args...>    run gh with GH_TOKEN=<PAT> for one process")
    [Console]::Error.WriteLine("  powershell -File github_pat_auth.ps1 fetch               git fetch over the PAT-based HTTPS URL into refs/remotes/origin/*")
    [Console]::Error.WriteLine("See ../../docs/github/GITHUB-AUTH-STRATEGY.md for the design.")
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

# Same `NAME = value` parser + local-overrides-team precedence as
# statuscheck.ps1 / jira_acli_login.ps1. Keep them in sync; don't add a second.
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

# Resolve the PAT. Never echoes the value. Strips CR/LF + surrounding whitespace
# + one layer of surrounding " or ' (a quote pair in local.env breaks gh's Bearer
# header). Mirrors _pat_value in the bash twin byte-for-byte.
function Get-PatValue {
    $raw = Get-Cfg 'GITHUB_PAT_TOKEN'
    if (-not $raw) { return $null }
    $v = $raw -replace "[`r`n]", ''
    $v = $v.Trim()
    if ($v -match '^"(.*)"$') { $v = $Matches[1] }
    elseif ($v -match "^'(.*)'$") { $v = $Matches[1] }
    return $v
}

# Derive the canonical HTTPS clone URL from the human's `origin` remote.
# Accepts SSH forms (git@github.com:OWNER/REPO.git, ssh://git@github.com/...)
# and HTTPS, all normalized to https://github.com/OWNER/REPO.git — repo-generic,
# no hardcoded owner/repo. Errors if origin isn't github.com (the PAT is scoped
# to a github.com repo; a non-github origin means the PAT can't apply).
function Get-RemoteHttps {
    $url = (& git remote get-url origin 2>$null)
    if (-not $url) {
        [Console]::Error.WriteLine("github_pat_auth: no `origin` remote in this repo.")
        return $null
    }
    $ghHost = ''; $path = ''
    switch -Wildcard ($url) {
        'git@github.com:*'    { $ghHost = 'github.com'; $path = $url -replace '^git@github\.com:', '' }
        'ssh://git@github.com/*' { $ghHost = 'github.com'; $path = $url -replace '^ssh://git@github\.com/', '' }
        'ssh://github.com/*'  { $ghHost = 'github.com'; $path = $url -replace '^ssh://github\.com/', '' }
        'https://github.com/*' { $ghHost = 'github.com'; $path = $url -replace '^https://github\.com/', '' }
        'http://github.com/*' { $ghHost = 'github.com'; $path = $url -replace '^http://github\.com/', '' }
        default {
            [Console]::Error.WriteLine("github_pat_auth: origin is '$url' — not a github.com remote; the PAT is scoped to a github.com repo.")
            return $null
        }
    }
    $path = $path -replace '\.git$', ''
    if (-not $path) {
        [Console]::Error.WriteLine("github_pat_auth: could not parse owner/repo from origin '$url'.")
        return $null
    }
    return "https://$ghHost/$path.git"
}

# --- subcommands ---------------------------------------------------------

function Invoke-RemoteUrl {
    $u = Get-RemoteHttps
    if ($null -eq $u) { exit 1 }
    [Console]::Out.Write($u)   # no trailing newline — matches the bash twin's printf
    exit 0
}

function Invoke-Verify {
    $pat = Get-PatValue
    if (-not $pat) {
        [Console]::Error.WriteLine("github_pat_auth: GITHUB_PAT_TOKEN is unset or empty in jira-sdlc-tools.local.env — set it to the fine-grained PAT value (see ../../docs/github/GITHUB-AUTH-STRATEGY.md §1).")
        exit 1
    }
    $url = Get-RemoteHttps
    if ($null -eq $url) { exit 1 }
    $ownerRepo = $url -replace '^https://github\.com/', '' -replace '\.git$', ''
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine("github_pat_auth: gh is not installed — install it (https://cli.github.com), then rerun.")
        exit 1
    }
    # A repo-scoped GET that REQUIRES authentication — not `/user`, not an
    # anonymous-readable repo endpoint (a public repo returns 200 with no auth,
    # which would mask a dead/missing token). Requests the PAT's repo, and only
    # that repo: the real proof the token value + scopes work for this repo.
    $env:GH_TOKEN = $pat
    & gh api "repos/$ownerRepo" > $null 2>$null
    $code = $LASTEXITCODE
    $env:GH_TOKEN = $null
    if ($code -eq 0) {
        [Console]::Out.WriteLine("github_pat_auth: OK — GITHUB_PAT_TOKEN authenticated for $ownerRepo.")
        exit 0
    } else {
        [Console]::Error.WriteLine("github_pat_auth: GITHUB_PAT_TOKEN rejected by GitHub for $ownerRepo (401/403). Check the value in jira-sdlc-tools.local.env (a surrounding quote pair breaks it), that it is the fine-grained PAT (not a classic token), and that it is scoped to $ownerRepo with Contents + Metadata + Pull requests — see ../../docs/github/GITHUB-AUTH-STRATEGY.md.")
        exit 1
    }
}

function Invoke-Git {
    if (-not $SubArgs -or $SubArgs.Count -lt 1) { Show-Usage; exit 1 }
    $pat = Get-PatValue
    if (-not $pat) {
        [Console]::Error.WriteLine("github_pat_auth: GITHUB_PAT_TOKEN is unset or empty in jira-sdlc-tools.local.env — set it before running git (see ../../docs/github/GITHUB-AUTH-STRATEGY.md).")
        exit 1
    }
    # Clear any inherited credential helpers first (`credential.helper=` resets
    # the list so the human's keychain/gh helper is NOT consulted in addition
    # to ours), then set ours BY NAME — $GITHUB_PAT_TOKEN resolves in the
    # helper's shell from git's environment, never in argv. The `!f(){ ... }; f`
    # snippet runs under Git for Windows' bundled MSYS sh. The caller passes the
    # explicit HTTPS URL (from `remote-url`) as one of the args; we only add
    # auth, never a target. Single-quoted PS string keeps $GITHUB_PAT_TOKEN
    # literal so GIT's helper shell expands it from the env. See §4 option A.
    $env:GITHUB_PAT_TOKEN = $pat
    & git -c 'credential.helper=' -c 'credential.helper=!f(){ echo username=x-access-token; echo "password=$GITHUB_PAT_TOKEN"; }; f' @SubArgs
    $code = $LASTEXITCODE
    $env:GITHUB_PAT_TOKEN = $null
    if ($code -eq 0) { exit 0 } else { exit 1 }
}

# The explicit-HTTPS-URL form of `git fetch origin --prune`. Fetching the named
# `origin` remote would route over the human's SSH (strategy doc §3/§4: origin
# stays SSH), so instead fetch the derived HTTPS URL + PAT and map the refspec
# into refs/remotes/origin/*. Two reasons this matters: (a) the skills' prose
# reads `origin/<branch>` tracking refs, so they must stay current without
# touching the human's SSH remote; (b) a push via the explicit URL (Invoke-Git
# above) does NOT create local refs/remotes/origin/<branch> the way pushing a
# named remote does, so sibling worktrees only see the pushed branch after a
# fetch — this is that fetch. See §4 option A.
function Invoke-Fetch {
    $pat = Get-PatValue
    if (-not $pat) {
        [Console]::Error.WriteLine("github_pat_auth: GITHUB_PAT_TOKEN is unset or empty in jira-sdlc-tools.local.env — set it before fetching (see ../../docs/github/GITHUB-AUTH-STRATEGY.md).")
        exit 1
    }
    $url = Get-RemoteHttps
    if ($null -eq $url) { exit 1 }
    $env:GITHUB_PAT_TOKEN = $pat
    & git -c 'credential.helper=' -c 'credential.helper=!f(){ echo username=x-access-token; echo "password=$GITHUB_PAT_TOKEN"; }; f' fetch $url '+refs/heads/*:refs/remotes/origin/*' --prune
    $code = $LASTEXITCODE
    $env:GITHUB_PAT_TOKEN = $null
    if ($code -eq 0) { exit 0 } else { exit 1 }
}

function Invoke-Gh {
    if (-not $SubArgs -or $SubArgs.Count -lt 1) { Show-Usage; exit 1 }
    $pat = Get-PatValue
    if (-not $pat) {
        [Console]::Error.WriteLine("github_pat_auth: GITHUB_PAT_TOKEN is unset or empty in jira-sdlc-tools.local.env — set it before running gh (see ../../docs/github/GITHUB-AUTH-STRATEGY.md).")
        exit 1
    }
    # gh honors an inline GH_TOKEN ahead of any stored login and never reads or
    # writes ~/.config/gh/hosts.yml when it's set — the human's gh session is
    # untouched. This wrapper NEVER runs `gh auth login`/`gh auth logout` (§5);
    # Assert-NotAuth blocks them below. GH_TOKEN via $env: is byte-clean on both
    # PS 5.1 and 7 (env block, not a string pipe).
    Assert-NotAuth $SubArgs
    $env:GH_TOKEN = $pat
    & gh @SubArgs
    $code = $LASTEXITCODE
    $env:GH_TOKEN = $null
    if ($code -eq 0) { exit 0 } else { exit 1 }
}

# Defense-in-depth: `gh auth login` / `gh auth logout` would clobber the human's
# machine-wide gh session (strategy doc §5) — block them at the only choke point
# the skills have for gh, so a skill drift can't slip one through.
function Assert-NotAuth {
    param([string[]]$A)
    if ($A.Count -ge 2 -and $A[0] -eq 'auth' -and ($A[1] -eq 'login' -or $A[1] -eq 'logout')) {
        [Console]::Error.WriteLine("github_pat_auth: refusing 'gh auth $($A[1])' — it overwrites the human's gh session machine-wide (strategy doc §5). The agent supplies the PAT per call via GH_TOKEN; it never 'logs in'.")
        exit 1
    }
}

# --- dispatch ------------------------------------------------------------

if (-not $Sub) { Show-Usage; exit 1 }

switch ($Sub) {
    'remote-url' { Invoke-RemoteUrl }
    'verify' { Invoke-Verify }
    'git' { Invoke-Git }
    'gh' { Invoke-Gh }
    'fetch' { Invoke-Fetch }
    '-h' { Show-Usage; exit 0 }
    '--help' { Show-Usage; exit 0 }
    'help' { Show-Usage; exit 0 }
    default { Show-Usage; exit 1 }
}
