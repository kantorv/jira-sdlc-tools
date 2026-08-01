# statuscheck.ps1 — Windows (PowerShell 5.1+) port of statuscheck.sh.
# Same pre-flight healthcheck: gathers every environment fact a skill needs
# (worktree, branch, issue key, platform, CLI auth, project config) in ONE run
# and prints the SAME markdown table + exit code as the bash original. Mirror
# the bash logic; keep them in sync.
#
# Usage: powershell -File statuscheck.ps1 --role assigner|executor|reviewer [ISSUE-KEY]
#   --role is REQUIRED and names the CALLING skill's role: auth is role-scoped
#   (there is no default credential), so the jira_auth / jira_project rows can
#   only probe a credential once they know whose it is. A missing or unknown
#   role is a usage error (exit 2, no table).
#   The issue key is normally derived from the branch and reported in the
#   `issue_key` row; passing an issue-key-shaped ISSUE-KEY (PROJ-123) makes the
#   script compare it itself. A positional arg that is NOT issue-key-shaped —
#   e.g. a role name passed positionally instead of via --role — is
#   ignored, not compared.
#
# Config: resolves PROJECT-KEY / DEFAULT_BASE_BRANCH from .jst/jira-sdlc-tools.env
# + .jst/jira-sdlc-tools.local.env (local overrides team; `NAME = value` lines, parsed
# not sourced), exactly as statuscheck.sh does.
#
# Exit code: 0 = all required checks OK; 1 = at least one FAIL row;
#            2 = usage error (bad/missing --role) — printed on stderr, no table.
# Row statuses: OK / FAIL (remedy printed) / WARN / INFO (context only).
#
# STATUSCHECK_FORCE_OS overrides OS detection so the Windows platform branch
# can be exercised on Linux/CI — statuscheck.sh honors the same override and
# emits an identical `platform` row.

# --- args: required --role, optional ISSUE-KEY -------------------------------
# Manual $args parsing (not param()) so the flag is the literal `--role` the
# bash twin takes. The role has no default: it selects the credential the jira
# rows authenticate with, and guessing wrong would report someone else's
# identity as if it were the caller's.
$Role = $env:JIRA_ROLE
$Key  = ''
$i = 0
while ($i -lt $args.Count) {
    $a = [string]$args[$i]
    if     ($a -eq '--role')     { $Role = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--role=*') { $Role = $a.Substring(7); $i += 1 }
    else   { $Key = $a; $i += 1 }
}
if (-not $Role) {
    [Console]::Error.WriteLine('statuscheck: --role is required — one of assigner|executor|reviewer')
    exit 2
}
if ($Role -notin @('assigner', 'executor', 'reviewer')) {
    [Console]::Error.WriteLine("statuscheck: role must be assigner|executor|reviewer (got '$Role')")
    exit 2
}
$RoleUc = $Role.ToUpper()

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
# value — most often a role name passed positionally instead of via --role — is
# NOT an issue key: ignore it and fall
# back to the branch-derived key, exactly as the no-key path does, instead of
# FAILing issue_key against it.
$KeyArgIgnored = ''
if ($KeyArg -and ($KeyArg -notmatch '^[A-Za-z][A-Za-z0-9]*-[0-9]+$')) {
    $KeyArgIgnored = $KeyArg
    $KeyArg = ''
    $Key    = ''   # don't let the bogus arg leak into the title/remedies
}
if (-not $Key) { $Key = $BrKey }   # best known key, for the title/remedies

$WtRoot = Get-GitTop
$IsWt   = ($WtRoot -and (Test-Path -LiteralPath (Join-Path $WtRoot '.git') -PathType Leaf))

# --- mandatory .jst/ gate (runs before every other check) --------------------
# Both settings files live in <repo-root>/.jst/, and nothing reads a root-level
# copy — so a missing .jst/ means no config at all, for every role. Check it
# before the local.env gate below: that gate copies a file *into* .jst/.
if (-not $WtRoot) {
    # No repo root to look under, so this gate can't run at all. Say that in a
    # row rather than printing nothing: the row map in jst-install lists jst_dir
    # as a section-1 row, and a silently absent row reads like a passing one.
    Add-Row jst_dir INFO "skipped — not inside a git repository, so there is no repo root to hold .jst/ (see git_repo)"
} else {
    $JstDir = Join-Path $WtRoot '.jst'
    if (Test-Path -LiteralPath $JstDir -PathType Container) {
        Add-Row jst_dir OK "$JstDir"
    } else {
        Add-Row jst_dir FAIL "settings folder $JstDir not found — the skills read their config only from there" `
            "create .jst/ in the project root holding jira-sdlc-tools.env (team-shared, tracked) and jira-sdlc-tools.local.env (machine-specific, gitignored) — see skills/_shared/project-config.md — then $Rerun."
        Write-Report
        exit 1
    }
}

# --- mandatory .jst/jira-sdlc-tools.local.env gate (before any other check) --
# A linked worktree is born without the gitignored local.env; the copy logic
# lives only in ensure_local_env.ps1, so delegate to it (run as a child PowerShell so
# its `exit` can't terminate us) rather than duplicating the copy.
$EnvLocalCopied     = $false
$EnvLocalCopiedFrom = ''
if ($WtRoot) {
    $preExisted = Test-Path -LiteralPath (Join-Path $WtRoot '.jst/jira-sdlc-tools.local.env')
    $selfExe = if (Test-Path "$PSHOME\pwsh.exe" -PathType Leaf) { "$PSHOME\pwsh.exe" } else { "$PSHOME\powershell.exe" }
    & $selfExe -NoProfile -File (Join-Path $PSScriptRoot 'ensure_local_env.ps1') *> $null
    if ($LASTEXITCODE -ne 0) {
        Add-Row env_local FAIL "mandatory .jst/jira-sdlc-tools.local.env missing — not in this worktree and not copyable from the main repo" `
            "create .jst/jira-sdlc-tools.local.env in the main checkout first (Jira URL/email/token — see skills/_shared/project-config.md), then $Rerun."
        Write-Report
        exit 1
    }
    if ((-not $preExisted) -and $IsWt -and (Test-Path -LiteralPath (Join-Path $WtRoot '.jst/jira-sdlc-tools.local.env'))) {
        $EnvLocalCopied = $true
        $gd = (Get-Content -LiteralPath (Join-Path $WtRoot '.git') |
            Where-Object { $_ -match '^gitdir:\s*(.*)$' } |
            ForEach-Object { $Matches[1].Trim() } | Select-Object -First 1)
        if ($gd) { $EnvLocalCopiedFrom = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $gd)) }
    }
}

# --- git repo / worktree -----------------------------------------------------
if (-not $WtRoot) {
    # Caller-neutral remedy on purpose: all four skills print this row, and a
    # sentence about one role's worktree is wrong for the other three (JST-251).
    Add-Row git_repo FAIL "not inside a git repository (cwd: $((Get-Location).Path))" `
        "cd into the project checkout these skills are configured for — its main checkout, or the issue's own worktree when you're running an issue — and $Rerun. If the project has no repository yet, create or clone one (with its GitHub 'origin' remote) first: the skills wire an existing repo up, they don't create it."
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
    # Name the runtime so this row matches statuscheck.sh's ($PS_RUNTIME) exactly.
    $psName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    # jira.ps1 uses native Invoke-WebRequest + ConvertFrom-Json, so the Windows
    # path needs only gh (for 'gh pr create') and the ports.
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { $missing += ' gh' }
    foreach ($s in 'statuscheck', 'ensure_local_env', 'get_assignee_email', 'check_assignee', 'jira') {
        if (-not (Test-Path -LiteralPath (Join-Path $winDir "$s.ps1"))) { $missing += " win/$s.ps1" }
    }
    if ($missing) {
        Add-Row platform FAIL "os=windows$OsForced — missing:$missing" `
            "on Windows the skills dispatch to pwsh/powershell scripts/win/*.ps1 — install PowerShell 5.1+ + gh and ensure the win/ ports are present, then $Rerun."
    } else {
        Add-Row platform OK "os=windows$OsForced — PowerShell $major ($psName) + gh + win/ ports present (Windows dispatch path ready)"
    }
} else {
    Add-Row platform INFO "os=$OS$OsForced — POSIX path: skills run the bash scripts in _shared/scripts/posix/"
}

# --- project config ----------------------------------------------------------
# Both settings files live in <repo-root>/.jst/ — the only location read.
$CfgRoot = if ($WtRoot) { $WtRoot } else { (Get-Location).Path }
$CfgDir  = Join-Path $CfgRoot '.jst'
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
        "create jira-sdlc-tools.env in the project's .jst/ folder (variables described in skills/_shared/project-config.md), then $Rerun."
} elseif (-not $ProjectKey) {
    Add-Row env_config FAIL "jira-sdlc-tools.env found but PROJECT-KEY is unset" `
        "add PROJECT-KEY to .jst/jira-sdlc-tools.env (see skills/_shared/project-config.md), then $Rerun."
} else {
    Add-Row env_config OK "PROJECT-KEY=$ProjectKey"
}

# --- .jst/jira-sdlc-tools.local.env ------------------------------------------
if (Test-Path -LiteralPath (Join-Path $CfgDir 'jira-sdlc-tools.local.env')) {
    if ($EnvLocalCopied) {
        Add-Row env_local OK "auto-copied from main repo ($EnvLocalCopiedFrom)"
    } else {
        Add-Row env_local OK ".jst/jira-sdlc-tools.local.env present"
    }
    # Run git from the repo root and name the path under .jst/ — git resolves a
    # relative pathspec against its working directory, so the two must agree.
    & git -C $CfgRoot ls-files --error-unmatch .jst/jira-sdlc-tools.local.env *> $null
    $tracked = ($LASTEXITCODE -eq 0)
    & git -C $CfgRoot check-ignore -q .jst/jira-sdlc-tools.local.env *> $null
    $ignored = ($LASTEXITCODE -eq 0)
    if ($tracked) {
        Add-Row env_local_ignored FAIL ".jst/jira-sdlc-tools.local.env is TRACKED by git — the account email and credential path are in shared history" `
            "git rm --cached .jst/jira-sdlc-tools.local.env, add it to .gitignore, and rotate the leaked Jira token before anything else."
    } elseif ($ignored) {
        Add-Row env_local_ignored OK "gitignored (never committed)"
    } else {
        Add-Row env_local_ignored FAIL ".jst/jira-sdlc-tools.local.env is NOT gitignored — committing it would leak the account email and credential path" `
            "add .jst/jira-sdlc-tools.local.env to .gitignore first, then $Rerun."
    }
} else {
    Add-Row env_local FAIL "jira-sdlc-tools.local.env not found in $CfgDir" `
        "create it in the project's .jst/ folder (Jira URL/email/token — see skills/_shared/project-config.md); don't copy a teammate's, it holds their token and account."
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
    $note = if ($KeyArgIgnored) { " (ignored non-key argument '$KeyArgIgnored' — the role goes in --role, and the key comes from the branch)" } else { '' }
    Add-Row issue_key OK "$BrKey (derived from branch — confirm it matches the issue you were asked to run)$note"
} else {
    $brShown = if ($Br) { $Br } else { 'none' }
    $note = if ($KeyArgIgnored) { " (ignored non-key argument '$KeyArgIgnored' — the role goes in --role, and the key comes from the branch)" } else { '' }
    Add-Row issue_key WARN "no issue key derivable from branch '$brShown' (see the branch row)$note"
}

# --- gh auth (needed by 'gh pr create') --------------------------------------
# Log gh in from a persistent PAT session at the very start of the run — logout
# FIRST, then login (see statuscheck.sh for the full rationale): a bare
# `gh auth login` does not reliably replace an already-stored keyring token, so
# without the logout a stale PR-read-only PAT could survive and 403 at
# `gh pr create` mid-run (JST-143). gh uses ONE shared PAT (not a per-role Jira
# identity), so this role-agnostic healthcheck — run by every skill
# before any work — is the right home for it, no per-skill wiring needed.
# GITHUB_PAT_TOKEN is a secret, machine-specific value → gitignored
# .jst/jira-sdlc-tools.local.env only. Missing token → FAIL with a remedy, and the
# skill stops like any other FAIL row. A login that runs but FAILs (non-zero
# exit — an expired or revoked PAT, etc.) also FAILs, relaying gh's first stderr
# line (token redacted) rather than falling through to a generic "no session" —
# so the actual auth error is named (JST-145 AC#3). Accepted tradeoff: this
# writes the OS-user-global gh config, overwriting the developer's own gh session
# and not restoring it afterward — see plugins/jira-sdlc/docs/github/ (JST-126/145).
$GhOk = $false
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Add-Row gh_auth FAIL "gh (GitHub CLI) is not installed" `
        "install it (https://cli.github.com), then $Rerun."
} else {
    # Get-Cfg parses rather than sources the env file, so a quoted value keeps
    # its quotes — strip one surrounding pair before handing the token to gh.
    $ghPat = Get-Cfg 'GITHUB_PAT_TOKEN'
    if ($ghPat) { $ghPat = $ghPat.Trim().Trim('"').Trim("'") }
    if (-not $ghPat) {
        Add-Row gh_auth FAIL "GITHUB_PAT_TOKEN is unset — gh can't be logged in for this session" `
            "add GITHUB_PAT_TOKEN to .jst/jira-sdlc-tools.local.env (a fine-grained GitHub PAT; see .jst/jira-sdlc-tools.local.env.example and plugins/jira-sdlc/docs/github/), then $Rerun."
    } else {
        # logout FIRST — see header; non-fatal if there's nothing to log out.
        & gh auth logout --hostname github.com 2>&1 | Out-Null
        # Login: capture gh's stderr. gh never echoes the token on error, but we
        # redact it anyway (issue NOTES) before relaying. A FAILED login now FAILs
        # the row with gh's own first error line instead of falling through to the
        # generic "no session" FAIL — so a real auth failure (expired/revoked PAT,
        # etc.) is named, not buried (JST-145 AC#3). Success exits 0 with no
        # stderr; only then do we run 'gh auth status' for the account line.
        # Do NOT "simplify" this back to `$ghPat | gh auth login` (JST-171): Windows
        # PowerShell 5.1 prepends a UTF-8 BOM (EF BB BF) when piping a string into a
        # native command, so gh sends BOM+token and GitHub returns a genuine 401 for
        # a perfectly valid PAT — and the remedy line then blames the token, sending
        # people off to regenerate a working one. Nothing settable fixes the pipe on
        # 5.1 ($OutputEncoding and [Console]::OutputEncoding are both ignored; .NET
        # Framework builds StandardInput from [Console]::OutputEncoding and emits its
        # preamble, and the StandardInputEncoding that would override that is .NET
        # Core only). Hence: write the token BOM-free and let cmd redirect stdin from
        # the file — PowerShell has no stdin redirection operator for native commands.
        # Unchanged on pwsh 7. GH_TOKEN is not a substitute either — it affects only
        # this process, while the persisted session is what the executor's later
        # `gh pr create` (a separate process) depends on.
        $tmpTok = Join-Path $env:TEMP ("ghtok-" + [guid]::NewGuid().ToString('N') + ".txt")
        $loginErr = ''; $loginCode = 1
        try {
            [System.IO.File]::WriteAllText($tmpTok, $ghPat + "`n", (New-Object System.Text.UTF8Encoding $false))
            $ghExe = (Get-Command gh).Source
            $loginErr = (& cmd /c "`"$ghExe`" auth login --with-token < `"$tmpTok`" 2>&1") | Out-String
            $loginCode = $LASTEXITCODE
        } finally {
            # The PAT sits on disk in plain text until this runs — clear it even when
            # the login failed. If the delete is blocked, blank the contents first so
            # no token-bearing file can survive, then try once more.
            if (Test-Path -LiteralPath $tmpTok) { Remove-Item -LiteralPath $tmpTok -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $tmpTok) {
                [System.IO.File]::WriteAllText($tmpTok, '', (New-Object System.Text.UTF8Encoding $false))
                Remove-Item -LiteralPath $tmpTok -Force -ErrorAction SilentlyContinue
            }
        }
        if ($loginCode -eq 0) {
            $ghLine = ((& gh auth status 2>&1) | Where-Object { $_ -match 'Logged in to' } |
                Select-Object -First 1) -replace '^[^L]*', ''
            if ($ghLine) {
                $GhOk = $true
                Add-Row gh_auth OK "$ghLine (PAT session login)"
            } else {
                Add-Row gh_auth FAIL "gh auth login succeeded but 'gh auth status' reports no logged-in account" `
                    "gh reported a successful login but no active session — inspect 'gh auth status' by hand, then $Rerun."
            }
        } else {
            $redacted = if ($ghPat) { $loginErr -replace [regex]::Escape($ghPat), '[REDACTED]' } else { $loginErr }
            $err = (($redacted -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1).Trim()
            if (-not $err) { $err = '(no stderr from gh)' }
            Add-Row gh_auth FAIL "gh auth login --with-token failed: $err" `
                "check that GITHUB_PAT_TOKEN in .jst/jira-sdlc-tools.local.env is a valid, non-expired GitHub PAT (gh error above); then $Rerun."
        }
    }
}

# --- gh repo access (needed by 'gh pr create', not proved by gh_auth) --------
# gh_auth proves a LOGIN succeeded and nothing more. A fine-grained PAT scoped
# to "only selected repositories" logs in happily, reads the org and 20 other
# repos, and still cannot see this one — GitHub answers 404, not 403, so it
# looks like a typo rather than a permission (JST-251). With an SSH origin every
# git operation keeps working, and the first thing to break is `gh pr create`
# in the executor, mid-task, after the work is committed. So probe the actual
# repository here. `gh api repos/<OWNER>/<REPO>` is REST; `gh repo view` goes
# through GraphQL and fails with a different, less legible error.
# Role-agnostic like the rest: gh uses one shared PAT, not a per-role identity.
function Get-GhSlug {  # Get-GhSlug <remote-url> -> OWNER/REPO ; $null when not github.com
    param([string]$Url)
    if ($Url -notmatch 'github\.com') { return $null }
    $s = $Url -replace '^.*github\.com', ''   # ":OWNER/REPO.git" (SSH) or "/OWNER/REPO.git" (HTTPS)
    $s = $s -replace '^[:/]+', ''
    $s = $s -replace '/$', ''
    $s = $s -replace '\.git$', ''
    if ($s -notmatch '^[^/]+/[^/]+$') { return $null }
    return $s
}
if (-not $WtRoot) {
    Add-Row gh_repo_access WARN "skipped (not in a git repository, so there is no origin to probe — see git_repo)"
} else {
    $originUrl = (& git -C $WtRoot remote get-url origin 2>$null)
    $originUrl = if ($LASTEXITCODE -eq 0 -and $originUrl) { ([string]$originUrl).Trim() } else { '' }
    $ghSlug = if ($originUrl) { Get-GhSlug $originUrl } else { $null }
    if (-not $originUrl) {
        Add-Row gh_repo_access FAIL "this repository has no 'origin' remote — the skills push issue branches to it and open PRs against it" `
            "create the GitHub repository (or find the existing one) and attach it: git remote add origin git@github.com:<OWNER>/<REPO>.git — the skills don't create repositories — then $Rerun."
    } elseif (-not $GhOk) {
        Add-Row gh_repo_access WARN "skipped (gh_auth failed — the repo probe needs a logged-in gh; see rows above)"
    } elseif (-not $ghSlug) {
        Add-Row gh_repo_access WARN "origin is not a github.com remote ($originUrl) — can't probe it with gh, and 'gh pr create' won't work against it"
    } else {
        $ghApiErr = ((& gh api "repos/$ghSlug" 2>&1) | Out-String)
        if ($LASTEXITCODE -eq 0) {
            Add-Row gh_repo_access OK "$ghSlug reachable with this PAT (GET /repos/$ghSlug)"
        } elseif ($ghApiErr -match '404|Not Found|Could not resolve') {
            Add-Row gh_repo_access FAIL "the PAT authenticates but 404s on $ghSlug — usually the fine-grained token's 'only selected repositories' list doesn't include this one (GitHub answers 404, not 403, for a repo a token can't see); a renamed or deleted repository looks identical from here" `
                "add $ghSlug to GITHUB_PAT_TOKEN's repository access at https://github.com/settings/personal-access-tokens (keep Contents: read/write and Pull requests: read/write) — an org-owned repo may also need an org admin to approve the token — or fix the origin URL if the repository really moved. Then $Rerun."
        } else {
            $err = (($ghApiErr -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
            $err = if ($err) { $err.Trim() } else { '(no error output from gh)' }
            Add-Row gh_repo_access FAIL "GET /repos/$ghSlug failed: $err" `
                "resolve the error above (permissions, SSO authorization, or a transient network/API problem), then $Rerun."
        }
    }
}

# --- Jira auth (needed by every 'jira.ps1 …' call) ---------------------------
# Per-request Basic auth via `jira.ps1 --role <caller> whoami` (GET /myself): one
# live call, no global login state and no cache. Auth is role-scoped, so this
# probes the CALLING role's own credential — the identity every later call in
# this run will use. The ownership gate stays in the skill (check_assignee --role).
$JiraOk = $false
$jiraPs = Join-Path $PSScriptRoot 'jira.ps1'
$psExe  = $null
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExe = 'pwsh'
} elseif (Get-Command powershell -ErrorAction SilentlyContinue) {
    $psExe = 'powershell'
}
if (-not $psExe) {
    Add-Row jira_auth FAIL "no PowerShell runtime (pwsh/powershell) found to run jira.ps1" `
        "install PowerShell 5.1+, then $Rerun."
} else {
    $whoami = ((& $psExe -NoProfile -File $jiraPs --role $Role whoami 2>$null) | Out-String)
    if ($LASTEXITCODE -eq 0 -and $whoami.Trim()) {
        $who = ''
        try {
            $o = $whoami | ConvertFrom-Json
            $who = if ($o.emailAddress) { $o.emailAddress } elseif ($o.displayName) { $o.displayName } else { $o.accountId }
        } catch { }
        $JiraOk = $true
        Add-Row jira_auth OK "$Role authenticated as $(if ($who) { $who } else { 'unknown' }) (GET /myself)"
    } else {
        Add-Row jira_auth FAIL "the $Role Jira credential doesn't authenticate — 'jira --role $Role whoami' failed (unset/stale/invalid pair, or unreachable site)" `
            "set a working JIRA_${RoleUc}_EMAIL + JIRA_${RoleUc}_TOKEN pair in .jst/jira-sdlc-tools.local.env — see skills/_shared/jira-api-reference.md — then $Rerun."
    }
}

# --- Jira project reachable ('jira.ps1 project exists' → GET /project/search) -
if ($JiraOk -and $ProjectKey) {
    & $psExe -NoProfile -File $jiraPs --role $Role project exists $ProjectKey *> $null
    if ($LASTEXITCODE -eq 0) {
        Add-Row jira_project OK "project $ProjectKey reachable on the authenticated site"
    } else {
        Add-Row jira_project FAIL "project '$ProjectKey' not visible to the $Role account via 'jira project exists' (or the call timed out)" `
            "check PROJECT_KEY in .jst/jira-sdlc-tools.env, whether the token is scoped to a different site, and whether this account has access to the project — or retry if Jira was just slow."
    }
} else {
    Add-Row jira_project WARN "skipped (jira_auth failed or PROJECT-KEY unset — see rows above)"
}

# --- context rows (never block) ----------------------------------------------
Add-Row base_branch INFO "DEFAULT_BASE_BRANCH=$(if ($BaseBranch) { $BaseBranch } else { 'unset' })"
Add-Row production_branch INFO "PRODUCTION_BRANCH=$(if ($ProductionBranch) { $ProductionBranch } else { 'unset' })"

# Gitflow needs the two long-lived branches to be DIFFERENT branches. Its own
# row rather than a FAIL state on the pair above, so those two keep printing the
# plain values several skills quote verbatim. FAIL, not WARN: a collapsed pair is
# invalid config, not a judgement call — with one branch every feature PR targets
# production, the assigner's hotfix path (step 5C) resolves to the same branch as
# its planned path, and the release workflows have no branch name left to key the
# version off (docs/SDLC.md §5). Unset is not "equal to unset": mid-install both
# read unset until jst-install writes the file, and that is not a config error.
if ((-not $BaseBranch) -or (-not $ProductionBranch)) {
    Add-Row branch_pair INFO "skipped (DEFAULT_BASE_BRANCH or PRODUCTION_BRANCH unset — see the two rows above)"
} elseif ($BaseBranch -ceq $ProductionBranch) {
    Add-Row branch_pair FAIL "DEFAULT_BASE_BRANCH and PRODUCTION_BRANCH are both '$BaseBranch' — Gitflow needs two distinct long-lived branches, and a single-branch repo isn't a supported configuration" `
        "point DEFAULT_BASE_BRANCH and PRODUCTION_BRANCH at two different branches in .jst/jira-sdlc-tools.env (the documented pair is development / main — any two names work, but create the second branch first), then $Rerun."
} else {
    Add-Row branch_pair OK "$BaseBranch (base) and $ProductionBranch (production) are distinct"
}

# The Jira site domain, used to build browse links (https://<URL>/browse/<KEY>).
# It lives only in the gitignored .jst/jira-sdlc-tools.local.env — the same file
# as the three role tokens and the GitHub PAT — so a skill that needed it had no
# row to read and reached for the file instead, putting live credentials in the
# transcript (JST-224). Printing the one non-secret value here removes the
# reason to open that file at all. Value only: Get-Cfg returns a single key,
# never a neighbouring line.
$JiraAccountUrl = Get-Cfg 'JIRA_ACCOUNT_URL'
Add-Row jira_account_url INFO "JIRA_ACCOUNT_URL=$(if ($JiraAccountUrl) { $JiraAccountUrl } else { 'unset' }) (browse links: https://<JIRA_ACCOUNT_URL>/browse/<KEY>)"

# WORKTREES_DIR must be ABSOLUTE — see the posix twin for why a relative
# value FAILs here rather than being resolved against a per-checkout base.
$WorktreesDir = Get-Cfg 'WORKTREES_DIR'
if (-not $WorktreesDir) {
    Add-Row worktrees_dir WARN "WORKTREES_DIR unset in .jst/jira-sdlc-tools(.local).env"
} elseif ([System.IO.Path]::IsPathRooted($WorktreesDir)) {
    if (Test-Path -LiteralPath $WorktreesDir -PathType Container) {
        Add-Row worktrees_dir INFO "$WorktreesDir (present)"
    } else {
        Add-Row worktrees_dir WARN "$WorktreesDir missing — the assigner won't create it; check WORKTREES_DIR in .jst/jira-sdlc-tools.local.env if the convention changed"
    }
} else {
    # Resolved from *here* for the remedy only, and only when it really names
    # a directory: a hint resolved against the wrong base is worse than none.
    $wdAbs = $null
    $wdRp = Resolve-Path -LiteralPath $WorktreesDir -ErrorAction SilentlyContinue
    if ($wdRp -and (Test-Path -LiteralPath $wdRp.Path -PathType Container)) { $wdAbs = $wdRp.Path }
    $wdFix = if ($wdAbs) {
        "set WORKTREES_DIR=$wdAbs in .jst/jira-sdlc-tools.local.env"
    } else {
        'set WORKTREES_DIR in .jst/jira-sdlc-tools.local.env to the absolute path of that directory (e.g. /home/you/src/myapp-worktrees)'
    }
    Add-Row worktrees_dir FAIL "WORKTREES_DIR=$WorktreesDir is a relative path — it must be absolute (it resolves differently from a linked worktree than from the main checkout)" `
        "$wdFix, then $Rerun."
}

# .jst/bootstrap.sh (POSIX) / .jst/bootstrap.ps1 (Windows) is the optional,
# tracked hook a project writes to turn a fresh worktree into a *runnable*
# instance: clone the database, pick per-instance ports, install deps. See
# project-config.md and docs/RUNNING-MULTIPLE-COPIES.md. Optional by design, so
# it is INFO either way — never WARN or FAIL, because most projects won't have
# one. This script only REPORTS it: jira-task-executor step 1 is what runs it,
# which keeps a broken hook visible in that run's transcript instead of
# swallowed in here, and keeps this script side-effect-free and role-agnostic.
# Tracked, so a linked worktree is born with it — resolve against CfgDir (this
# checkout's .jst/), not the main checkout.
$BootstrapFile = if ($OS -eq 'windows') { 'bootstrap.ps1' } else { 'bootstrap.sh' }
$BootstrapPath = Join-Path $CfgDir $BootstrapFile
if (Test-Path -LiteralPath $BootstrapPath -PathType Leaf) {
    Add-Row bootstrap INFO "$BootstrapPath (present — jira-task-executor runs it in step 1)"
} else {
    Add-Row bootstrap INFO "no .jst/$BootstrapFile (optional — a project adds one to turn a fresh worktree into a runnable instance: clone the database, pick per-instance ports, install deps)"
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
