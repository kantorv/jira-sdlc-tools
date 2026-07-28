# Harness stub — PowerShell twin of the jira.sh stub (same fixture file, same
# exit code) so the real collect_feature.ps1 can run against it. Replays the one
# Jira call collect_feature makes (the sub-task lookup) from
# $CF_FIXTURE_WORK/jira.json.
Get-Content -LiteralPath (Join-Path $env:CF_FIXTURE_WORK 'jira.json')
exit 0
