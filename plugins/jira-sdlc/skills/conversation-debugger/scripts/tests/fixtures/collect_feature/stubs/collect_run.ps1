# Harness stub — PowerShell twin of collect_run.sh (same fixture files, same
# exit codes) so the real collect_feature.ps1 can run against it.
$b = [System.IO.Path]::GetFileNameWithoutExtension([string]$args[1])
$f = Join-Path $env:CF_FIXTURE_WORK ("collect_run/" + $b + "." + $args[0] + ".kv")
if (-not (Test-Path -LiteralPath $f)) {
    [Console]::Error.WriteLine("collect_run stub: no fixture for $($args[0]) $b")
    exit 1
}
Get-Content -LiteralPath $f
exit 0
