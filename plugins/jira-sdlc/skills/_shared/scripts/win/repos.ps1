# repos.ps1 — Windows (PowerShell 5.1+) twin of repos.sh: the set of repos an
# issue's work spans, behind one front door. Same arguments, same stdout, same
# stderr, same exit codes; repos.sh carries the full rationale. Design:
# https://kantorv.github.io/jira-sdlc-tools/docs/proposals/submodules-strategy
#
# Usage: pwsh -File repos.ps1 <verb>
#   strategy  key=value lines: strategy, root, members, pinned
#   list      tab-separated rows, header first:
#             repo role initialized slug base branch dirty ahead
#
# Exit 0 — ok. Exit 2 — usage error (stderr only), or JST_MEMBERS is invalid
# (stdout ends with an `error=<reason>` line).
#
# Writes with Write-Output, so a caller can capture it in-process with `&`
# (statuscheck.ps1 does) — unlike jira.ps1, which writes to [Console]::Out.

. (Join-Path $PSScriptRoot '_jst_root.ps1')

function Stop-Usage {
    param([string]$Message)
    [Console]::Error.WriteLine("repos: $Message")
    exit 2
}

$Verb = if ($args.Count -gt 0) { [string]$args[0] } else { '' }
if (-not $Verb) { Stop-Usage 'a verb is required — one of: strategy, list' }
if ($Verb -notin @('strategy', 'list')) { Stop-Usage "unknown verb '$Verb' — one of: strategy, list" }

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
    $url = (& git -C $dir remote get-url origin 2>$null)
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

& "s_$Verb"
exit 0
