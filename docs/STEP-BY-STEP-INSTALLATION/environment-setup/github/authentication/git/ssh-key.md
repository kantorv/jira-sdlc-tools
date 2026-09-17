---
slug: /step-by-step-installation/ssh-key
sidebar_position: 2
sidebar_label: SSH key
---

# SSH key

If you clone over SSH (`git@github.com:<OWNER>/<REPO>.git`) instead of
HTTPS, `git` authenticates with a key pair rather than a credentials
manager:

```bash
ssh-keygen -t ed25519 -C "you@example.com"   # accept the default path
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub                    # paste this into GitHub
```

Add the printed public key at **GitHub → Settings → SSH and GPG keys → New
SSH key**, then confirm with:

```bash
ssh -T git@github.com
```

Pick one of credentials-manager or SSH key, not both — whichever matches
the clone URL you use.
