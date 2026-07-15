# ensure_local_env.ps1 — Windows (PowerShell 5.1+) port of ensure_local_env.sh.
# Mirrors the bash contract exactly: same messages, same exit codes. See the
# bash original for the full rationale; kept minimal on purpose.
#
# Ensures jira-sdlc-tools.local.env exists in this checkout before anything
# reads it. A linked worktree shares only tracked files with its main checkout,
# so it is born WITHOUT this gitignored file; copy it in from the main checkout.
#
# Usage: powershell -File ensure_local_env.ps1
# Exit 0 — a linked worktree now has the file (just copied, or already had it),
#          OR this is the main checkout (nothing to copy).
# Exit 1 — a linked worktree has no local.env and the main checkout doesn't
#          either. Actionable remedy on stderr.

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

$LocalEnv = Join-Path $WtRoot 'jira-sdlc-tools.local.env'
if (Test-Path -LiteralPath $LocalEnv) { exit 0 }   # already present — don't overwrite

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

if ($MainRoot -and
    (Test-Path -LiteralPath (Join-Path $MainRoot '.git') -PathType Container) -and
    (Test-Path -LiteralPath (Join-Path $MainRoot 'jira-sdlc-tools.local.env'))) {
    try {
        Copy-Item -LiteralPath (Join-Path $MainRoot 'jira-sdlc-tools.local.env') `
                  -Destination $LocalEnv -ErrorAction Stop
    } catch { }
    if (Test-Path -LiteralPath $LocalEnv) {
        Write-Output "ensure_local_env: copied jira-sdlc-tools.local.env from the main checkout ($MainRoot)."
        exit 0
    }
}

[Console]::Error.WriteLine("ensure_local_env: jira-sdlc-tools.local.env missing here and not found in the main checkout either — create it in the main checkout first (Jira URL/email/token — see skills/_shared/project-config.md), then rerun.")
exit 1
