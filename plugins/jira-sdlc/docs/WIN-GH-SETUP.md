````markdown
# Windows SSH Key Setup for GitHub (OpenSSH + Git)

This document describes how to configure SSH keys on Windows for GitHub access.

The setup is split into:

- **Administrator actions** — machine-level configuration (services)
- **Regular user actions** — user-specific SSH keys, Git configuration, and repository access

---

# Overview

Windows OpenSSH has two layers:

| Component | Scope | Required permissions |
|---|---|---|
| `ssh-agent` Windows service | System-wide service | Administrator |
| SSH private key | User profile | Regular user |
| `~/.ssh/config` | User profile | Regular user |
| Git SSH configuration | User profile | Regular user |
| GitHub key registration | GitHub account | Regular user |

The administrator only enables the SSH agent service.

The actual SSH identity belongs to the user.

---

# Part 1 — Administrator Setup

Run **PowerShell as Administrator**.

## 1. Check OpenSSH agent service

```powershell
Get-Service ssh-agent
````

Expected output:

```
Status   Name
------   ----
Stopped  ssh-agent
```

---

## 2. Configure ssh-agent to start automatically

```powershell
Set-Service ssh-agent -StartupType Automatic
```

Verify:

```powershell
Get-Service ssh-agent | Select-Object Status, StartType, Name
```

Expected:

```
Status    StartType    Name
------    ---------    ----
Stopped   Automatic    ssh-agent
```

---

## 3. Start ssh-agent

```powershell
Start-Service ssh-agent
```

Verify:

```powershell
Get-Service ssh-agent
```

Expected:

```
Status: Running
```

---

## 4. Close Administrator PowerShell

No more administrator actions are required.

The SSH key itself should **not** be installed by Administrator.

---

# Part 2 — Regular User Setup

Open normal **PowerShell**.

Example:

```
PS C:\Users\vboxuser>
```

---

# 1. Create SSH directory

```powershell
mkdir $HOME\.ssh
```

Expected:

```
C:\Users\vboxuser\.ssh
```

---

# 2. Place your private key

Example:

```
C:\Users\vboxuser\.ssh\winkey.pem
```

The private key must belong to the current user.

Check:

```powershell
dir $HOME\.ssh
```

Example:

```
winkey.pem
```

---

# 3. Fix private key permissions

SSH rejects keys with insecure permissions.

Run:

```powershell
icacls $HOME\.ssh\winkey.pem /inheritance:r
icacls $HOME\.ssh\winkey.pem /grant:r "$env:USERNAME:F"
```

Verify:

```powershell
icacls $HOME\.ssh\winkey.pem
```

Expected:

Only your user should have access.

---

# 4. Add key to ssh-agent

```powershell
ssh-add $HOME\.ssh\winkey.pem
```

Example:

```
Enter passphrase:
Identity added:
C:\Users\vboxuser\.ssh\winkey.pem
```

---

# 5. Verify loaded keys

```powershell
ssh-add -l
```

Example:

```
4096 SHA256:xxxxxxxx lalala@vivo7 (RSA)
```

---

# 6. Generate public key from private key (if needed)

If you only have a `.pem` private key:

```powershell
ssh-keygen -y -f $HOME\.ssh\winkey.pem
```

Output:

```
ssh-rsa AAAAB3.... lalala@vivo7
```

Save it:

```powershell
ssh-keygen -y -f $HOME\.ssh\winkey.pem > $HOME\.ssh\winkey.pub
```

---

# 7. Add public key to GitHub

Login to GitHub.

Navigate:

```
Settings
 → SSH and GPG keys
 → New SSH key
```

Paste the content of:

```
C:\Users\vboxuser\.ssh\winkey.pub
```

Save.

---

# 8. Configure SSH client

Create:

```
C:\Users\vboxuser\.ssh\config
```

Example:

```sshconfig
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/winkey.pem
    IdentitiesOnly yes
```

This forces GitHub to use this key.

---

# 9. Test SSH authentication

Run:

```powershell
ssh -T git@github.com
```

Expected:

```
Hi username! You've successfully authenticated,
but GitHub does not provide shell access.
```

---

# 10. Configure Git to use Windows OpenSSH

Check current configuration:

```powershell
git config --global --get core.sshCommand
```

If empty:

```powershell
git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"
```

Verify:

```powershell
git config --global --get core.sshCommand
```

Expected:

```
C:/Windows/System32/OpenSSH/ssh.exe
```

---

# 11. Test GitHub repository access

Example:

```powershell
git ls-remote git@github.com:OWNER/REPOSITORY.git
```

Expected:

```
<commit> HEAD
<commit> refs/heads/main
```

---

# 12. Clone repository

Example:

```powershell
cd $HOME
mkdir skill-dev
cd skill-dev

git clone git@github.com:kantorv/jira-sdlc-tools.git
```

---

# Troubleshooting

## Problem

```
git@github.com: Permission denied (publickey)
```

Check:

### Is the key loaded?

```powershell
ssh-add -l
```

If empty:

```powershell
ssh-add $HOME\.ssh\winkey.pem
```

---

### Does SSH authentication work?

```powershell
ssh -T git@github.com
```

If this works but Git clone fails, Git is using another SSH executable.

Check:

```powershell
git config --global --get core.sshCommand
```

Force Windows OpenSSH:

```powershell
git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"
```

---

### Debug SSH selection

Run:

```powershell
ssh -vT git@github.com
```

Look for:

```
Offering public key:
```

and:

```
Server accepts key
```

---

# Your observed issue

Initial state:

```
git clone
→ Permission denied (publickey)
```

Cause:

Git was not using the Windows OpenSSH agent/key.

After:

```powershell
git config --global core.sshCommand "C:/Windows/System32/OpenSSH/ssh.exe"
```

verification:

```powershell
git ls-remote git@github.com:kantorv/chess-app.git
```

worked.

This confirms:

* SSH key is valid ✅
* GitHub account has the public key ✅
* ssh-agent is working ✅
* Git is now using the correct SSH implementation ✅

---

# Final checklist

Administrator:

* [x] Enable `ssh-agent`
* [x] Set startup type Automatic
* [x] Start service

Regular user:

* [x] Put private key in `~/.ssh`
* [x] Fix permissions
* [x] Run `ssh-add`
* [x] Upload public key to GitHub
* [x] Create SSH config
* [x] Configure Git SSH command
* [x] Test `ssh -T git@github.com`
* [x] Clone repositories

```
```
