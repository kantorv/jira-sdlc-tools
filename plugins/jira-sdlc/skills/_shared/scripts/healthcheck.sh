#!/usr/bin/env bash

set -euo pipefail

# 1. Check if we're inside a Git repository
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "❌ Not inside a Git repository."
    exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
echo "✅ Git repository: $repo_root"

# 2. Check if jira-sdlc-tools.env and jira-sdlc-tools.local.env exist in repository root
missing=0

for file in jira-sdlc-tools.env jira-sdlc-tools.local.env; do
    if [[ -f "$repo_root/$file" ]]; then
        echo "✅ Found $file"
    else
        echo "❌ Missing $file"
        missing=1
    fi
done

# 3. Check if jira-sdlc-tools.local.env is gitignored
if git check-ignore -q "$repo_root/jira-sdlc-tools.local.env"; then
    echo "✅ jira-sdlc-tools.local.env is gitignored"
else
    echo "❌ jira-sdlc-tools.local.env is NOT gitignored"
    missing=1
fi

exit "$missing"