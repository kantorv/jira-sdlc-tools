# get_assignee_email.ps1 — Windows (PowerShell 5.1+) port of get_assignee_email.sh.
# Mirrors the bash contract exactly: one line on stdout, same exit codes.
#
# Prints the email every issue should be assigned to: JIRA_EXECUTOR_EMAIL —
# required, with no fallback. No token is resolved or printed here.
#
# Exit 0 — the email is on stdout.
# Exit 1 — it isn't set; the reason is on stderr. The caller stops.
#
# The env-file parser mirrors statuscheck.sh's cfg(): same `NAME = value`
# match, same local-overrides-team precedence, last match in a file wins.

. (Join-Path $PSScriptRoot '_jst_root.ps1')   # Get-JstRoot: the project root, even from inside a member submodule

. (Join-Path $PSScriptRoot '_jst_config.ps1')   # the one reader: JIRA_EXECUTOR_EMAIL is a credential key
Initialize-JstConfig


if (-not (Resolve-JstCred)) {
    [Console]::Error.WriteLine("get_assignee_email: $($script:JstCred.Err) — $($script:JstCred.Fix), then rerun.")
    exit 1
}
$Email = Get-JstCred 'JIRA_EXECUTOR_EMAIL'

if (-not $Email) {
    [Console]::Error.WriteLine("get_assignee_email: no assignee email — set JIRA_EXECUTOR_EMAIL in $($script:JstCred.Where), then rerun.")
    exit 1
}

Write-Output $Email
