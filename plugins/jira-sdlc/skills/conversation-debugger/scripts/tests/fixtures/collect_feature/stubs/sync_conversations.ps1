# Harness stub — PowerShell twin of sync_conversations.sh (same fixture files,
# same exit codes) so the real collect_feature.ps1 can run against it.
$f = Join-Path $env:CF_FIXTURE_WORK ("sync/" + $args[0] + ".txt")
if (-not (Test-Path -LiteralPath $f)) {
    [Console]::Error.WriteLine("sync_conversations stub: no fixture for $($args[0])")
    exit 1
}
Get-Content -LiteralPath $f
exit 0
