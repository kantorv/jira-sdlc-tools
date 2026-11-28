# _jst_config.ps1 — Windows (PowerShell 5.1+) twin of _jst_config.sh: the one
# reader of a project's .jst/ config and of the credentials its scripts run
# with. Dot-sourced, never run, after _jst_root.ps1:
#   . (Join-Path $PSScriptRoot '_jst_root.ps1')
#   . (Join-Path $PSScriptRoot '_jst_config.ps1')
# Same rules, results and messages as the bash original, which carries the full
# rationale (skills/_shared/project-config.md § Credentials); keep the two in
# step. In short: plain keys local over team; the credential group (the three
# Jira role pairs and GITHUB_PAT_TOKEN) from ONE source — the project's own
# .jst/ when it sets any key of it (then all seven), else the profile named by
# JST_CREDENTIALS, else the machine default, else an error. A profile lives in
# %APPDATA%\jira-sdlc\profiles\<name>.env on Windows ($XDG_CONFIG_HOME or
# ~/.config elsewhere) and is used only when its PROFILE_GITHUB_OWNERS covers
# every GitHub owner of the project's remotes. The group/others permission
# check applies off Windows only, where file modes exist. Nothing here prints a
# value.

$script:JstLocalEnvName = 'jira-sdlc-tools.local.env'
$script:JstTeamEnvName = 'jira-sdlc-tools.env'
$script:JstCredKeys = @('JIRA_ASSIGNER_EMAIL', 'JIRA_ASSIGNER_TOKEN', 'JIRA_EXECUTOR_EMAIL', 'JIRA_EXECUTOR_TOKEN',
    'JIRA_REVIEWER_EMAIL', 'JIRA_REVIEWER_TOKEN', 'GITHUB_PAT_TOKEN')
# Dot-sourced twice (gh.ps1 sources it too) must not drop the caller's state.
if (-not (Get-Variable -Name JstCfgDir -Scope Script -ErrorAction SilentlyContinue)) {
    $script:JstCfgRoot = $null
    $script:JstCfgDir = $null
    $script:JstCredDone = $false
    $script:JstCred = @{}
    $script:JstCredVals = @{}
}

function Test-JstOnWindows {
    if ($PSVersionTable.PSVersion.Major -lt 6) { return $true }
    return [bool]$IsWindows
}

# Initialize-JstConfig [<root>] — read the project at <root> (default: Get-JstRoot,
# else the current location). Drops the cached credential resolution.
function Initialize-JstConfig {
    param([string]$Root)
    if (-not $Root) { $Root = Get-JstRoot }
    if (-not $Root) { $Root = (Get-Location).Path }
    $script:JstCfgRoot = $Root
    $script:JstCfgDir = "$Root/.jst"
    $script:JstCredDone = $false
    $script:JstCred = @{}
    $script:JstCredVals = @{}
}

# Get-JstFileVal <file> <NAME-PATTERN> — the value of the last matching line, or $null.
function Get-JstFileVal {
    param([string]$File, [string]$Pattern)
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    $val = $null
    foreach ($line in Get-Content -LiteralPath $File) {
        if ($line -match "^\s*($Pattern)\s*=(.*)$") { $val = $Matches[$Matches.Count - 1].Trim() }
    }
    if ($val) { return $val }
    return $null
}

function Get-JstCfgFile {
    param([string]$Pattern)
    foreach ($f in @($script:JstLocalEnvName, $script:JstTeamEnvName)) {
        if (Get-JstFileVal "$($script:JstCfgDir)/$f" $Pattern) { return $f }
    }
    return $null
}

# Get-JstCfgRaw <NAME-PATTERN> — the project's own value, local over team.
function Get-JstCfgRaw {
    param([string]$Pattern)
    if (-not $script:JstCfgDir) { Initialize-JstConfig }
    foreach ($f in @($script:JstLocalEnvName, $script:JstTeamEnvName)) {
        $v = Get-JstFileVal "$($script:JstCfgDir)/$f" $Pattern
        if ($v) { return $v }
    }
    return $null
}

function Test-JstCredKey { param([string]$Name) return ($script:JstCredKeys -contains $Name) }

# Get-JstCfg <NAME-PATTERN> — a plain value; a credential key from the group's source.
function Get-JstCfg {
    param([string]$Pattern)
    if (-not $script:JstCfgDir) { Initialize-JstConfig }
    if (Test-JstCredKey $Pattern) { return (Get-JstCred $Pattern) }
    return (Get-JstCfgRaw $Pattern)
}

function Get-JstConfigHome {
    if ($env:XDG_CONFIG_HOME) { return "$($env:XDG_CONFIG_HOME)/jira-sdlc" }
    if ((Test-JstOnWindows) -and $env:APPDATA) { return (Join-Path $env:APPDATA 'jira-sdlc') }
    return "$HOME/.config/jira-sdlc"
}
function Get-JstProfilesDir { return "$(Get-JstConfigHome)/profiles" }
function Get-JstProfilePath { param([string]$Name) return "$(Get-JstProfilesDir)/$Name.env" }

function Get-JstTilde {
    param([string]$Path)
    if ($HOME -and $Path.StartsWith("$HOME/")) { return '~' + $Path.Substring($HOME.Length) }
    return $Path
}

function Get-JstDefaultProfile {
    $f = "$(Get-JstConfigHome)/default"
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
    foreach ($line in Get-Content -LiteralPath $f) {
        $t = $line.Trim()
        if ($t -and -not $t.StartsWith('#')) { return $t }
    }
    return $null
}

function Test-JstValidProfileName { param([string]$Name) return ($Name -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') }

# Get-JstFileMode <file> — permission bits in octal ('644'), or $null (Windows).
function Get-JstFileMode {
    param([string]$File)
    if (Test-JstOnWindows) { return $null }
    $m = (& stat -c '%a' $File 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $m) { $m = (& stat -f '%Lp' $File 2>$null) }
    if ($m) { return ([string]$m).Trim() }
    return $null
}

function Test-JstLooseMode {
    param([string]$File)
    $m = Get-JstFileMode $File
    if (-not $m) { return $false }
    return (([Convert]::ToInt32($m, 8) -band 63) -ne 0)
}

function Get-JstOwner {
    param([string]$Url)
    if (-not $Url -or $Url -notmatch 'github\.com') { return $null }
    $s = $Url.Substring($Url.IndexOf('github.com') + 'github.com'.Length)
    $s = $s -replace '^:', '' -replace '^/', '' -replace '/$', '' -replace '\.git$', ''
    if ($s -notmatch '^[^/]+/[^/]+$') { return $null }
    return ($s.Split('/')[0]).ToLower()
}

function Resolve-JstUrl {
    param([string]$Base, [string]$Rel)
    if ($Rel -notmatch '^\.\.?/') { return $Rel }
    $Base = $Base.TrimEnd('/')
    while ($true) {
        if ($Rel.StartsWith('./')) { $Rel = $Rel.Substring(2) }
        elseif ($Rel.StartsWith('../')) {
            $Rel = $Rel.Substring(3)
            if ($Base.Contains('/')) { $Base = $Base.Substring(0, $Base.LastIndexOf('/')) }
            elseif ($Base.Contains(':')) { $Base = $Base.Substring(0, $Base.IndexOf(':')) + ':' }
        } else { break }
    }
    if ($Base.EndsWith(':')) { return "$Base$Rel" }
    return "$Base/$Rel"
}

function Get-JstGitConfig {
    param([string[]]$GitArgs)
    $v = (& git @GitArgs 2>$null)
    if ($LASTEXITCODE -eq 0 -and $v) { return ([string]($v | Select-Object -First 1)).Trim() }
    return $null
}

# Get-JstProjectOwners — the GitHub owners of the root's and each member's
# origin, lowercased, sorted, space-separated ('' when none).
function Get-JstProjectOwners {
    if (-not $script:JstCfgDir) { Initialize-JstConfig }
    $root = $script:JstCfgRoot
    $owners = New-Object System.Collections.Generic.List[string]
    $rootUrl = Get-JstGitConfig @('-C', $root, 'config', '--get', 'remote.origin.url')
    $o = Get-JstOwner $rootUrl
    if ($o) { $owners.Add($o) }
    $members = Get-JstCfgRaw 'JST_MEMBERS'
    if ($members) {
        foreach ($p in ($members -split '\s+' | Where-Object { $_ })) {
            $url = $null
            if (Test-Path -LiteralPath "$root/$p/.git") {
                $url = Get-JstGitConfig @('-C', "$root/$p", 'config', '--get', 'remote.origin.url')
            }
            if (-not $url -and (Test-Path -LiteralPath "$root/.gitmodules")) {
                $lines = (& git config -f "$root/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>$null)
                $name = $null
                foreach ($l in @($lines)) {
                    if ($l -match '^submodule\.(.*)\.path (.*)$' -and $Matches[2] -eq $p) { $name = $Matches[1]; break }
                }
                if ($name) {
                    $url = Get-JstGitConfig @('config', '-f', "$root/.gitmodules", '--get', "submodule.$name.url")
                    if ($url) { $url = Resolve-JstUrl $rootUrl $url }
                }
            }
            $o = Get-JstOwner $url
            if ($o -and -not $owners.Contains($o)) { $owners.Add($o) }
        }
    }
    return ((@($owners | Sort-Object -Unique)) -join ' ')
}

function Set-JstCredFail {
    param([string]$Err, [string]$Fix)
    $script:JstCred.Source = ''
    $script:JstCred.Err = $Err
    $script:JstCred.Fix = $Fix
    $script:JstCredVals = @{}
    return $false
}

# Get-JstCredKind — project | profile | none, without reading a profile.
function Get-JstCredKind {
    if (-not $script:JstCfgDir) { Initialize-JstConfig }
    foreach ($k in $script:JstCredKeys) { if (Get-JstCfgRaw $k) { return 'project' } }
    if ((Get-JstCfgRaw 'JST_CREDENTIALS') -or (Get-JstDefaultProfile)) { return 'profile' }
    return 'none'
}

# Resolve-JstCred — decide the group's source once per project; $true when
# usable. Fills $script:JstCred (Source, Err, Fix, Where, Name, File, Via,
# Owners, ProfileOwners) and keeps the values private in $script:JstCredVals.
function Resolve-JstCred {
    if (-not $script:JstCfgDir) { Initialize-JstConfig }
    if ($script:JstCredDone) { return [bool]$script:JstCred.Source }
    $script:JstCredDone = $true
    $script:JstCred = @{ Source = ''; Err = ''; Fix = ''; Where = ''; Name = ''; File = ''; Via = ''; Owners = ''; ProfileOwners = '' }
    $script:JstCredVals = @{}
    $le = $script:JstLocalEnvName; $te = $script:JstTeamEnvName
    $cfgHome = Get-JstTilde (Get-JstConfigHome)

    $set = @(); $missing = @(); $vals = @{}
    foreach ($k in $script:JstCredKeys) {
        $v = Get-JstCfgRaw $k
        if ($v) { $set += $k; $vals[$k] = $v } else { $missing += $k }
    }
    if ($set.Count -gt 0) {
        $script:JstCred.File = "$($script:JstCfgDir)/$le"
        $script:JstCred.Where = ".jst/$le"
        if ($missing.Count -gt 0) {
            return (Set-JstCredFail "the project's .jst/ sets part of the credential group ($($set -join ' ')) — missing: $($missing -join ' ') (a partial set is never filled in from a profile)" `
                "set the missing keys in .jst/$le, or remove every key of the group from .jst/ and use a profile (JST_CREDENTIALS) — see skills/_shared/project-config.md § Credentials")
        }
        $script:JstCredVals = $vals
        $script:JstCred.Source = 'project'
        return $true
    }

    $name = Get-JstCfgRaw 'JST_CREDENTIALS'
    if ($name) { $via = "JST_CREDENTIALS in .jst/$(Get-JstCfgFile 'JST_CREDENTIALS')" }
    else {
        $name = Get-JstDefaultProfile
        if ($name) { $via = "the machine default ($cfgHome/default)" }
        else {
            return (Set-JstCredFail "no credentials: the project's .jst/ sets none of the credential group, names no profile (JST_CREDENTIALS), and this machine has no default profile ($cfgHome/default)" `
                "name a profile with JST_CREDENTIALS = <name> in .jst/$te (a file in $cfgHome/profiles), or set the seven keys in .jst/$le — see skills/_shared/project-config.md § Credentials")
        }
    }
    $script:JstCred.Name = $name; $script:JstCred.Via = $via
    if (-not (Test-JstValidProfileName $name)) {
        return (Set-JstCredFail "profile name '$name' ($via) is not a name: letters, digits, '.', '_' and '-' only" "fix the name ($via)")
    }
    $file = Get-JstProfilePath $name; $tf = Get-JstTilde $file
    $script:JstCred.File = $file
    $script:JstCred.Where = "profile $name ($tf)"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        return (Set-JstCredFail "profile '$name' ($via) not found: $tf" `
            "create the profile (see skills/_shared/templates/credential-profile.env.example; chmod 600), or name an existing one in $cfgHome/profiles")
    }
    if (Test-JstLooseMode $file) {
        return (Set-JstCredFail "profile $tf is open to group or others (mode $(Get-JstFileMode $file)) — refused" "chmod 600 $tf")
    }
    $missing = @(); $vals = @{}
    foreach ($k in $script:JstCredKeys) {
        $v = Get-JstFileVal $file $k
        if ($v) { $vals[$k] = $v } else { $missing += $k }
    }
    $po = Get-JstFileVal $file 'PROFILE_GITHUB_OWNERS'
    if ($po) { $po = ((($po.ToLower() -replace ',', ' ') -split '\s+' | Where-Object { $_ }) -join ' ') } else { $po = '' }
    $script:JstCred.ProfileOwners = $po
    if ($missing.Count -gt 0) {
        return (Set-JstCredFail "profile $tf lacks: $($missing -join ' ')" "add the missing keys to $tf — a profile holds all seven")
    }
    $owners = Get-JstProjectOwners
    $script:JstCred.Owners = $owners
    if (-not $po) {
        $shown = if ($owners) { $owners } else { 'none' }
        return (Set-JstCredFail "profile $tf sets no PROFILE_GITHUB_OWNERS, so it can't be matched to this project (owners: $shown)" `
            "set PROFILE_GITHUB_OWNERS (the GitHub owners its PAT is for, space-separated) in $tf")
    }
    if (-not $owners) {
        return (Set-JstCredFail "the project has no github.com remote, so profile '$name' (owners: $po) can't be matched to it" `
            "attach the project's GitHub 'origin' remote, or set the seven keys in .jst/$le")
    }
    $lacking = @($owners -split ' ' | Where-Object { $_ -and (@($po -split ' ') -notcontains $_) })
    if ($lacking.Count -gt 0) {
        return (Set-JstCredFail "profile '$name' ($via) is for GitHub owner(s) $po, but this project's remotes are owned by $owners (not covered: $($lacking -join ' '))" `
            "name a profile whose PROFILE_GITHUB_OWNERS covers $($lacking -join ' '), add the owner to $tf if its PAT really is for it, or set the seven keys in .jst/$le")
    }
    $script:JstCredVals = $vals
    $script:JstCred.Source = 'profile'
    return $true
}

# Get-JstCred <KEY> — one credential value, or $null when the resolution failed.
function Get-JstCred {
    param([string]$Key)
    if (-not (Test-JstCredKey $Key)) { return $null }
    if (-not (Resolve-JstCred)) { return $null }
    if ($script:JstCredVals.ContainsKey($Key)) { return $script:JstCredVals[$Key] }
    return $null
}

# Get-JstCredDescribe — statuscheck's credentials row detail, never a value.
function Get-JstCredDescribe {
    if (-not (Resolve-JstCred)) { return $null }
    if ($script:JstCred.Source -eq 'project') { return "project .jst/ (.jst/$($script:JstLocalEnvName))" }
    return "profile $($script:JstCred.Name) ($(Get-JstTilde $script:JstCred.File)) · via $($script:JstCred.Via) · owners match ($($script:JstCred.Owners))"
}
