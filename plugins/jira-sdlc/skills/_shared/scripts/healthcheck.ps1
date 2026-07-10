# Check if we're inside a Git repository
$null = git rev-parse --is-inside-work-tree 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ Not inside a Git repository."
    exit 1
}

$repoRoot = (git rev-parse --show-toplevel).Trim()
Write-Host "✅ Git repository: $repoRoot"

$failed = $false

# Check if jira-sdlc-tools.env and jira-sdlc-tools.local.env exist
foreach ($file in @("jira-sdlc-tools.env", "jira-sdlc-tools.local.env")) {
    $path = Join-Path $repoRoot $file

    if (Test-Path $path -PathType Leaf) {
        Write-Host "✅ Found $file"
    }
    else {
        Write-Host "❌ Missing $file"
        $failed = $true
    }
}

# Check if jira-sdlc-tools.local.env is gitignored
$settingsLocal = Join-Path $repoRoot "jira-sdlc-tools.local.env"
git check-ignore $settingsLocal *> $null

if ($LASTEXITCODE -eq 0) {
    Write-Host "✅ jira-sdlc-tools.local.env is gitignored"
}
else {
    Write-Host "❌ jira-sdlc-tools.local.env is NOT gitignored"
    $failed = $true
}

if ($failed) {
    exit 1
}

exit 0