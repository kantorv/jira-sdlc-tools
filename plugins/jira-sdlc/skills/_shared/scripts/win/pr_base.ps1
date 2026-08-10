# pr_base.ps1 — Windows (PowerShell 5.1+) twin of pr_base.sh.
# Resolve the PR base branch for the leaf issue this branch belongs to.
# Same args, same stdout, same stderr, same exit codes.
#
# Usage: pwsh -File pr_base.ps1 --role <role> [--branch <BRANCH>]
#                               [--parent-key <PARENT-KEY>] [ISSUE-KEY]
#   --role is required (jira.ps1 has no default credential) and is also read
#   from $env:JIRA_ROLE; --branch resolves the base for that branch instead of
#   the checked-out one (the reviewer resolves <PARENT-BRANCH>'s base from a
#   sub-task's worktree, where the current branch is the sub-task's — see
#   pr_base.sh's header); --parent-key is the leaf's fields.parent.key from the
#   issue fetch, empty for a top-level issue; ISSUE-KEY defaults to the key
#   derived from --branch, or from the current branch when it is absent.
#
# The implementation of jira-api-reference.md §13 — see pr_base.sh's header for
# the four sources in order and why a sub-task never reaches the env default.
#
# jira.ps1 calls `exit` and writes via [Console]::Out, so it runs in its OWN
# pwsh process with stdout redirected to a file (never `&` in-process, which
# would exit this script too and capture nothing — JST-214).
#
# stdout — always exactly two lines:
#   base=<branch>   (empty when unresolved)
#   source=git-config|jira-comment|branch-search|env-default|unresolved
#
# Exit 0 — resolved.  Exit 1 — unresolved sub-task base: STOP and ask.
# Exit 2 — usage or environment error.

$ErrorActionPreference = 'Stop'

function Die  { param([string]$Msg) [Console]::Error.WriteLine($Msg); exit 2 }
function Warn { param([string]$Msg) [Console]::Error.WriteLine($Msg) }
function Emit { param([string]$Base, [string]$Source) Write-Output "base=$Base"; Write-Output "source=$Source" }

# --- args: --role, optional --branch/--parent-key, optional ISSUE-KEY --------
$Role      = $env:JIRA_ROLE
$ParentKey = ''
$Key       = ''
$Branch    = ''
$i = 0
while ($i -lt $args.Count) {
    $a = [string]$args[$i]
    if     ($a -eq '--role')          { $Role = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--role=*')      { $Role = $a.Substring(7); $i += 1 }
    elseif ($a -eq '--branch')        { $Branch = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--branch=*')    { $Branch = $a.Substring(9); $i += 1 }
    elseif ($a -eq '--parent-key')    { $ParentKey = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--parent-key=*') { $ParentKey = $a.Substring(13); $i += 1 }
    else   { $Key = $a; $i += 1 }
}
if (-not $Role) { Die "pr_base: --role is required (executor|assigner|reviewer) — jira.sh has no default credential." }

$jiraPs = Join-Path $PSScriptRoot 'jira.ps1'
$psExe  = $null
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExe = 'pwsh'
} elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
    $psExe = 'powershell'
}
if (-not $psExe) { Die "pr_base: no PowerShell runtime (pwsh/powershell) found to run jira.ps1." }

$Cur = ''
if ($Branch) {
    $Cur = $Branch
} else {
    try { $b = (& git branch --show-current 2>$null); if ($LASTEXITCODE -eq 0 -and $b) { $Cur = ([string]$b).Trim() } } catch { }
    if (-not $Cur) { Die "pr_base: not on a branch in a git repo — run this from the issue's worktree, or name one with --branch." }
}

if (-not $Key) {
    # Prefix-agnostic by construction: everything up to the first `/` is dropped,
    # so all four issue-branch prefixes (feature/bugfix/chore/hotfix) derive a key
    # with no per-prefix list to keep current.
    $brTail = $Cur -replace '^[^/]*/', ''
    if ($brTail -match '^([A-Za-z][A-Za-z0-9]*-[0-9]+)') { $Key = $Matches[1] }
    if (-not $Key) {
        Die "pr_base: no issue key derivable from branch '$Cur' — expected feature/, bugfix/, chore/ or hotfix/<KEY>-<slug>. Run from the issue's worktree, or pass the key."
    }
}

# --- 1. git config -----------------------------------------------------------
$PrBase = ''
try { $g = (& git config "branch.$Cur.parentbranch" 2>$null); if ($LASTEXITCODE -eq 0 -and $g) { $PrBase = ([string]$g).Trim() } } catch { }
if ($PrBase) { Emit $PrBase 'git-config'; exit 0 }

# --- 2. the durable `PR target branch: …` Jira comment (§11) -----------------
# The child's own stderr goes to a throwaway file, not through to ours — the
# bash twin's `2>/dev/null` on this call, without which jira.ps1's diagnostics
# would surface as this script's.
$tmp    = [System.IO.Path]::GetTempFileName()
$tmpErr = [System.IO.Path]::GetTempFileName()
try {
    $p = Start-Process -FilePath $psExe -PassThru -Wait -NoNewWindow `
        -ArgumentList @('-NoProfile', '-File', $jiraPs, '--role', $Role, 'issue', 'comment', 'list', $Key) `
        -RedirectStandardOutput $tmp -RedirectStandardError $tmpErr
    $comments = if ($p.ExitCode -eq 0) { Get-Content -LiteralPath $tmp -Raw } else { '' }
    if ($p.ExitCode -ne 0) {
        Warn "pr_base: could not read $Key's comments as role '$Role' — skipping the 'PR target branch:' fallback."
    }
} catch {
    $comments = ''
    Warn "pr_base: could not read $Key's comments as role '$Role' — skipping the 'PR target branch:' fallback."
} finally {
    Remove-Item -LiteralPath $tmp, $tmpErr -Force -ErrorAction SilentlyContinue
}
if ($comments -and $comments -match 'PR target branch: ([^"\s]+)') {
    $PrBase = $Matches[1] -replace '\.$', ''
}
if ($PrBase) { Emit $PrBase 'jira-comment'; exit 0 }

# --- 3. parent-branch search — a leaf that HAS a parent, i.e. a sub-task -----
# Normalize before counting, or one branch reads as several and looks "ambiguous":
# strip BOTH markers `git branch -a` emits — `*` (checked out here) and `+`
# (checked out in another linked worktree, the normal state of a parent branch
# while a sub-task's worktree runs this search) — and fold the remotes/origin/
# copy of a pushed branch into its local name (§12). All four issue-branch
# prefixes are searched: the parent's prefix is whichever one the assigner chose
# for that run, and a sub-task inherits it rather than picking its own.
if ($ParentKey) {
    $raw = @()
    try {
        $raw = @(& git branch -a --list `
            "*feature/$ParentKey-*" "*bugfix/$ParentKey-*" `
            "*chore/$ParentKey-*" "*hotfix/$ParentKey-*" 2>$null)
    } catch { $raw = @() }
    $candidates = @($raw |
        ForEach-Object { ([string]$_) -replace '^[+* ]+', '' -replace '^remotes/origin/', '' } |
        Where-Object { $_.Trim() } |
        Sort-Object -Unique)
    if ($candidates.Count -eq 1) { Emit $candidates[0] 'branch-search'; exit 0 }
    Emit '' 'unresolved'
    Warn "pr_base: $Key is a sub-task of $ParentKey and the parent-branch search matched $($candidates.Count) branches, not 1. STOP and ask the user which branch is the base — a sub-task's base is its parent's branch, never the env default."
    exit 1
}

# --- 4. the env default — top-level issues only ------------------------------
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
$PrBase = Get-Cfg 'DEFAULT_BASE_BRANCH'
if ($PrBase) { Emit $PrBase 'env-default'; exit 0 }

Emit '' 'unresolved'
Warn "pr_base: no base resolved for $Key and DEFAULT_BASE_BRANCH is unset in .jst/jira-sdlc-tools.env. STOP and ask the user which branch is the base."
exit 1
