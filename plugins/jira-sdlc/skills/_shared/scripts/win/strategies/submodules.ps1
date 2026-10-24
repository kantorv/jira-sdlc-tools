# strategies/submodules.ps1 — twin of strategies/submodules.sh: a parent repo
# holding its member repos as git submodules. Dot-sourced by repos.ps1, which
# provides $Root, $BaseBranch, $MembersCfg, $ListHeader and the helpers. One
# function per verb: s_<verb>. The bash twin carries the rationale.

function Test-Members {  # sets $script:Members, $script:Pinned, $script:Err; both lists empty on an error
    $script:Members = @(); $script:Pinned = @(); $script:Err = ''
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.gitmodules'))) {
        $script:Err = 'JST_MEMBERS is set, but the project has no .gitmodules — list the submodule paths that take part in issues, or leave it empty for a single-repo project'
        return
    }
    $all = @(@(Get-Submodules) | ForEach-Object { $_.Path })
    $seen = @()
    foreach ($p in @($MembersCfg -split '\s+' | Where-Object { $_ })) {
        if ($seen -contains $p) { $script:Err = "JST_MEMBERS lists '$p' twice"; break }
        if ($all -notcontains $p) { $script:Err = "JST_MEMBERS lists '$p', which isn't a top-level submodule in .gitmodules"; break }
        $seen += $p
    }
    if ($script:Err) { return }
    $script:Members = $seen
    $script:Pinned = @($all | Where-Object { $seen -notcontains $_ })
}

function s_strategy {
    Test-Members
    Write-Output 'strategy=submodules'
    Write-Output "root=$Root"
    Write-Output "members=$($script:Members -join ' ')"
    Write-Output "pinned=$($script:Pinned -join ' ')"
    if ($script:Err) { Write-Output "error=$($script:Err)"; exit 2 }
}

function Get-MemberBase {  # .gitmodules branch, else DEFAULT_BASE_BRANCH; `branch = .` reads as `error`
    param([string]$Name)
    $b = (& git config -f (Join-Path $Root '.gitmodules') --get "submodule.$Name.branch" 2>$null)
    $b = if ($b) { ([string]$b).Trim() } else { '' }
    if ($b -eq '.') { return 'error' }
    if (-not $b) { if ($BaseBranch) { return $BaseBranch } else { return '-' } }
    return $b
}

function s_list {
    Test-Members
    if ($script:Err) { Write-Output "error=$($script:Err)"; exit 2 }
    Write-Output $ListHeader
    $b = if ($BaseBranch) { $BaseBranch } else { '-' }
    # The root's own state, without its submodules (see the bash twin).
    Write-Output (Get-RepoRow '.' 'root' $b @('--ignore-submodules=all'))
    $rootUrl = (& git -C $Root remote get-url origin 2>$null)
    $rootUrl = if ($rootUrl) { ([string]$rootUrl).Trim() } else { '' }
    $subs = @(Get-Submodules)
    foreach ($p in $script:Members) {
        $name = (@($subs | Where-Object { $_.Path -eq $p }) | Select-Object -First 1).Name
        $top = (& git -C "$Root/$p" rev-parse --show-toplevel 2>$null)
        $top = if ($top) { ([string]$top).Trim() } else { '' }
        if ($top -eq "$Root/$p") {
            Write-Output (Get-RepoRow $p 'member' (Get-MemberBase $name) @())
        } else {
            $url = (& git config -f (Join-Path $Root '.gitmodules') --get "submodule.$name.url" 2>$null)
            $url = if ($url) { ([string]$url).Trim() } else { '' }
            $slug = Get-GhSlug (Resolve-SubUrl $rootUrl $url)
            if (-not $slug) { $slug = '-' }
            Write-Output (@($p, 'member', 'no', $slug, (Get-MemberBase $name), '-', '-', '-') -join "`t")
        }
    }
}

function s_prs { v_prs }

function s_gate {
    # Multistep across members needs per-member parent PRs first (see the bash twin).
    if ($OptMultistep) {
        Use-Branch
        Write-Output 'phase=stop'
        Write-Output "reason=multistep issues (Jira sub-tasks) across member repos aren't supported yet — review the sub-task PRs by hand"
        Write-Output 'root=unknown'
        Write-Output 'members=unknown'
        Exit-With 0
    }
    v_gate
}

function s_land { v_land }

function s_provision { v_provision }
function s_sync      { v_sync }
function s_push      { v_push }
function s_open_prs  { v_open_prs }
function s_remove_check { v_remove_check }
