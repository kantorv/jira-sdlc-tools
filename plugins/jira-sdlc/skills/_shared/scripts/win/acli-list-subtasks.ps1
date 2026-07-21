# acli-list-subtasks.ps1 — Windows (PowerShell 5.1+) port of acli-list-subtasks.sh.
# Lists a Jira parent's sub-tasks. `acli jira workitem view <KEY> --json` omits
# `subtasks` by default, so this requests just `subtasks,issuetype` and prints
# each sub-task's key + summary. Mirrors the bash helper's behavior and output
# (same parent/env/json flags, same text + JSON formats, same exit codes), but
# parses acli's JSON with PowerShell's built-in ConvertFrom-Json — no jq needed.
#
# Requires `acli` authenticated (see ../jira-acli-reference.md §0).
# Reads <PROJECT-KEY> from jira-sdlc-tools.env (override with -EnvPath or
# $env:PROJECT_KEY); the project is printed as a label only, never sent to acli.
#
# Usage:
#   powershell -File acli-list-subtasks.ps1 -Parent <PARENT-KEY> [-EnvPath ./jira-sdlc-tools.env] [-Json]
#   (positional works too: powershell -File acli-list-subtasks.ps1 <PARENT-KEY> [-Json])
#
# Exit 0      — listed sub-tasks (or reported "none").
# Exit 1      — acli missing, -Parent missing, or acli's --json output had no JSON.
# Exit <code> — the `acli jira workitem view` call failed (its stderr is relayed).

param([string]$Parent, [string]$EnvPath = './jira-sdlc-tools.env', [switch]$Json)

if (-not (Get-Command acli -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('acli-list-subtasks: acli is not installed.')
    exit 1
}
if (-not $Parent) {
    [Console]::Error.WriteLine('acli-list-subtasks: missing required -Parent <PARENT-KEY>')
    [Console]::Error.WriteLine('usage: powershell -File acli-list-subtasks.ps1 -Parent <PARENT-KEY> [-EnvPath ./jira-sdlc-tools.env] [-Json]')
    exit 1
}

# --- resolve PROJECT-KEY (hyphen OR underscore form) ------------------------
# PROJECT-KEY has a hyphen, so `source`-style reads can't grab it — match it out.
# Same precedence as the python helper: explicit -EnvPath, then ./jira-sdlc-tools.env,
# then ../jira-sdlc-tools.env; first file carrying PROJECT-KEY wins. Falls back to
# $env:PROJECT_KEY. It is printed as a label only — never passed to acli.
function Get-ProjectKey {
    foreach ($p in @($EnvPath, 'jira-sdlc-tools.env', '../jira-sdlc-tools.env')) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        foreach ($line in Get-Content -LiteralPath $p) {
            if ($line -match '^\s*PROJECT[-_]KEY\s*=\s*(.+)$') { return $Matches[1].Trim() }
        }
    }
    return $env:PROJECT_KEY
}
$Project   = Get-ProjectKey
$ProjLabel = if ($Project) { "[$Project] " } else { '' }

# --- fetch the parent + its sub-tasks via acli -------------------------------
# Request only `subtasks,issuetype` (narrower than the canonical fetch lists in
# ../jira-acli-reference.md §3). acli may print leading non-JSON lines, so jump
# to the first '{' before ConvertFrom-Json — same resilience as the python
# helper's `raw.find('{')`. stderr is merged into stdout (matches check_assignee.ps1);
# on failure the merged text is relayed, same as the python `out.stderr or out.stdout`.
$out  = (& acli jira workitem view $Parent --json --fields 'subtasks,issuetype' 2>&1)
$code = $LASTEXITCODE
if ($code -ne 0) {
    [Console]::Error.WriteLine(($out | Out-String).Trim())
    exit $code
}
$raw   = $out | Out-String
$start = $raw.IndexOf('{')
if ($start -lt 0) {
    [Console]::Error.WriteLine('acli-list-subtasks: acli --json output had no JSON object')
    exit 1
}
try {
    $data = $raw.Substring($start) | ConvertFrom-Json
} catch {
    [Console]::Error.WriteLine("acli-list-subtasks: could not parse acli JSON — $($_.Exception.Message)")
    exit 1
}

# acli nests under `fields`; tolerate a flat object (matches python's
# `data.get('fields', data)`).
$fields     = if ($data.fields) { $data.fields } else { $data }
$subtasks   = if ($fields.subtasks) { @($fields.subtasks) } else { @() }
$parentType = if ($fields.issuetype -and $fields.issuetype.name) { $fields.issuetype.name } else { '?' }

if ($Json) {
    # Ordered keys (parent, parent_type, subtasks) to match json.dumps; each
    # sub-task row is a PSCustomObject so ConvertTo-Json keeps key/summary order.
    $rows = @($subtasks | ForEach-Object {
        [pscustomobject]@{
            key     = if ($_.key)     { $_.key }     else { $null }
            summary = if ($_.fields)  { $_.fields.summary } else { $null }
        }
    })
    [pscustomobject]@{ parent = $Parent; parent_type = $parentType; subtasks = $rows } |
        ConvertTo-Json -Depth 8
    exit 0
}

Write-Output ("{0}parent {1} ({2}) — {3} sub-task(s):" -f $ProjLabel, $Parent, $parentType, $subtasks.Count)
if ($subtasks.Count -eq 0) {
    Write-Output "  (none — not a parent, or no sub-tasks attached)"
    exit 0
}
foreach ($s in $subtasks) {
    $k    = if ($s.key)                    { $s.key }            else { '?' }
    $summ = if ($s.fields -and $s.fields.summary) { $s.fields.summary } else { '' }
    Write-Output ("  {0}  {1}" -f $k, $summ)
}
exit 0
