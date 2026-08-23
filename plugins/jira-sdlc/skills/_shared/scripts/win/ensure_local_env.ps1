# ensure_local_env.ps1 — Windows (PowerShell 5.1+) port of ensure_local_env.sh.
# Mirrors the bash contract exactly: same messages, same exit codes. See the
# bash original for the full rationale; kept minimal on purpose.
#
# Gives a linked worktree the whole .jst/ contract — .gitignore,
# jira-sdlc-tools.env, jira-sdlc-tools.local.env — and refuses to write the
# credential file unless git ignores that path here, so the three Jira role
# tokens and the GitHub PAT it holds are never one `git add` from a commit
# (JST-301).
#
# Usage: powershell -File ensure_local_env.ps1
# Exit 0 — a linked worktree now has the .jst/ contract and an ignored
#          local.env (just provisioned, or already there), OR this is the main
#          checkout (nothing to copy).
# Exit 1 — nothing to copy from the main checkout, or the credential path is
#          not ignored here. Actionable remedy on stderr; no unignored
#          credential file left behind.

$LocalEnvName = 'jira-sdlc-tools.local.env'

function Get-GitTop {
    try {
        $t = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $t) { return ([string]$t).Trim() }
    } catch { }
    return $null
}

$WtRoot = Get-GitTop
if (-not $WtRoot) { exit 0 }   # not a git repo — statuscheck's git_repo row FAILs on this

# A linked worktree's .git is a *file* (pointer into the main repo's
# .git/worktrees/<name>); the main checkout's .git is a directory.
$DotGit = Join-Path $WtRoot '.git'
if (-not (Test-Path -LiteralPath $DotGit -PathType Leaf)) { exit 0 }   # main checkout — nothing to copy

# .git points at "gitdir: <main>/.git/worktrees/<name>"; <main> sits three
# parents up (worktrees/<name> -> .git -> repo root).
$GitDir = (Get-Content -LiteralPath $DotGit |
    Where-Object { $_ -match '^gitdir:\s*(.*)$' } |
    ForEach-Object { $Matches[1].Trim() } |
    Select-Object -First 1)
$MainRoot = $null
if ($GitDir) {
    $MainRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $GitDir))
}
if ($MainRoot -and -not (Test-Path -LiteralPath (Join-Path $MainRoot '.git') -PathType Container)) {
    $MainRoot = $null
}

$JstDir     = Join-Path $WtRoot '.jst'
$IgnoreFile = Join-Path $JstDir '.gitignore'

# The destination folder is normally already there (.jst/ is tracked once the
# project has committed it), but create it anyway — every write below is the
# path that must not depend on that.
try { New-Item -ItemType Directory -Force -Path $JstDir -ErrorAction Stop | Out-Null } catch { }

function Sync-In {   # copy from the main checkout only when absent here
    param([string]$Name)
    if (-not $MainRoot) { return }
    $dest = Join-Path $JstDir $Name
    if (Test-Path -LiteralPath $dest) { return }
    $src = Join-Path $MainRoot (Join-Path '.jst' $Name)
    if (-not (Test-Path -LiteralPath $src)) { return }
    try { Copy-Item -LiteralPath $src -Destination $dest -ErrorAction Stop } catch { return }
    Write-Output "ensure_local_env: copied .jst/$Name from the main checkout ($MainRoot)."
}

# 1. The ignore rule, before the credential file it protects. jst-install 1b
#    puts it inside .jst/ precisely so that carrying the folder carries the
#    protection; appending it here covers the case where neither checkout has
#    the rule yet.
Sync-In '.gitignore'
$HasRule = $false
if (Test-Path -LiteralPath $IgnoreFile -PathType Leaf) {
    try {
        $HasRule = @(Get-Content -LiteralPath $IgnoreFile -ErrorAction Stop |
            Where-Object { $_ -ceq $LocalEnvName }).Count -gt 0
    } catch { }
}
if (-not $HasRule) {
    # A file whose last byte isn't a newline would otherwise swallow the rule
    # onto the end of its final line.
    $prefix = ''
    if (Test-Path -LiteralPath $IgnoreFile -PathType Leaf) {
        try {
            $raw = [System.IO.File]::ReadAllText($IgnoreFile)
            if ($raw.Length -gt 0 -and $raw[-1] -ne "`n") { $prefix = "`n" }
        } catch { }
    }
    try {
        [System.IO.File]::AppendAllText($IgnoreFile, "$prefix$LocalEnvName`n")
        Write-Output "ensure_local_env: added '$LocalEnvName' to .jst/.gitignore."
    } catch { }
}

# 2. The team-shared config. Absent from the main checkout too isn't fatal
#    here — statuscheck's env_config row reports that, with its own remedy.
Sync-In 'jira-sdlc-tools.env'

# 3. A *tracked* credential file is a different and worse problem, and it has
#    to be tested before check-ignore rather than after: check-ignore consults
#    the index, so it reports "not ignored" for a tracked path no matter what
#    .gitignore says. Falling through to the gate below would hand the user a
#    remedy that cannot clear the condition — add the rule, rerun, same error,
#    forever. Name the remedy that works, in statuscheck's words.
$LocalEnv = Join-Path $JstDir $LocalEnvName
& git -C $WtRoot ls-files --error-unmatch ".jst/$LocalEnvName" *> $null
if ($LASTEXITCODE -eq 0) {
    [Console]::Error.WriteLine("ensure_local_env: .jst/$LocalEnvName is TRACKED by git — the account email and credential path are in shared history. Run 'git rm --cached .jst/$LocalEnvName', add a line '$LocalEnvName' to .jst/.gitignore, and rotate the leaked Jira token before anything else.")
    exit 1
}

# 4. The credential file — but only once git actually ignores the path. Ask
#    git rather than trusting the write above: a negation rule elsewhere
#    ("!.jst/**") can still un-ignore it, and being wrong here is what leaks
#    the tokens.
& git -C $WtRoot check-ignore -q ".jst/$LocalEnvName" 2>$null
if ($LASTEXITCODE -ne 0) {
    if (Test-Path -LiteralPath $LocalEnv) {
        [Console]::Error.WriteLine("ensure_local_env: .jst/$LocalEnvName is present here but git does not ignore that path — it holds three Jira role tokens and a GitHub PAT that a 'git add' would commit. Add a line '$LocalEnvName' to .jst/.gitignore (where jst-install puts the rule), then rerun.")
    } else {
        [Console]::Error.WriteLine("ensure_local_env: refusing to write .jst/$LocalEnvName here — git does not ignore that path, so the three Jira role tokens and the GitHub PAT it holds would be one 'git add' away from a commit. Add a line '$LocalEnvName' to .jst/.gitignore (where jst-install puts the rule), then rerun.")
    }
    exit 1
}

if (Test-Path -LiteralPath $LocalEnv) { exit 0 }   # already present — don't overwrite

if ($MainRoot) {
    $src = Join-Path $MainRoot (Join-Path '.jst' $LocalEnvName)
    if (Test-Path -LiteralPath $src) {
        try { Copy-Item -LiteralPath $src -Destination $LocalEnv -ErrorAction Stop } catch { }
        if (Test-Path -LiteralPath $LocalEnv) {
            Write-Output "ensure_local_env: copied .jst/$LocalEnvName from the main checkout ($MainRoot)."
            exit 0
        }
    }
}

[Console]::Error.WriteLine("ensure_local_env: .jst/$LocalEnvName missing here and not found in the main checkout either — create it in the main checkout first (Jira URL/email/token — see skills/_shared/project-config.md), then rerun.")
exit 1
