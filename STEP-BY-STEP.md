# Step by step

## How it works

Detailed setup lives in [INSTALLATION.md](INSTALLATION.md) — this page is the
short, ordered version.

## Section 1. Preparing environment

1. **Install the required tools** — `acli`, `git`, `gh`. On Windows, make sure
   `acli` is on your `PATH`.
2. **Have a git repository and a Jira account with a board created.**
   [GitHub for Jira](INSTALLING-GITHUB-FOR-JIRA.md) is a great, recommended
   integration — but it is **not** required.
3. **Generate your tokens:** a **granular** `GITHUB_PAT` and a **classic**
   `JIRA_TOKEN` (see the note in [SECURITY.md](SECURITY.md) on why the Jira
   token must be classic).
4. **Define your main repository and worktrees dir in the settings**, e.g.:
   ```
   WORKTREES_DIR=/home/lalala/src/skills-dev/JST-worktrees
   ```

### Verify your tokens

**Jira** — log `acli` in with your token:
```bash
echo "$JIRA_TOKEN" | acli jira auth login \
  --site your-jira-site.atlassian.net \
  --email yourmail@gmail.com \
  --token
```

**GitHub** — log `gh` in with your PAT:
```bash
echo "$GITHUB_PAT_TOKEN" | gh auth login --with-token && gh auth status
```

### Your settings should look like this

```
WORKTREES_DIR=/path/to/worktrees/PROJ-worktrees

JIRA_ACCOUNT_URL=your-jira-site.atlassian.net
JIRA_ACCOUNT_EMAIL=yourmail@gmail.com
JIRA_TOKEN=XXXXXXXXXXXXXXXXXXXXXXX

#  acli jira auth login --site coolapp-dev.atlassian.net --email kantorvv@gmail.com < .jira/token.txt

GITHUB_PAT_TOKEN="XXXXXXXXXXXXX"
```

### Run the healthcheck

From your **main repository**, run the statuscheck script — it confirms both
logins, your settings, and the platform in one pass:

**Linux / macOS** (bash):
```bash
curl -fsSL "https://raw.githubusercontent.com/kantorv/jira-sdlc-tools/main/plugins/jira-sdlc/skills/_shared/scripts/posix/statuscheck.sh" -o statuscheck.sh
bash statuscheck.sh
```

**Windows** (PowerShell 7+ `pwsh`, or 5.1 `powershell`):
```powershell
iwr -UseBasicParsing "https://raw.githubusercontent.com/kantorv/jira-sdlc-tools/main/plugins/jira-sdlc/skills/_shared/scripts/win/statuscheck.ps1" -OutFile statuscheck.ps1
pwsh -File statuscheck.ps1        # PowerShell 7+
powershell -File statuscheck.ps1  # PowerShell 5.1
```

