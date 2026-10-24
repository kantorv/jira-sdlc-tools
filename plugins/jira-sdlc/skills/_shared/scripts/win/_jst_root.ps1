# _jst_root.ps1 — Windows (PowerShell 5.1+) twin of _jst_root.sh: where the
# project lives, for every script in this folder. Dot-sourced, never run:
# `. (Join-Path $PSScriptRoot '_jst_root.ps1')`. Same rules and results as the
# bash original, which carries the full rationale; keep the two in step.
#
# Get-JstRoot — the project root: walk up from the git toplevel through
# superprojects and return the OUTERMOST level that has a .jst/ folder, or the
# outermost level when none has one. A plain repo resolves exactly as
# --show-toplevel did. $null outside a git repository.

function Get-JstRoot {
    $d = $null
    try {
        $t = (& git rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $t) { $d = ([string]$t).Trim() }
    } catch { }
    if (-not $d) { return $null }
    $outer = $null
    $found = $null
    $n = 0
    while ($d -and $n -lt 32) {   # the cap only guards against a loop
        $outer = $d
        if (Test-Path -LiteralPath (Join-Path $d '.jst') -PathType Container) { $found = $d }
        $sup = $null
        try {
            $t = (& git -C $d rev-parse --show-superproject-working-tree 2>$null)
            if ($LASTEXITCODE -eq 0 -and $t) { $sup = ([string]$t).Trim() }
        } catch { }
        $d = $sup
        $n++
    }
    if ($found) { return $found }
    return $outer
}

# Get-JstGitDir <root> — the gitdir a .git *file* points at, absolute; $null
# when .git is a directory. A relative gitdir is relative to <root>, not to the
# caller's location.
function Get-JstGitDir {
    param([string]$Root)
    $dotGit = Join-Path $Root '.git'
    if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { return $null }
    $gd = (Get-Content -LiteralPath $dotGit |
        Where-Object { $_ -match '^gitdir:\s*(.*)$' } |
        ForEach-Object { $Matches[1].Trim() } |
        Select-Object -First 1)
    if (-not $gd) { return $null }
    if ($gd -notmatch '^(/|[A-Za-z]:)') { $gd = "$Root/$gd" }
    return $gd
}

# Test-JstLinkedWorktree <root> — $true when <root> is a linked worktree. A
# submodule's .git is a file too, but it points at …/modules/<name>, not at
# …/worktrees/<name>.
function Test-JstLinkedWorktree {
    param([string]$Root)
    $gd = Get-JstGitDir $Root
    if (-not $gd) { return $false }
    return ((Split-Path -Leaf (Split-Path -Parent $gd)) -eq 'worktrees')
}

# Get-JstMainCheckout <root> — the main checkout's root when <root> is a linked
# worktree whose main checkout still exists (three parents up from the gitdir);
# $null otherwise.
function Get-JstMainCheckout {
    param([string]$Root)
    if (-not (Test-JstLinkedWorktree $Root)) { return $null }
    $m = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Get-JstGitDir $Root)))
    if ($m -and (Test-Path -LiteralPath (Join-Path $m '.git') -PathType Container)) { return $m }
    return $null
}
