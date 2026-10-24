# repos.ps1 — Windows (PowerShell 5.1+) twin of repos.sh: the set of repos an
# issue's work spans, behind one front door. Same arguments, same stdout, same
# stderr, same exit codes; repos.sh carries the full rationale. Design:
# https://kantorv.github.io/jira-sdlc-tools/docs/proposals/submodules-strategy
#
# Usage: pwsh -File repos.ps1 <verb> [--branch <b>] [--state all|open]
#                                    [--base <b>] [--check] [--multistep]
#   strategy  key=value lines: strategy, root, members, pinned
#   list      tab-separated rows, header first:
#             repo role initialized slug base branch dirty ahead
#   prs       tab-separated PR rows: repo slug pr state base url
#   gate      phase, reason, root, members — then the prs table
#   land      land the merged member PRs; --check verifies the gitlinks
#   provision put members whose issue branch is on origin onto it (--add: scope growth)
#   sync      merge origin/<base> into each member on the issue branch
#   push      push every repo with work its origin lacks, members first
#   open-prs  one PR per repo that needs one, plus the PR-set section
#
# Exit 0 — ok. Exit 1 — land refused or failed, or --check failed. Exit 2 —
# usage error (stderr only), or JST_MEMBERS is invalid (stdout ends with an
# `error=<reason>` line). Exit 4 — prs couldn't look up a repo.
#
# Unlike bash's $(...), an in-process PowerShell function that calls `exit`
# ends the whole script and drops output still being captured. So the verbs
# here compute first and exit only at the top, and an invalid JST_MEMBERS is
# reported before anything is captured.
#
# Writes with Write-Output, so a caller can capture it in-process with `&`
# (statuscheck.ps1 does) — unlike jira.ps1, which writes to [Console]::Out.

. (Join-Path $PSScriptRoot '_jst_root.ps1')

function Stop-Usage {
    param([string]$Message)
    [Console]::Error.WriteLine("repos: $Message")
    exit 2
}

$Verbs = 'strategy, list, prs, gate, land, provision, sync, push, open-prs'
$Verb = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
if (-not $Verb) { Stop-Usage "a verb is required — one of: $Verbs" }
if ($Verb -notin @('strategy', 'list', 'prs', 'gate', 'land', 'provision', 'sync', 'push', 'open-prs')) { Stop-Usage "unknown verb '$Verb' — one of: $Verbs" }
$OptBranch = ''; $OptState = 'all'; $OptBase = ''; $OptCheck = $false; $OptMultistep = $false
$OptAdd = ''; $OptTitle = ''; $OptBody = ''
$i = 1
while ($i -lt $args.Count) {
    $a = [string]$args[$i]
    if     ($a -eq '--branch')      { $OptBranch = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--branch=*')  { $OptBranch = $a.Substring(9); $i += 1 }
    elseif ($a -eq '--state')       { $OptState = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--state=*')   { $OptState = $a.Substring(8); $i += 1 }
    elseif ($a -eq '--base')        { $OptBase = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--base=*')    { $OptBase = $a.Substring(7); $i += 1 }
    elseif ($a -eq '--check')       { $OptCheck = $true; $i += 1 }
    elseif ($a -eq '--multistep')   { $OptMultistep = $true; $i += 1 }
    elseif ($a -eq '--add')         { $OptAdd = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--add=*')     { $OptAdd = $a.Substring(6); $i += 1 }
    elseif ($a -eq '--title')       { $OptTitle = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--title=*')   { $OptTitle = $a.Substring(8); $i += 1 }
    elseif ($a -eq '--body-file')   { $OptBody = [string]$args[$i + 1]; $i += 2 }
    elseif ($a -like '--body-file=*') { $OptBody = $a.Substring(12); $i += 1 }
    else { Stop-Usage "unknown argument '$a'" }
}
if ($OptState -notin @('all', 'open')) { Stop-Usage "--state must be all or open (got '$OptState')" }

$Root = Get-JstRoot
if (-not $Root) { Stop-Usage 'not inside a git repository' }
$CfgDir = Join-Path $Root '.jst'

# Same `NAME = value` parser as the other scripts: local.env overrides .env.
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

# --- helpers the strategies share ---------------------------------------------

function Get-GhSlug {  # OWNER/REPO, or $null when not github.com (statuscheck's rule)
    param([string]$Url)
    if ($Url -notmatch 'github\.com') { return $null }
    $s = $Url -replace '^.*?github\.com', ''
    $s = $s -replace '^:', ''
    $s = $s -replace '^/', ''
    $s = $s -replace '/$', ''
    $s = $s -replace '\.git$', ''
    if ($s -notmatch '^[^/]+/[^/]+$') { return $null }
    return $s
}

function Resolve-SubUrl {  # a .gitmodules URL, ./ and ../ resolved against the root's origin
    param([string]$Base, [string]$Url)
    if ($Url -notmatch '^\.\.?/') { return $Url }
    $b = $Base -replace '/$', ''
    $rel = $Url
    while ($true) {
        if ($rel.StartsWith('./')) { $rel = $rel.Substring(2) }
        elseif ($rel.StartsWith('../')) {
            $rel = $rel.Substring(3)
            if ($b.Contains('/')) { $b = $b.Substring(0, $b.LastIndexOf('/')) }
            elseif ($b.Contains(':')) { $b = $b.Substring(0, $b.IndexOf(':')) + ':' }
        }
        else { break }
    }
    if ($b.EndsWith(':')) { return "$b$rel" }
    return "$b/$rel"
}

function Get-Submodules {  # @{Name; Path} per top-level submodule, in .gitmodules order
    $gm = Join-Path $Root '.gitmodules'
    if (-not (Test-Path -LiteralPath $gm)) { return @() }
    $lines = @(& git config -f $gm --get-regexp '^submodule\..*\.path$' 2>$null)
    return @($lines | ForEach-Object {
        if ([string]$_ -match '^submodule\.(.*)\.path (.*)$') { [pscustomobject]@{ Name = $Matches[1]; Path = $Matches[2] } }
    })
}

function Get-RepoRow {  # one `list` row for a checked-out repo
    param([string]$Path, [string]$Role, [string]$Base, [string[]]$StatusFlags)
    $dir = if ($Path -eq '.') { $Root } else { "$Root/$Path" }
    $url = (& git -C $dir config --get remote.origin.url 2>$null)   # the configured URL, not insteadOf's rewrite (see repos.sh)
    $slug = if ($LASTEXITCODE -eq 0 -and $url) { Get-GhSlug ([string]$url).Trim() } else { $null }
    if (-not $slug) { $slug = '-' }
    $branch = (& git -C $dir branch --show-current 2>$null)
    $branch = if ($branch) { ([string]$branch).Trim() } else { '(detached)' }
    $st = @(& git -C $dir status --porcelain @StatusFlags 2>$null)
    $dirty = if ($st.Count -gt 0 -and ($st -join '').Trim()) { 'yes' } else { 'no' }
    $ahead = (& git -C $dir rev-list --count '@{u}..HEAD' 2>$null)
    $ahead = if ($LASTEXITCODE -eq 0 -and $ahead) { ([string]$ahead).Trim() } else { '-' }
    return (@($Path, $Role, 'yes', $slug, $Base, $branch, $dirty, $ahead) -join "`t")
}

$ListHeader = (@('repo', 'role', 'initialized', 'slug', 'base', 'branch', 'dirty', 'ahead') -join "`t")
$BaseBranch = Get-Cfg 'DEFAULT_BASE_BRANCH'
$MembersCfg = Get-Cfg 'JST_MEMBERS'

$Strategy = if ($MembersCfg) { 'submodules' } else { 'single' }
. (Join-Path $PSScriptRoot "strategies/$Strategy.ps1")

# --- the PR verbs (prs, gate, land) -------------------------------------------
# Twins of repos.sh's: they work on the repo set, so a single repo is just a set
# without members. Same messages, byte for byte.

$PrsHeader = (@('repo', 'slug', 'pr', 'state', 'base', 'url') -join "`t")
$RootBase = if ($OptBase) { $OptBase } else { $BaseBranch }
$ErrFile = [System.IO.Path]::GetTempFileName()

function Get-FirstLine { param([string]$Path)
    $l = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne '' }) | Select-Object -First 1
    if ($l) { return ([string]$l) } else { return '' } }

function Exit-With { param([int]$Code) Remove-Item -LiteralPath $ErrFile -Force -ErrorAction SilentlyContinue; exit $Code }

function Use-Branch {
    if (-not $script:OptBranch) {
        $b = (& git -C $Root branch --show-current 2>$null)
        $script:OptBranch = if ($b) { ([string]$b).Trim() } else { '' }
    }
    if (-not $script:OptBranch) { Stop-Usage 'no branch: the root is on a detached HEAD — pass --branch <b>' }
}

function Assert-ValidSet {   # an invalid JST_MEMBERS: say so before anything is captured
    if (Get-Command Test-Members -ErrorAction SilentlyContinue) {
        Test-Members
        if ($script:Err) { Write-Output "error=$($script:Err)"; Exit-With 2 }
    }
}

function Get-RepoSet {   # @{Repo; Slug; Base; Role} per repo, root first (from s_list)
    $rows = @(s_list | Select-Object -Skip 1)
    return @($rows | ForEach-Object {
        $f = ([string]$_) -split "`t"
        $b = if ($f[1] -eq 'root' -and $RootBase) { $RootBase } else { $f[4] }
        [pscustomobject]@{ Repo = $f[0]; Slug = $f[3]; Base = $b; Role = $f[1] }
    })
}

function Get-UrlEnc { param([string]$S) return ($S -replace '/', '%2F') }

function Get-PrRows {   # "pr`tstate`tbase`turl" per PR; $null on a gh error (message in $ErrFile)
    param([string]$Slug, [string]$Branch)
    $out = @()
    foreach ($n in 1, 2) {
        $out = @(& gh pr list -R $Slug --head $Branch --state all --json number,state,baseRefName,url `
                 --jq '.[] | [.number, .state, .baseRefName, .url] | @tsv' 2> $ErrFile)
        if ($LASTEXITCODE -ne 0) { return $null }
        $out = @($out | Where-Object { ([string]$_).Trim() -ne '' })
        if ($out.Count -gt 0) { break }
    }
    return ,$out
}

function Get-PrsTable {   # @{Lines; Rc} — the prs verb's output, computed in-process
    $lines = @($PrsHeader); $rc = 0
    foreach ($r in @(Get-RepoSet)) {
        if ($r.Slug -eq '-') {
            $lines += (@($r.Repo, '-', '-', 'error', '-', '-') -join "`t")
            [Console]::Error.WriteLine("repos: $($r.Repo): origin isn't a github.com remote, so its PRs can't be looked up")
            $rc = 4; continue
        }
        $rows = Get-PrRows $r.Slug $script:OptBranch
        if ($null -eq $rows) {
            $lines += (@($r.Repo, $r.Slug, '-', 'error', '-', '-') -join "`t")
            [Console]::Error.WriteLine("repos: $($r.Slug): $(Get-FirstLine $ErrFile)")
            $rc = 4; continue
        }
        if ($OptState -eq 'open') { $rows = @($rows | Where-Object { (([string]$_) -split "`t")[1] -eq 'OPEN' }) }
        if (@($rows).Count -eq 0) {
            $lines += (@($r.Repo, $r.Slug, '-', 'none', '-', '-') -join "`t")
        } else {
            foreach ($row in $rows) { $lines += "$($r.Repo)`t$($r.Slug)`t$row" }
        }
    }
    return [pscustomobject]@{ Lines = $lines; Rc = $rc }
}

function v_prs {
    Use-Branch; Assert-ValidSet
    $t = Get-PrsTable
    $t.Lines | ForEach-Object { Write-Output $_ }
    Exit-With $t.Rc
}

function Get-Effective {   # none | OPEN <n> | MERGED <n> | stop <reason>
    param([string[]]$Rows, [string]$Want)
    $Rows = @($Rows | Where-Object { $_ })
    if ($Rows.Count -eq 0) { return 'none' }
    $f0 = $Rows[0] -split "`t"
    $open = @($Rows | Where-Object { ($_ -split "`t")[3] -eq 'OPEN' })
    if ($open.Count -gt 1) { return "stop several OPEN PRs in $($f0[0])" }
    if ($open.Count -eq 1) {
        $o = $open[0] -split "`t"
        if ($Want -and $o[4] -ne $Want) { return "stop $($f0[1])#$($o[2]) targets '$($o[4])', but its base is '$Want'" }
        return "OPEN $($o[2])"
    }
    $m = @($Rows | Where-Object { ($_ -split "`t")[3] -eq 'MERGED' }) | Select-Object -First 1
    if ($m) { return "MERGED $(($m -split "`t")[2])" }
    $c = @($Rows | Where-Object { ($_ -split "`t")[3] -eq 'CLOSED' }) | Select-Object -First 1
    $cn = if ($c) { ($c -split "`t")[2] } else { '' }
    return "stop $($f0[1])#$cn was closed without merging — abandoned on purpose? Ask before reviewing or replacing it"
}

function Get-RepoPrRows { param($Lines, [string]$Repo)
    return @($Lines | Select-Object -Skip 1 | Where-Object { $f = ([string]$_) -split "`t"; $f[0] -eq $Repo -and $f[3] -ne 'none' }) }

function Get-TakesPart {   # no | pushed | error <message>
    param([string]$Slug, [string]$Base)
    & gh api "repos/$Slug/branches/$(Get-UrlEnc $script:OptBranch)" > $null 2> $ErrFile
    if ($LASTEXITCODE -ne 0) {
        if ((Get-Content -LiteralPath $ErrFile -Raw -ErrorAction SilentlyContinue) -match '404|Not Found') { return 'no' }
        return "error $(Get-FirstLine $ErrFile)"
    }
    $ahead = (& gh api "repos/$Slug/compare/$(Get-UrlEnc $Base)...$(Get-UrlEnc $script:OptBranch)" --jq .ahead_by 2> $ErrFile)
    if ($LASTEXITCODE -ne 0) { return "error $(Get-FirstLine $ErrFile)" }
    $n = 0; [void][int]::TryParse(([string]$ahead).Trim(), [ref]$n)
    if ($n -gt 0) { return 'pushed' } else { return 'no' }
}

function Write-Gate { param([string]$Phase, [string]$Reason, [string]$RootState, [string]$Members, $Lines)
    Write-Output "phase=$Phase"; Write-Output "reason=$Reason"; Write-Output "root=$RootState"; Write-Output "members=$Members"
    $Lines | ForEach-Object { Write-Output $_ }
    Exit-With 0
}

function v_gate {
    Use-Branch; Assert-ValidSet
    $set = @(Get-RepoSet)
    $t = Get-PrsTable
    if ($t.Rc -ne 0) {
        $bad = @($t.Lines | Select-Object -Skip 1 | Where-Object { (([string]$_) -split "`t")[3] -eq 'error' } | ForEach-Object { (([string]$_) -split "`t")[0] }) -join ' '
        Write-Gate 'stop' "PRs unknown for: $bad — gh failed; unknown is not none" 'unknown' 'unknown' $t.Lines
    }
    $root = 'none'; $rootN = ''; $stop = ''; $openM = @(); $mergedM = @(); $nPart = 0
    foreach ($r in $set) {
        $eff = Get-Effective (Get-RepoPrRows $t.Lines $r.Repo) $r.Base
        $word = ($eff -split ' ', 2)[0]
        if ($word -eq 'stop') { if (-not $stop) { $stop = $eff.Substring(5) }; continue }
        if ($r.Role -eq 'root') {
            $root = $word.ToLower(); $rootN = if ($eff.Contains(' ')) { ($eff -split ' ', 2)[1] } else { $eff }
            continue
        }
        if ($word -eq 'OPEN') { $openM += $r.Repo; $nPart++ }
        elseif ($word -eq 'MERGED') { $mergedM += $r.Repo; $nPart++ }
        else {
            $tp = Get-TakesPart $r.Slug $r.Base
            if ($tp -eq 'pushed') { if (-not $stop) { $stop = "$($r.Repo) has commits on $($script:OptBranch) ahead of $($r.Base), but no PR — pushed, no PR" } }
            elseif ($tp.StartsWith('error')) { if (-not $stop) { $stop = "could not tell whether $($r.Repo) takes part: $($tp.Substring(6)) — unknown is not none" } }
        }
    }
    $members = 'n/a'
    if (@($set | Where-Object { $_.Role -eq 'member' }).Count -gt 0) {
        if ($openM.Count -gt 0 -and $mergedM.Count -gt 0) { $members = 'mixed' }
        elseif ($openM.Count -gt 0) { $members = 'open' }
        elseif ($mergedM.Count -gt 0) { $members = 'merged' }
        else { $members = 'none' }
    }
    $o = $openM -join ' '; $m = $mergedM -join ' '
    if ($stop) { Write-Gate 'stop' $stop $root $members $t.Lines }
    if ($nPart -eq 0) {
        if ($root -eq 'none')   { Write-Gate 'none' "no PR on $($script:OptBranch) in any repo" $root $members $t.Lines }
        if ($root -eq 'open')   { Write-Gate 'review' "PR #$rootN open" $root $members $t.Lines }
        if ($root -eq 'merged') { Write-Gate 'merged' "PR #$rootN merged" $root $members $t.Lines }
    }
    if ($openM.Count -gt 0) {
        if ($root -eq 'none') {
            $mm = if ($m) { " (merged: $m)" } else { '' }
            Write-Gate 'review' "member PRs open: $o$mm" $root $members $t.Lines
        }
        Write-Gate 'stop' "the root PR #$rootN is $root while member PRs are still open ($o) — it lands only after they merge" $root $members $t.Lines
    }
    if ($root -eq 'none')   { Write-Gate 'land' "every member PR is merged ($m); no root PR yet — land it" $root $members $t.Lines }
    if ($root -eq 'open')   { Write-Gate 'review-landing' "root PR #$rootN open; every member PR is merged ($m)" $root $members $t.Lines }
    Write-Gate 'merged' "root PR #$rootN merged" $root $members $t.Lines
}

function Stop-Land { param([string]$Message) Write-Output "error=$Message"; Exit-With 1 }

function Test-IsCheckedOut { param([string]$Path)
    $top = (& git -C "$Root/$Path" rev-parse --show-toplevel 2>$null)
    return ($top -and ([string]$top).Trim() -eq "$Root/$Path") }

function v_land_check {
    Use-Branch; Assert-ValidSet
    $set = @(Get-RepoSet)
    if (@($set | Where-Object { $_.Role -eq 'member' }).Count -eq 0) { Write-Output 'check=nothing to check — no member gitlinks'; Exit-With 0 }
    & git -C $Root fetch -q origin $script:OptBranch $RootBase 2>$null | Out-Null
    $ref = "origin/$($script:OptBranch)"
    & git -C $Root rev-parse -q --verify $ref > $null 2>&1
    if ($LASTEXITCODE -ne 0) { $ref = 'HEAD' }
    Write-Output (@('repo', 'gitlink', 'base', 'result') -join "`t")
    $rc = 0
    foreach ($r in @($set | Where-Object { $_.Role -eq 'member' })) {
        $gl = ''
        $lt = (& git -C $Root ls-tree $ref -- $r.Repo 2>$null)
        if ($lt) { $gl = (([string]$lt) -split '\s+')[2] }
        if (-not $gl) { Write-Output "$($r.Repo)`t-`t$($r.Base)`tmissing from $ref"; $rc = 1; continue }
        $g12 = $gl.Substring(0, [Math]::Min(12, $gl.Length))
        & git -C "$Root/$($r.Repo)" fetch -q origin $r.Base 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Output "$($r.Repo)`t$g12`t$($r.Base)`tcannot fetch origin/$($r.Base)"; $rc = 1; continue }
        & git -C "$Root/$($r.Repo)" merge-base --is-ancestor $gl "origin/$($r.Base)" 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Output "$($r.Repo)`t$g12`t$($r.Base)`tok" }
        else { Write-Output "$($r.Repo)`t$g12`t$($r.Base)`tnot on origin/$($r.Base)"; $rc = 1 }
    }
    & git -C $Root diff --quiet "origin/$RootBase" $ref -- .gitmodules 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Output ".gitmodules`t-`t$RootBase`tchanged against origin/$RootBase — a landing PR must not move submodule settings"; $rc = 1
    }
    Exit-With $rc
}

function v_land {
    if ($OptCheck) { v_land_check }
    Use-Branch; Assert-ValidSet
    $set = @(Get-RepoSet)
    if (@($set | Where-Object { $_.Role -eq 'member' }).Count -eq 0) {
        Write-Output 'landed='; Write-Output 'reason=nothing to land — the set has no member gitlinks'; Exit-With 0
    }
    $cur = (& git -C $Root branch --show-current 2>$null)
    $cur = if ($cur) { ([string]$cur).Trim() } else { '' }
    $curShown = if ($cur) { $cur } else { 'a detached HEAD' }
    if ($cur -ne $script:OptBranch) { Stop-Land "run land from the issue worktree, on $($script:OptBranch) (the root is on '$curShown')" }
    if (@(& git -C $Root status --porcelain --ignore-submodules=all 2>$null | Where-Object { $_ }).Count -gt 0) {
        Stop-Land 'the root has uncommitted changes — commit or stash them first'
    }
    $tail = $script:OptBranch -replace '^[^/]*/', ''
    $key = if ($tail -match '^([A-Za-z][A-Za-z0-9]*-[0-9]+)') { $Matches[1] } else { '' }
    $t = Get-PrsTable
    if ($t.Rc -ne 0) { Stop-Land "PRs unknown (prs exit $($t.Rc)) — nothing changed" }
    $plan = @(); $rootEff = ''; $rootSlug = ''
    foreach ($r in $set) {
        $eff = Get-Effective (Get-RepoPrRows $t.Lines $r.Repo) $r.Base
        if ($r.Role -eq 'root') { $rootEff = $eff; $rootSlug = $r.Slug; continue }
        if ($eff.StartsWith('stop')) { Stop-Land "$($eff.Substring(5)) — nothing changed" }
        if ($eff.StartsWith('OPEN')) { Stop-Land "$($r.Slug)#$($eff.Substring(5)) is still open — merge it first; nothing changed" }
        if ($eff -eq 'none') {
            if ((Get-TakesPart $r.Slug $r.Base) -ne 'no') { Stop-Land "$($r.Repo) has work on $($script:OptBranch) but no merged PR — nothing changed" }
            continue
        }
        $n = $eff.Substring(7)
        $mc = (& gh pr view $n -R $r.Slug --json mergeCommit --jq .mergeCommit.oid 2> $ErrFile)
        if ($LASTEXITCODE -ne 0) { Stop-Land "$($r.Slug)#${n}: $(Get-FirstLine $ErrFile) — nothing changed" }
        $mc = ([string]$mc).Trim()
        if (-not (Test-IsCheckedOut $r.Repo)) { Stop-Land "$($r.Repo) isn't checked out here — nothing changed" }
        if (@(& git -C "$Root/$($r.Repo)" status --porcelain 2>$null | Where-Object { $_ }).Count -gt 0) { Stop-Land "$($r.Repo) has uncommitted changes — nothing changed" }
        & git -C "$Root/$($r.Repo)" fetch -q origin $r.Base 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-Land "can't fetch $($r.Repo)'s origin/$($r.Base) — nothing changed" }
        & git -C "$Root/$($r.Repo)" merge-base --is-ancestor $mc "origin/$($r.Base)" 2>$null
        if ($LASTEXITCODE -ne 0) { Stop-Land "$($r.Slug)#${n}'s merge commit $($mc.Substring(0, [Math]::Min(12, $mc.Length))) isn't on $($r.Repo)'s origin/$($r.Base) — nothing changed" }
        $plan += [pscustomobject]@{ Repo = $r.Repo; Mc = $mc; Ref = "$($r.Slug)#$n" }
    }
    if ($rootEff.StartsWith('MERGED')) { Stop-Land "the root PR #$($rootEff.Substring(7)) is already merged — nothing to land" }
    if ($rootEff.StartsWith('stop')) { Stop-Land "$($rootEff.Substring(5)) — nothing changed" }
    if ($plan.Count -eq 0) { Stop-Land 'no member PR has merged yet — nothing to land' }
    $body = "Lands ${key}: moves each member's gitlink to its merged PR's commit on the member's base."
    $landed = @()
    foreach ($p in $plan) {
        & git -C "$Root/$($p.Repo)" checkout -q --detach $p.Mc 2>$null
        if ($LASTEXITCODE -ne 0) { Stop-Land "checkout of $($p.Mc) in $($p.Repo) failed" }
        & git -C $Root add -- $p.Repo 2>$null
        $landed += $p.Repo
        $body += "`n- $($p.Repo) → $($p.Mc.Substring(0, [Math]::Min(12, $p.Mc.Length))) ($($p.Ref), merged)"
    }
    $landedS = $landed -join ' '
    & git -C $Root diff --cached --quiet 2>$null
    if ($LASTEXITCODE -ne 0) {
        & git -C $Root commit -q -m "${key}: land $landedS" -m $body 2>$null
        if ($LASTEXITCODE -ne 0) { Stop-Land 'the landing commit failed' }
    }
    & git -C $Root -c push.recurseSubmodules=check push -q -u origin $script:OptBranch 2> $ErrFile
    if ($LASTEXITCODE -ne 0) { Stop-Land "committed locally, but the push failed: $(Get-FirstLine $ErrFile)" }
    if ($rootEff.StartsWith('OPEN')) {
        $rn = $rootEff.Substring(5)
        $url = @($t.Lines | Select-Object -Skip 1 | Where-Object { $f = ([string]$_) -split "`t"; $f[0] -eq '.' -and $f[2] -eq $rn } | ForEach-Object { (([string]$_) -split "`t")[5] }) | Select-Object -First 1
    } else {
        $jurl = Get-Cfg 'JIRA_ACCOUNT_URL'
        $jurl = if ($jurl) { $jurl -replace '^.*?://', '' } else { '' }
        $jline = if ($jurl) { "`nJira: https://$jurl/browse/$key" } else { '' }
        $bodyFile = "$ErrFile.body"
        [System.IO.File]::WriteAllText($bodyFile, "$body`n`nEvery gitlink here points at a commit on its member's base; the reviewer checks it with ``repos.sh land --check``.`n$jline`n")
        $url = @(& gh pr create -R $rootSlug --base $RootBase --head $script:OptBranch --title "${key}: land $landedS" --body-file $bodyFile 2> $ErrFile) | Select-Object -Last 1
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
        if (-not $url) { Stop-Land "landed and pushed, but opening the root PR failed: $(Get-FirstLine $ErrFile)" }
    }
    $head = ([string](& git -C $Root rev-parse HEAD 2>$null)).Trim()
    Write-Output "landed=$landedS"; Write-Output "commit=$head"; Write-Output "pr=$url"
    Exit-With 0
}

# --- the executor's verbs (provision, sync, push, open-prs) --------------------

function Stop-Run { param([string]$Message) Write-Output "error=$Message"; Exit-With 1 }

function Test-OnBranch { param([string]$Dir)
    $b = (& git -C $Dir branch --show-current 2>$null)
    return ($b -and ([string]$b).Trim() -eq $script:OptBranch) }

function Get-Members { param($Set) return @($Set | Where-Object { $_.Role -eq 'member' }) }

function Test-RemoteBranch { param([string]$Dir)
    & git -C $Dir ls-remote --exit-code --heads origin $script:OptBranch > $null 2>&1
    return ($LASTEXITCODE -eq 0) }

function v_provision {
    Use-Branch; Assert-ValidSet
    $set = @(Get-RepoSet); $mem = Get-Members $set
    if ($mem.Count -eq 0) { Write-Output 'provisioned='; Write-Output 'pinned='; Exit-With 0 }
    if (-not (Test-OnBranch $Root)) {
        $c = (& git -C $Root branch --show-current 2>$null); $c = if ($c) { ([string]$c).Trim() } else { '' }
        Stop-Run "run provision from the issue worktree, on $($script:OptBranch) (the root is on '$c')"
    }
    $adds = @(($OptAdd -replace ',', ' ') -split '\s+' | Where-Object { $_ })
    foreach ($a in $adds) { if (-not (@($mem | Where-Object { $_.Repo -eq $a }).Count)) { Stop-Run "--add ${a}: not a member (JST_MEMBERS lists the members)" } }
    & git -C $Root submodule update -q --init --recursive 2> $ErrFile
    if ($LASTEXITCODE -ne 0) { Stop-Run "submodule update failed: $(Get-FirstLine $ErrFile)" }
    $prov = @(); $pin = @()
    foreach ($r in $mem) {
        $d = "$Root/$($r.Repo)"
        if (($adds -contains $r.Repo) -and -not (Test-RemoteBranch $d)) {
            & git -C $d fetch -q origin $r.Base 2> $ErrFile
            if ($LASTEXITCODE -ne 0) { Stop-Run "$($r.Repo): can't fetch origin/$($r.Base): $(Get-FirstLine $ErrFile)" }
            & git -C $d switch -q -c $script:OptBranch "origin/$($r.Base)" 2> $ErrFile
            if ($LASTEXITCODE -ne 0) { Stop-Run "$($r.Repo): can't create $($script:OptBranch): $(Get-FirstLine $ErrFile)" }
            & git -C $d push -q -u origin $script:OptBranch 2> $ErrFile
            if ($LASTEXITCODE -ne 0) { Stop-Run "$($r.Repo): created $($script:OptBranch), but the push failed: $(Get-FirstLine $ErrFile)" }
        }
        if (Test-RemoteBranch $d) {
            if (-not (Test-OnBranch $d)) {
                & git -C $d fetch -q origin $script:OptBranch 2>$null | Out-Null
                & git -C $d rev-parse -q --verify "refs/heads/$($script:OptBranch)" > $null 2>&1
                if ($LASTEXITCODE -eq 0) { & git -C $d switch -q $script:OptBranch 2> $ErrFile }
                else { & git -C $d switch -q -c $script:OptBranch --track "origin/$($script:OptBranch)" 2> $ErrFile }
                if ($LASTEXITCODE -ne 0) { Stop-Run "$($r.Repo): can't switch to $($script:OptBranch): $(Get-FirstLine $ErrFile)" }
            }
            & git -C $d config "branch.$($script:OptBranch).parentbranch" $r.Base
            & git -C $d submodule update -q --init --recursive 2>$null | Out-Null
            $prov += $r.Repo
        } else { $pin += $r.Repo }
    }
    & git -C $Root config push.recurseSubmodules check
    Write-Output "provisioned=$($prov -join ' ')"; Write-Output "pinned=$($pin -join ' ')"
    Exit-With 0
}

function v_sync {
    Use-Branch; Assert-ValidSet
    $synced = @()
    foreach ($r in (Get-Members @(Get-RepoSet))) {
        $d = "$Root/$($r.Repo)"
        if (-not (Test-OnBranch $d)) { continue }
        & git -C $d fetch -q origin $r.Base 2> $ErrFile
        if ($LASTEXITCODE -ne 0) { Stop-Run "$($r.Repo): can't fetch origin/$($r.Base): $(Get-FirstLine $ErrFile)" }
        & git -C $d merge -q --no-edit "origin/$($r.Base)" > $null 2> $ErrFile
        if ($LASTEXITCODE -ne 0) {
            $files = @(& git -C $d diff --name-only --diff-filter=U 2>$null | Where-Object { $_ }) -join ' '
            if (-not $files) { $files = Get-FirstLine $ErrFile }
            Write-Output "conflict=$($r.Repo)"; Write-Output "files=$files"; Write-Output "synced=$($synced -join ' ')"
            Exit-With 1
        }
        $synced += $r.Repo
    }
    Write-Output "synced=$($synced -join ' ')"
    Exit-With 0
}

function Test-NeedsPush { param([string]$Dir)
    $n = (& git -C $Dir rev-list --count '@{u}..HEAD' 2>$null)
    if ($LASTEXITCODE -ne 0) { return $true }
    $k = 0; [void][int]::TryParse(([string]$n).Trim(), [ref]$k); return ($k -gt 0) }

function v_push {
    Use-Branch; Assert-ValidSet
    $mem = Get-Members @(Get-RepoSet); $pushed = @()
    foreach ($r in $mem) {
        $d = "$Root/$($r.Repo)"
        if (-not ((Test-OnBranch $d) -and (Test-NeedsPush $d))) { continue }
        & git -C $d push -q -u origin $script:OptBranch 2> $ErrFile
        if ($LASTEXITCODE -ne 0) { Stop-Run "$($r.Repo): push failed: $(Get-FirstLine $ErrFile)" }
        $pushed += $r.Repo
    }
    if (-not (Test-OnBranch $Root)) { Stop-Run "the root isn't on $($script:OptBranch)" }
    if ($mem.Count -eq 0 -or (Test-NeedsPush $Root)) {
        & git -C $Root -c push.recurseSubmodules=check push -q -u origin $script:OptBranch 2> $ErrFile
        if ($LASTEXITCODE -ne 0) { Stop-Run "root: push failed: $(Get-FirstLine $ErrFile)" }
        $pushed += '.'
    }
    Write-Output "pushed=$($pushed -join ' ')"
    Exit-With 0
}

$PrSetOpen = '<!-- jst:pr-set -->'; $PrSetClose = '<!-- /jst:pr-set -->'

function Get-WithSet { param([string]$Body, [string]$Section)   # the body without an old PR-set section, then the new one
    $keep = @(); $skip = $false
    foreach ($l in ($Body -split "`r?`n")) {
        if ($l -eq $PrSetOpen) { $skip = $true }
        if (-not $skip) { $keep += $l }
        if ($l -eq $PrSetClose) { $skip = $false }
    }
    while ($keep.Count -gt 0 -and -not $keep[-1].Trim()) { $keep = @($keep | Select-Object -First ($keep.Count - 1)) }
    return (($keep -join "`n") + "`n`n$PrSetOpen`n$Section`n$PrSetClose`n")
}

function v_open_prs {
    Use-Branch
    if (-not $OptTitle) { Stop-Usage 'open-prs needs --title' }
    if (-not ($OptBody -and (Test-Path -LiteralPath $OptBody -PathType Leaf))) { Stop-Usage 'open-prs needs --body-file <an existing file>' }
    Assert-ValidSet
    $set = @(Get-RepoSet); $mem = Get-Members $set
    $tail = $script:OptBranch -replace '^[^/]*/', ''
    $key = if ($tail -match '^([A-Za-z][A-Za-z0-9]*-[0-9]+)') { $Matches[1] } else { '' }
    $targets = @()
    if ($mem.Count -eq 0) { $targets = @($set | Where-Object { $_.Role -eq 'root' }) }
    else {
        foreach ($r in $mem) {
            $d = "$Root/$($r.Repo)"
            & git -C $d fetch -q origin $r.Base 2>$null | Out-Null
            $a = (& git -C $d rev-list --count "origin/$($r.Base)..refs/heads/$($script:OptBranch)" 2>$null)
            $k = 0; [void][int]::TryParse(([string]$a).Trim(), [ref]$k)
            if ($k -gt 0) { $targets += $r }
        }
    }
    $t = Get-PrsTable
    if ($t.Rc -ne 0) { Stop-Run "PRs unknown (prs exit $($t.Rc)) — nothing opened" }
    $out = @((@('repo', 'slug', 'pr', 'action', 'url') -join "`t"))
    foreach ($r in $targets) {
        $eff = Get-Effective (Get-RepoPrRows $t.Lines $r.Repo) $r.Base
        if ($eff.StartsWith('stop')) { Stop-Run $eff.Substring(5) }
        if ($eff.StartsWith('OPEN')) {
            $n = $eff.Substring(5)
            $url = @($t.Lines | Select-Object -Skip 1 | Where-Object { $f = ([string]$_) -split "`t"; $f[0] -eq $r.Repo -and $f[2] -eq $n } | ForEach-Object { (([string]$_) -split "`t")[5] }) | Select-Object -First 1
            $out += "$($r.Repo)`t$($r.Slug)`t$n`texists`t$url"
        } else {
            $url = @(& gh pr create -R $r.Slug --base $r.Base --head $script:OptBranch --title $OptTitle --body-file $OptBody 2> $ErrFile) | Select-Object -Last 1
            if (-not $url) { Stop-Run "$($r.Slug): gh pr create failed: $(Get-FirstLine $ErrFile)" }
            $url = ([string]$url).Trim()
            $out += "$($r.Repo)`t$($r.Slug)`t$($url.Split('/')[-1])`tcreated`t$url"
        }
    }
    $out | ForEach-Object { Write-Output $_ }
    if ($mem.Count -eq 0) { Exit-With 0 }
    $t2 = Get-PrsTable
    if ($t2.Rc -ne 0) { Exit-With 0 }
    $rows = @($t2.Lines | Select-Object -Skip 1 | Where-Object { (([string]$_) -split "`t")[2] -ne '-' })
    $section = "**PR set** for $key (kept current by jira-sdlc):`n" + ((@($rows | ForEach-Object { $f = ([string]$_) -split "`t"; "- $($f[1])#$($f[2]) — $($f[3])" })) -join "`n")
    foreach ($row in @($rows | Where-Object { (([string]$_) -split "`t")[3] -eq 'OPEN' })) {
        $f = ([string]$row) -split "`t"
        $cur = (& gh pr view $f[2] -R $f[1] --json body --jq .body 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0) { continue }
        $cur = $cur -replace "`r?`n$", ''
        $new = Get-WithSet $cur $section
        if ($new -ne ($cur + "`n")) {
            $nf = "$ErrFile.new"; [System.IO.File]::WriteAllText($nf, $new)
            & gh pr edit $f[2] -R $f[1] --body-file $nf > $null 2>&1
            Remove-Item -LiteralPath $nf -Force -ErrorAction SilentlyContinue
        }
    }
    Exit-With 0
}

& "s_$($Verb -replace '-', '_')"
Exit-With 0
