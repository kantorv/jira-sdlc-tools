# strategies/single.ps1 — twin of strategies/single.sh: the project is one repo.
# Dot-sourced by repos.ps1, which provides $Root, $BaseBranch, $ListHeader and
# the helpers. One function per verb: s_<verb>.

function s_strategy {
    # Unlisted submodules stay pinned — shown so a project can see what it could opt in.
    $pinned = (@(Get-Submodules) | ForEach-Object { $_.Path }) -join ' '
    Write-Output 'strategy=single'
    Write-Output "root=$Root"
    Write-Output 'members='
    Write-Output "pinned=$pinned"
}

function s_list {
    Write-Output $ListHeader
    $b = if ($BaseBranch) { $BaseBranch } else { '-' }
    Write-Output (Get-RepoRow '.' 'root' $b @())
}
