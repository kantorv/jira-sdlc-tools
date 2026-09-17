---
slug: /step-by-step-installation/github-post-install
sidebar_position: 2
sidebar_label: Post install
---

# Post install

## *[OPTIONAL]* Add the git branch to your command prompt

These skills move you between a lot of directories and branches: the main
checkout sits on the base branch, and every issue gets its own worktree on its
own `feature/` or `hotfix/` branch. Seeing the active branch in the prompt at
all times is what keeps you from committing in the wrong one.

Pick your shell below, then open a new terminal to check it.

### Bash (Linux)

Add this to `~/.bashrc`:

```bash
git_branch() {
  git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/(\1)/'
}

export PS1="\[\e]0;\u@\h: \w\a\]${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\] \[\033[00;32m\]\$(git_branch)\[\033[00m\]\$ "
```

Outside a repository `git_branch` prints nothing, so the prompt stays as it was.

### PowerShell (Windows)

Add this to your PowerShell profile:

```powershell
function prompt {
    $currentPath = (Get-Location).Path

    # Check for Git branch if Git is available
    $gitBranch = $null
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $gitBranch = git branch --show-current 2>$null
    }

    # Render prompt
    Write-Host "PS " -NoNewline -ForegroundColor DarkGray
    Write-Host "$currentPath" -NoNewline -ForegroundColor Cyan

    if ($gitBranch) {
        Write-Host " [$gitBranch]" -NoNewline -ForegroundColor Green
    }

    Write-Host "> " -NoNewline -ForegroundColor White

    return " "
}
```

The profile path differs between PowerShell 5.1 and 7, so let the shell tell you
which file it reads, and create it if it isn't there:

```powershell
$PROFILE                                  # e.g. …\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1
New-Item -ItemType File -Path $PROFILE -Force   # only if it does not exist yet
notepad $PROFILE
```

If the new prompt doesn't appear in a fresh terminal, the execution policy is
blocking profile scripts. `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`
allows them.

### zsh (macOS)

macOS defaults to zsh. Add this to `~/.zshrc` — `PROMPT_SUBST` is what makes the
prompt re-evaluate `git_branch` on every command:

```bash
git_branch() {
  git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/(\1)/'
}

setopt PROMPT_SUBST
PROMPT='%F{green}%n@%m%f:%F{blue}%~%f %F{green}$(git_branch)%f$ '
```

⚠️ Unlike the bash and PowerShell versions above, this one is not tested — the
same caveat the [Software](../software.md) table carries for
macOS generally. Using bash on macOS instead? The bash snippet works as is, in
`~/.bash_profile`.

### Another shell

Fish, Nushell, Starship prompts and the rest all support this, each in their own
way. Ask your coding assistant for the equivalent for your shell — the whole
requirement is "show `git branch --show-current` in the prompt, and show nothing
outside a repository".
