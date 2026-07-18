# statuscheck.ps1 — Windows (PowerShell 5.1+) port of statuscheck.sh.
# Same pre-flight healthcheck: gathers every environment fact a skill needs
# (worktree, branch, issue key, platform, CLI auth, project config) in ONE run
# and prints the SAME markdown table + exit code as the bash original. Mirror
# the bash logic; keep them in sync.
#
# Usage: powershell -File statuscheck.ps1 [ISSUE-KEY]
#   The issue key is normally derived from the branch and reported in the
#   `issue_key` row; passing an issue-key-shaped ISSUE-KEY (PROJ-123) makes the
#   script compare it itself. A positional arg that is NOT issue-key-shaped —
#   e.g. a role name like "reviewer" carried over from jira_acli_login — is
#   ignored, not compared. statuscheck takes no role argument.
#
# Config: resolves PROJECT-KEY / DEFAULT_BASE_BRANCH from jira-sdlc-tools.env +
# jira-sdlc-tools.local.env (local overrides team; `NAME = value` lines, parsed
# not sourced), exactly as statuscheck.sh does.
#
# Exit code: 0 = all required checks OK; 1 = at least one FAIL row.
# Row statuses: OK / FAIL (remedy printed) / WARN / INFO (context only).
#
# STATUSCHECK_FORCE_OS overrides OS detection so the Windows platform branch
# can be exercised on Linux/CI — statuscheck.sh honors the same override and
# emits an identical `platform` row.

param([string]$Key)

$KeyArg = $Key
$Rerun  = if ($env:STATUSCHECK_RERUN) { $env:STATUSCHECK_RERUN } else { 'rerun /jira-sdlc:jira-task-executor' }

$script:Rows     = @()
$script:Remedies = @()
$script:Failed   = 0

function Get-GitTop {
    try {
        $t = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $t) { return ([string]$t).Trim() }
    } catch { }
    return $null
}

function Add-Row {  # Add-Row <name> <status> <detail> [remedy]
    param([string]$Name, [string]$Status, [string]$Detail, [string]$Remedy)
    $d = ($Detail -replace '\|', '/')   # keep the table parseable
    if (-not $d) { $d = '—' }
    $script:Rows += "| $Name | $Status | $d |"
    if ($Status -eq 'FAIL') {
        $script:Failed = 1
        if ($Remedy) { $script:Remedies += ('- `' + $Name + '`: ' + $Remedy) }
    }
}

function Write-Report {
    $keyLabel = if ($Key) { $Key } else { 'no issue key' }
    Write-Output "## jira-sdlc statuscheck — $keyLabel"
    Write-Output ""
    Write-Output "| check | status | detail |"
    Write-Output "|---|---|---|"
    foreach ($r in $script:Rows) { Write-Output $r }
    if ($script:Failed -ne 0) {
        Write-Output ""
        Write-Output "Remedies for FAIL rows (relay these to the user — don't self-repair):"
        foreach ($m in $script:Remedies) { Write-Output $m }
    }
}

# --- derive the issue key from the branch up front ---------------------------
$Br = (& git branch --show-current 2>$null)
$Br = if ($Br) { ([string]$Br).Trim() } else { '' }
$BrTail = $Br -replace '^[^/]*/', ''
$BrKey  = if ($BrTail -match '^([A-Za-z][A-Za-z0-9]*-[0-9]+)') { $Matches[1] } else { '' }
# Only honor a positional arg that has the issue-key shape (PROJ-123). Any other
# value — most often a role name like "reviewer" carried over by mistake from the
# preceding `jira_acli_login <role>` call — is NOT an issue key: ignore it and fall
# back to the branch-derived key, exactly as the no-arg path does, instead of
# FAILing issue_key against it. statuscheck itself takes no role argument.
$KeyArgIgnored = ''
if ($KeyArg -and ($KeyArg -notmatch '^[A-Za-z][A-Za-z0-9]*-[0-9]+$')) {
    $KeyArgIgnored = $KeyArg
    $KeyArg = ''
    $Key    = ''   # don't let the bogus arg leak into the title/remedies
}
if (-not $Key) { $Key = $BrKey }   # best known key, for the title/remedies

# --- mandatory jira-sdlc-tools.local.env gate (runs before any other check) --
# A linked worktree is born without the gitignored local.env; the copy logic
# lives only in ensure_local_env.ps1, so delegate to it (run as a child PowerShell so
# its `exit` can't terminate us) rather than duplicating the copy.
$WtRoot = Get-GitTop
$IsWt   = ($WtRoot -and (Test-Path -LiteralPath (Join-Path $WtRoot '.git') -PathType Leaf))
$EnvLocalCopied     = $false
$EnvLocalCopiedFrom = ''
if ($WtRoot) {
    $preExisted = Test-Path -LiteralPath (Join-Path $WtRoot 'jira-sdlc-tools.local.env')
    $selfExe = if (Test-Path "$PSHOME\pwsh.exe" -PathType Leaf) { "$PSHOME\pwsh.exe" } else { "$PSHOME\powershell.exe" }
    & $selfExe -NoProfile -File (Join-Path $PSScriptRoot 'ensure_local_env.ps1') *> $null
    if ($LASTEXITCODE -ne 0) {
        Add-Row env_local FAIL "mandatory jira-sdlc-tools.local.env missing — not in this worktree and not copyable from the main repo" `
            "create jira-sdlc-tools.local.env in the main checkout first (Jira URL/email/token — see skills/_shared/project-config.md), then $Rerun."
        Write-Report
        exit 1
    }
    if ((-not $preExisted) -and $IsWt -and (Test-Path -LiteralPath (Join-Path $WtRoot 'jira-sdlc-tools.local.env'))) {
        $EnvLocalCopied = $true
        $gd = (Get-Content -LiteralPath (Join-Path $WtRoot '.git') |
            Where-Object { $_ -match '^gitdir:\s*(.*)$' } |
            ForEach-Object { $Matches[1].Trim() } | Select-Object -First 1)
        if ($gd) { $EnvLocalCopiedFrom = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $gd)) }
    }
}

# --- git repo / worktree -----------------------------------------------------
if (-not $WtRoot) {
    $wtKey = if ($Key) { $Key } else { '<KEY>' }
    Add-Row git_repo FAIL "not inside a git repository (cwd: $((Get-Location).Path))" `
        "cd into the per-issue worktree jira-task-assigner created (worktree-$wtKey) and $Rerun."
} else {
    Add-Row git_repo OK "root: $WtRoot"
    if ($IsWt) {
        Add-Row worktree INFO "linked worktree: $(Split-Path -Leaf $WtRoot) (.git is a file)"
    } else {
        Add-Row worktree INFO "main repo checkout (.git is a directory)"
    }
}

# --- platform (single source of truth for "am I on Windows") -----------------
# Mirrors statuscheck.sh's platform block; the win/*.ps1 ports live in this
# script's own directory ($PSScriptRoot).
function Get-DetectedOS {
    # $IsWindows/$IsMacOS/$IsLinux are PS6+ automatic vars; undefined on
    # Windows PowerShell 5.1. $env:OS is 'Windows_NT' on Windows, unset on
    # Linux/macOS — a reliable 5.1+7 cross-version signal.
    if ($null -eq $IsWindows) { return $(if ($env:OS -eq 'Windows_NT') { 'windows' } else { 'linux' }) }
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS)   { return 'darwin' }
    if ($IsLinux)   { return 'linux' }
    return 'unknown'
}
$forced = $env:STATUSCHECK_FORCE_OS
switch ($forced) {
    { $_ -in 'linux', 'darwin', 'windows' } { $OS = $forced; $OsForced = ' (forced via STATUSCHECK_FORCE_OS)' }
    { [string]::IsNullOrEmpty($_) }         { $OS = Get-DetectedOS; $OsForced = '' }
    default { $OS = Get-DetectedOS; $OsForced = " (STATUSCHECK_FORCE_OS='$forced' invalid — ignored)" }
}
if ($OS -eq 'windows') {
    $winDir = $PSScriptRoot
    $missing = ''
    $major = $PSVersionTable.PSVersion.Major   # 5.1+ acceptable — scripts are compatible with both
    if (-not (Get-Command acli -ErrorAction SilentlyContinue)) { $missing += ' acli' }
    if (-not (Get-Command gh   -ErrorAction SilentlyContinue)) { $missing += ' gh' }
    foreach ($s in 'statuscheck', 'ensure_local_env', 'jira_acli_login', 'get_assignee_email', 'check_assignee', 'github_pat_auth') {
        if (-not (Test-Path -LiteralPath (Join-Path $winDir "$s.ps1"))) { $missing += " win/$s.ps1" }
    }
    if ($missing) {
        Add-Row platform FAIL "os=windows$OsForced — missing:$missing" `
            "on Windows the skills dispatch to pwsh/powershell scripts/win/*.ps1 — install PowerShell 5.1+ + acli + gh and ensure the win/ ports are present, then $Rerun."
    } else {
        Add-Row platform OK "os=windows$OsForced — PowerShell $major + acli + gh + win/ ports present (Windows dispatch path ready)"
    }
} else {
    Add-Row platform INFO "os=$OS$OsForced — POSIX path: skills run the bash scripts in _shared/scripts/posix/"
}

# --- project config ----------------------------------------------------------
$CfgDir = if ($WtRoot) { $WtRoot } else { (Get-Location).Path }
function Get-Cfg {  # Get-Cfg <NAME-PATTERN> -> value; local.env overrides .env
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

$ProjectKey       = Get-Cfg 'PROJECT[-_]KEY'
$BaseBranch       = Get-Cfg 'DEFAULT_BASE_BRANCH'
$ProductionBranch = Get-Cfg 'PRODUCTION_BRANCH'
if (-not (Test-Path -LiteralPath (Join-Path $CfgDir 'jira-sdlc-tools.env'))) {
    Add-Row env_config FAIL "jira-sdlc-tools.env not found in $CfgDir" `
        "create jira-sdlc-tools.env in the project root (variables described in skills/_shared/project-config.md), then $Rerun."
} elseif (-not $ProjectKey) {
    Add-Row env_config FAIL "jira-sdlc-tools.env found but PROJECT-KEY is unset" `
        "add PROJECT-KEY to jira-sdlc-tools.env (see skills/_shared/project-config.md), then $Rerun."
} else {
    Add-Row env_config OK "PROJECT-KEY=$ProjectKey"
}

# --- jira-sdlc-tools.local.env -----------------------------------------------
if (Test-Path -LiteralPath (Join-Path $CfgDir 'jira-sdlc-tools.local.env')) {
    if ($EnvLocalCopied) {
        Add-Row env_local OK "auto-copied from main repo ($EnvLocalCopiedFrom)"
    } else {
        Add-Row env_local OK "jira-sdlc-tools.local.env present"
    }
    & git -C $CfgDir ls-files --error-unmatch jira-sdlc-tools.local.env *> $null
    $tracked = ($LASTEXITCODE -eq 0)
    & git -C $CfgDir check-ignore -q jira-sdlc-tools.local.env *> $null
    $ignored = ($LASTEXITCODE -eq 0)
    if ($tracked) {
        Add-Row env_local_ignored FAIL "jira-sdlc-tools.local.env is TRACKED by git — the account email and credential path are in shared history" `
            "git rm --cached jira-sdlc-tools.local.env, add it to .gitignore, and rotate the leaked Jira token before anything else."
    } elseif ($ignored) {
        Add-Row env_local_ignored OK "gitignored (never committed)"
    } else {
        Add-Row env_local_ignored FAIL "jira-sdlc-tools.local.env is NOT gitignored — committing it would leak the account email and credential path" `
            "add jira-sdlc-tools.local.env to .gitignore first, then $Rerun."
    }
} else {
    Add-Row env_local FAIL "jira-sdlc-tools.local.env not found in $CfgDir" `
        "create it in the project root (Jira URL/email/token — see skills/_shared/project-config.md); don't copy a teammate's, it holds their token and account."
    Add-Row env_local_ignored INFO "skipped (file absent)"
}

# --- current branch ----------------------------------------------------------
$BranchOk = $false
if (-not $Br) {
    Add-Row branch INFO "detached HEAD or no current branch"
} elseif ($BaseBranch -and ($Br -ceq $BaseBranch)) {
    Add-Row branch INFO "$Br (base branch — matches DEFAULT_BASE_BRANCH)"
} elseif (($Br -clike 'feature/*') -or ($Br -clike 'hotfix/*')) {
    $BranchOk = $true
    Add-Row branch INFO "$Br (feature/hotfix issue branch)"
} else {
    Add-Row branch INFO "$Br (neither DEFAULT_BASE_BRANCH nor a feature/hotfix issue branch)"
}

if ($BranchOk -and $ProjectKey) {
    if ($BrTail -clike "$ProjectKey-*") {
        Add-Row branch_project OK "branch belongs to project $ProjectKey"
    } else {
        Add-Row branch_project FAIL "'$Br' doesn't start with $ProjectKey- — this worktree was set up for another project's issue" `
            "switch to the branch for $(if ($Key) { $Key } else { '<KEY>' }) in this project's worktree, then $Rerun."
    }
} else {
    Add-Row branch_project WARN "skipped (branch or PROJECT-KEY unavailable — see rows above)"
}

# --- issue key (derived from branch; compared only if one was passed) --------
if ($KeyArg) {
    if ($BrKey -eq $KeyArg) {
        Add-Row issue_key OK "branch is $KeyArg's own"
    } else {
        $bk = if ($BrKey) { $BrKey } else { 'none' }
        Add-Row issue_key FAIL "branch key '$bk' != requested '$KeyArg' — this worktree wasn't set up for this issue" `
            "cd into $KeyArg's own worktree/branch and $Rerun — or get explicit user confirmation before proceeding here."
    }
} elseif ($BrKey) {
    $note = if ($KeyArgIgnored) { " (ignored non-key argument '$KeyArgIgnored' — statuscheck takes no role/issue-key argument)" } else { '' }
    Add-Row issue_key OK "$BrKey (derived from branch — confirm it matches the issue you were asked to run)$note"
} else {
    $brShown = if ($Br) { $Br } else { 'none' }
    $note = if ($KeyArgIgnored) { " (ignored non-key argument '$KeyArgIgnored' — statuscheck takes no role/issue-key argument)" } else { '' }
    Add-Row issue_key WARN "no issue key derivable from branch '$brShown' (see the branch row)$note"
}

# --- gh auth (PAT-scoped; needed by every 'gh pr …') -------------------------
# AC#5: verify the agent's repo-scoped fine-grained PAT (from
# jira-sdlc-tools.local.env) authenticates against THIS repo — NOT the human's
# `gh auth status` keyring login, which the PAT model deliberately leaves
# untouched (the agent never 'logs in'; the human's gh session stays as-is).
# See ../../docs/github/GITHUB-AUTH-STRATEGY.md. Runs the helper as a child
# process (its `exit` must not terminate us). Resolving the current pwsh exe via
# (Get-Process -Id $PID).Path is cross-platform — works on Linux+pwsh (forced
# Windows testing) and on real Windows — so the check actually runs, rather than
# the $PSHOME\*.exe form which only resolves on Windows.
$ghaHelper = Join-Path $PSScriptRoot 'github_pat_auth.ps1'
$selfExe   = (Get-Process -Id $PID).Path
$ghaOut    = ((& $selfExe -NoProfile -File $ghaHelper verify 2>&1) -join "`n")
if ($ghaOut -match 'github_pat_auth: OK') {
    Add-Row gh_auth OK ($ghaOut)
} else {
    $detail = (($ghaOut -split "`n") | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
    if (-not $detail) { $detail = 'gh auth via GITHUB_PAT_TOKEN failed' }
    Add-Row gh_auth FAIL $detail `
        "set GITHUB_PAT_TOKEN in jira-sdlc-tools.local.env to the fine-grained PAT scoped to this repo (Contents:RW, Metadata:RO, Pull requests:RW) — and install gh if missing; see ../../docs/github/GITHUB-AUTH-STRATEGY.md, then $Rerun."
}

# --- acli auth (needed by every 'acli jira ...' call) ------------------------
$AcliOk = $false
if (-not (Get-Command acli -ErrorAction SilentlyContinue)) {
    Add-Row acli_auth FAIL "acli (Atlassian CLI) is not installed" `
        "install acli and run the one-time login (skills/_shared/jira-acli-reference.md §0, using the jira-sdlc-tools.local.env values), then $Rerun."
} else {
    $acliLine = ((& acli jira auth status 2>&1) | Where-Object { $_ -match '✓ Authenticated' } | Select-Object -First 1)
    if ($acliLine) {
        $AcliOk = $true
        Add-Row acli_auth OK "$acliLine (cached status — real reachability is the jira_project row below)"
    } else {
        Add-Row acli_auth FAIL "acli is installed but not authenticated with Jira" `
            "run the one-time acli login (skills/_shared/jira-acli-reference.md §0, using the jira-sdlc-tools.local.env values), then $Rerun."
    }
}

# --- Jira project reachable --------------------------------------------------
if ($AcliOk -and $ProjectKey) {
    $projOut = (& acli jira project list --paginate --json 2>$null) | Out-String
    if ($projOut -match "\b$([regex]::Escape($ProjectKey))\b") {
        Add-Row jira_project OK "project $ProjectKey reachable on the authenticated site"
    } else {
        Add-Row jira_project FAIL "project '$ProjectKey' not found via 'acli jira project list' (or the call timed out)" `
            "if acli_auth is OK but this FAILs, the stored credential is stale (auth status caches) — 'acli jira auth logout' then re-login per §0; else check PROJECT_KEY in jira-sdlc-tools.env, whether the token is scoped to a different site/board, whether this account was granted access to the board — or retry if Jira was just slow."
    }
} else {
    Add-Row jira_project WARN "skipped (acli not authenticated or PROJECT-KEY unset — see rows above)"
}

# --- context rows (never block) ----------------------------------------------
Add-Row base_branch INFO "DEFAULT_BASE_BRANCH=$(if ($BaseBranch) { $BaseBranch } else { 'unset' })"
Add-Row production_branch INFO "PRODUCTION_BRANCH=$(if ($ProductionBranch) { $ProductionBranch } else { 'unset' })"

$WorktreesDir = Get-Cfg 'WORKTREES_DIR'
if (-not $WorktreesDir) {
    Add-Row worktrees_dir WARN "WORKTREES_DIR unset in jira-sdlc-tools(.local).env"
} else {
    $wdBase = if ($WtRoot) { $WtRoot } else { (Get-Location).Path }
    if ($IsWt) {
        $wdGitdir = (Get-Content -LiteralPath (Join-Path $WtRoot '.git') |
            Where-Object { $_ -match '^gitdir:\s*(.*)$' } |
            ForEach-Object { $Matches[1].Trim() } | Select-Object -First 1)
        if ($wdGitdir) { $wdBase = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $wdGitdir)) }
    }
    $wdPath = if ([System.IO.Path]::IsPathRooted($WorktreesDir)) { $WorktreesDir } else { Join-Path $wdBase $WorktreesDir }
    if (Test-Path -LiteralPath $wdPath -PathType Container) {
        Add-Row worktrees_dir INFO "$wdPath (present)"
    } else {
        Add-Row worktrees_dir WARN "$wdPath missing — the assigner won't create it; check WORKTREES_DIR in jira-sdlc-tools.env if the convention changed"
    }
}

$Parent = (& git config "branch.$Br.parentbranch" 2>$null)
$Parent = if ($Parent) { ([string]$Parent).Trim() } else { '' }
Add-Row parent_branch INFO "$(if ($Parent) { $Parent } else { 'unset' }) (PR base; unset → fall back to Jira 'PR target branch' comment, then DEFAULT_BASE_BRANCH)"

$dirtyOut = (& git status --porcelain 2>$null)
$Dirty = if ($dirtyOut) { @($dirtyOut).Count } else { 0 }
if ($Dirty -gt 0) {
    Add-Row working_tree WARN "$Dirty uncommitted change(s) present before this run started"
} else {
    Add-Row working_tree INFO "clean"
}

# --- report ------------------------------------------------------------------
Write-Report
exit $script:Failed
