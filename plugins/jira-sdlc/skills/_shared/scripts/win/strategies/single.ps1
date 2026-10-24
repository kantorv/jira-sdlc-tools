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

# The PR verbs work on the repo set, and a single repo is a set of one: the
# shared implementations in repos.ps1 need nothing from this strategy.
function s_prs  { v_prs }
function s_gate { v_gate }
function s_land { v_land }

function s_provision { v_provision }
function s_sync      { v_sync }
function s_push      { v_push }
function s_open_prs  { v_open_prs }
function s_remove_check { v_remove_check }
