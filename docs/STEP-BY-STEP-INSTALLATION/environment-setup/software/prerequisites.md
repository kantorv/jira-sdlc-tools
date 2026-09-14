---
slug: /step-by-step-installation/prerequisites
sidebar_position: 1
sidebar_label: Prerequisites
---

# Prerequisites

## Tools

| Tool | Title | Uses | Install URL | Local docs |
| -- | -- | -- | -- | -- |
| `git` | Version control | commit/push | [git-scm.com/downloads](https://git-scm.com/downloads) | — |
| `gh` | GitHub CLI | pr create/update | [cli.github.com](https://cli.github.com/) | [GH-PAT-SESSION-LOGIN.md](../../../github/GH-PAT-SESSION-LOGIN.md) |
| `jq` | JSON processor | parse Jira REST responses (`jira.sh`) | [jqlang.github.io/jq](https://jqlang.github.io/jq/download/) | — |
| `python3` *(recommended)* | Scripting | scripting, JSON parsing, etc. | [python.org/downloads](https://www.python.org/downloads/) | — |

**Platform specific**

| Platform | Needs | Tested on | Why |
| -- | -- | -- | -- |
| **Windows** | [`pwsh`](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) (PowerShell 7+) **or** `powershell` (5.1, ships with Windows) | Windows 11 | execute `.ps1` scripts |
| **Linux** | `bash` | Ubuntu 22.04 | execute `.sh` scripts |
| **macOS** | `bash`/`sh` | ⚠️ not tested | execute `.sh` scripts |

On Linux and macOS, the Jira client also requires `curl` and `jq` on your
`PATH`. Python 3 is recommended on all platforms because the workflows handle
substantial JSON data from the Jira and GitHub APIs, although it is not mandatory.
