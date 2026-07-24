# jira.test.ps1 — Windows (PowerShell 5.1+) twin of jira.test.sh.
#
# Live end-to-end smoke test for jira.ps1. Creates a throwaway parent + sub-task,
# exercises EVERY jira.ps1 subcommand (including the negative cases), asserts the
# result, then deletes the issues. A finally block deletes anything created even
# if an assertion aborts midway.
#
# This is an INTEGRATION test: it hits a real Jira instance and creates/deletes
# real issues, so it is NOT a CI test — it needs live credentials in
# jira-sdlc-tools.local.env. It runs as the `assigner` role (which can create);
# override with $env:JIRA_TEST_ROLE.
#
# Usage:  pwsh -File jira.test.ps1
# Exit 0 — all checks passed.   Exit 1 — one or more checks failed.
#
# jira.ps1 calls `exit`, so each op runs in its OWN pwsh process (never `&` in-
# process, which would exit this harness too) — the same way Windows dispatches it.

$ErrorActionPreference = 'Continue'

$HERE    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$JIRA_PS = Join-Path $HERE 'jira.ps1'
$ROLE    = if ($env:JIRA_TEST_ROLE) { $env:JIRA_TEST_ROLE } else { 'assigner' }

# Run jira.ps1 in a child process; capture stdout in $o, exit code in $script:RC.
function J {
    $o = & pwsh -NoProfile -File $JIRA_PS --role $ROLE @args 2>$null
    $script:RC = $LASTEXITCODE
    return $o
}
function Json { param($x) try { (@($x) -join "`n") | ConvertFrom-Json } catch { $null } }
function NullStr { param($x) if ($null -eq $x) { 'null' } else { [string]$x } }

# --- resolve config the same way jira.ps1 does (local overrides team) ---------
$cfgDir = $null
try { $t = (& git rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -eq 0 -and $t) { $cfgDir = ([string]$t).Trim() } } catch { }
if (-not $cfgDir) { $cfgDir = (Get-Location).Path }
function Cfg {
    param([string]$Name)
    foreach ($f in @('jira-sdlc-tools.local.env', 'jira-sdlc-tools.env')) {
        $path = Join-Path $cfgDir $f
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $val = $null
        foreach ($line in Get-Content -LiteralPath $path) {
            if ($line -match "^\s*$Name\s*=(.*)$") { $val = $Matches[1].Trim() }
        }
        if ($val) { return $val }
    }
    return $null
}
$PROJECT_KEY  = Cfg 'PROJECT_KEY'
$IN_PROGRESS  = Cfg 'STATUS_IN_PROGRESS'; if (-not $IN_PROGRESS) { $IN_PROGRESS = 'In Progress' }
$ASSIGN_EMAIL = Cfg 'JIRA_EXECUTOR_EMAIL'; if (-not $ASSIGN_EMAIL) { $ASSIGN_EMAIL = Cfg 'JIRA_ACCOUNT_EMAIL' }
if (-not $PROJECT_KEY)  { [Console]::Error.WriteLine('test: PROJECT_KEY not set in jira-sdlc-tools.env'); exit 1 }
if (-not $ASSIGN_EMAIL) { [Console]::Error.WriteLine('test: no executor/account email to assign to'); exit 1 }

# --- tiny assertion framework ------------------------------------------------
$script:PASS = 0; $script:FAIL = 0
function Cpass { param($m) $script:PASS++; Write-Host ('  PASS  ' + $m) }
function Cfail { param($m) $script:FAIL++; Write-Host ('  FAIL  ' + $m) }
function Eq { param($m, $exp, $got) if ("$exp" -eq "$got") { Cpass $m } else { Cfail "$m (expected '$exp', got '$got')" } }
function Rc { param($m, $exp, $got) if ("$exp" -eq "$got") { Cpass $m } else { Cfail "$m (expected rc $exp, got rc $got)" } }
function Ne { param($m, $got) if ($got -and "$got" -ne 'null') { Cpass $m } else { Cfail "$m (got empty/null)" } }

# --- cleanup: delete created issues in REVERSE order (sub before parent) -----
$script:CREATED = @()
function Cleanup {
    if ($script:CREATED.Count -eq 0) { return }
    Write-Host ('--- cleanup: deleting ' + ($script:CREATED -join ' ') + ' ---')
    for ($i = $script:CREATED.Count - 1; $i -ge 0; $i--) {
        $k = $script:CREATED[$i]
        & pwsh -NoProfile -File $JIRA_PS --role $ROLE issue delete $k *> $null
        if ($LASTEXITCODE -eq 0) { Write-Host "  deleted $k" } else { Write-Host "  WARN could not delete $k — remove it manually" }
    }
}

$TMP = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ('jira-test-' + [guid]::NewGuid().ToString('N')))

Write-Host "== jira.ps1 live test (role=$ROLE, project=$PROJECT_KEY) =="

try {
    # 1. whoami --------------------------------------------------------------
    $out = J whoami; $r = $script:RC
    Rc 'whoami exits 0' 0 $r
    Ne 'whoami returns an accountId' (Json $out).accountId

    # 2/3. project exists (positive + negative) ------------------------------
    $out = J project exists $PROJECT_KEY; Rc "project exists $PROJECT_KEY -> 0" 0 $script:RC
    Eq 'project exists prints the key' $PROJECT_KEY ([string]$out).Trim()
    J project exists '__NO_SUCH_PROJ__' | Out-Null; Rc 'project exists (missing) -> 4' 4 $script:RC

    # 4. create parent (plain-text description + assignee) -------------------
    $descFile = Join-Path $TMP 'desc.txt'
    [IO.File]::WriteAllText($descFile, "Live test parent for jira.ps1.`n`nSecond paragraph — safe to delete.`n")
    $PARENT = ([string](J issue create --project $PROJECT_KEY --type Task `
        --summary 'jira.ps1 live test (parent)' `
        --assignee $ASSIGN_EMAIL --desc-file $descFile)).Trim()
    $r = $script:RC
    Rc 'create parent -> 0' 0 $r
    if ($PARENT) { $script:CREATED += $PARENT }
    Eq "created key is in project $PROJECT_KEY" $PROJECT_KEY ($PARENT -replace '-.*$', '')

    # 5. create sub-task (--parent) ------------------------------------------
    $SUB = ([string](J issue create --project $PROJECT_KEY --type Subtask --parent $PARENT `
        --summary 'jira.ps1 live test (sub-task)')).Trim()
    $r = $script:RC
    Rc 'create sub-task -> 0' 0 $r
    if ($SUB) { $script:CREATED += $SUB }

    # 6. view: sub-task shows under parent's subtasks -------------------------
    $v = Json (J issue view $PARENT --fields subtasks)
    $gotKeys = @($v.fields.subtasks | ForEach-Object { $_.key })
    $got = '[' + (($gotKeys | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
    Eq 'parent lists the sub-task' ('["' + $SUB + '"]') $got

    # 7. view: description ADF landed ----------------------------------------
    $d = Json (J issue view $PARENT --fields description)
    Eq 'description first paragraph stored' 'Live test parent for jira.ps1.' $d.fields.description.content[0].content[0].text

    # 8/9. comments: plain-text + raw ADF ------------------------------------
    $cmtFile = Join-Path $TMP 'cmt.txt'
    [IO.File]::WriteAllText($cmtFile, "PR target branch: development.`nSecond line of the note.`n")
    J issue comment add $PARENT --body-file $cmtFile | Out-Null; Rc 'comment add (--body-file) -> 0' 0 $script:RC
    $adfFile = Join-Path $TMP 'rich.adf.json'
    [IO.File]::WriteAllText($adfFile, '{"type":"doc","version":1,"content":[{"type":"heading","attrs":{"level":3},"content":[{"type":"text","text":"Rich heading"}]}]}')
    J issue comment add $PARENT --adf-file $adfFile | Out-Null; Rc 'comment add (--adf-file) -> 0' 0 $script:RC

    # 10. comment list: both are present -------------------------------------
    $cl = Json (J issue comment list $PARENT)
    Eq 'comment count is 2' 2 $cl.total
    $marker = 'no'
    foreach ($c in $cl.comments) {
        foreach ($blk in $c.body.content) {
            foreach ($n in $blk.content) {
                if ($n.PSObject.Properties['text'] -and $n.text -and $n.text.StartsWith('PR target branch:')) { $marker = 'yes' }
            }
        }
    }
    Eq 'marker comment present' 'yes' $marker

    # 11/12/13. assign by email -> @me -> remove -----------------------------
    J issue assign $PARENT --to $ASSIGN_EMAIL | Out-Null; Rc 'assign by email -> 0' 0 $script:RC
    Ne 'assignee is set' (Json (J issue view $PARENT --fields assignee)).fields.assignee.accountId
    J issue assign $PARENT --to '@me' | Out-Null; Rc 'assign @me -> 0' 0 $script:RC
    J issue assign $PARENT --remove | Out-Null; Rc 'assign --remove -> 0' 0 $script:RC
    Eq 'assignee cleared' 'null' (NullStr (Json (J issue view $PARENT --fields assignee)).fields.assignee)

    # 14. transition by status name ------------------------------------------
    J issue transition $PARENT --to $IN_PROGRESS | Out-Null; Rc "transition -> $IN_PROGRESS -> 0" 0 $script:RC
    Eq "status is now $IN_PROGRESS" $IN_PROGRESS (Json (J issue view $PARENT --fields status)).fields.status.name

    # 15. transition to a bogus status -> exit 8 -----------------------------
    J issue transition $PARENT --to '__nope__' | Out-Null; Rc 'transition (bad status) -> 8' 8 $script:RC

    # 16. raw escape hatch ----------------------------------------------------
    Eq 'raw GET /myself returns identity' (Json (J whoami)).accountId (Json (J raw GET /myself)).accountId

    # 17/18/19. delete sub, delete parent, confirm gone ----------------------
    J issue delete $SUB | Out-Null; $r = $script:RC; Rc 'delete sub-task -> 0' 0 $r
    if ($r -eq 0) { $script:CREATED = @($PARENT) }          # sub gone; leave only parent
    J issue delete $PARENT | Out-Null; $r = $script:RC; Rc 'delete parent -> 0' 0 $r
    if ($r -eq 0) { $script:CREATED = @() }                 # both gone; cleanup has nothing to do
    J issue view $PARENT | Out-Null; Rc 'view deleted issue -> 4' 4 $script:RC
}
finally {
    Cleanup
    Remove-Item -LiteralPath $TMP -Recurse -Force -ErrorAction SilentlyContinue
}

# --- summary -----------------------------------------------------------------
Write-Host "== $script:PASS passed, $script:FAIL failed =="
if ($script:FAIL -eq 0) { exit 0 } else { exit 1 }
