# Windows scripts — the `win/*.ps1` ports

> Audience: anyone maintaining the Windows dispatch path. This is an
> inventory + the load-bearing compatibility notes; the **edit-one-edit-both
> parity rule and the diff loop live in the repo-root `AGENTS.md`** ("Touched
> a `_shared/scripts/posix/*.sh`? Its `win/*.ps1` twin must stay in sync"). Re-verify
> parity there after changing any twin.

The five skill-invoked scripts plus one operator helper are shipped **twice**:

- **POSIX path:** `skills/_shared/scripts/posix/<name>.sh` (bash originals)
- **Windows path:** `skills/_shared/scripts/win/<name>.ps1` (PowerShell ports)

The three `SKILL.md` files contain one dispatch rule each — *"run every
`bash …/scripts/X.sh` shown in this skill as `pwsh` or `powershell`
(`…/scripts/win/X.ps1`) with the same arguments"* — and each skill picks
that branch itself, from its own runtime, before the first script runs.
`statuscheck`'s `platform` row then *confirms* the OS (and, on Windows,
that the runtime + ports are present) — it can't be the source the
dispatch is keyed off, since statuscheck is itself one of the dispatched
scripts. So a skill never names a `.ps1` directly; it names the `.sh` and
the dispatch rule maps it.

## Quick reference

All paths below are relative to the plugin root (`plugins/jira-sdlc/`).

| Script | Path | Summary | Called by |
|---|---|---|---|
| `statuscheck` | `skills/_shared/scripts/win/statuscheck.ps1` | Pre-flight healthcheck: one markdown table of env facts (git/worktree, branch, issue key, **platform**, gh+acli auth, project config, `JIRA-SDLC-TOOLS-RULES.md` presence + sections). Exit 0 if all OK, 1 if any `FAIL`. Its `platform` row confirms POSIX-bash vs Windows-ps1 dispatch (already chosen by the skill up front). | **assigner, executor, reviewer** — each skill's "Discovery & healthcheck" |
| `ensure_local_env` | `skills/_shared/scripts/win/ensure_local_env.ps1` | Ensures the gitignored `jira-sdlc-tools.local.env` exists: copies it from the main checkout into a linked worktree (which is born without it); no-op in the main checkout or when already present. Exit 0/1. | **assigner, executor, reviewer** — run **first** in each skill (before login, before statuscheck); also invoked as a child by `statuscheck.ps1`'s own `env_local` gate |
| `jira_acli_login` | `skills/_shared/scripts/win/jira_acli_login.ps1` `<role>` | Logs `acli` in as the role's Jira identity (`executor`\|`assigner`\|`reviewer`), idempotently — no-op if already that site+email, else `logout` then `login`. Exit 0/1. Token delivered via temp-file + `Start-Process -RedirectStandardInput` (see gotcha). | **assigner**→`assigner`, **executor**→`executor`, **reviewer**→`reviewer` — run after `ensure_local_env` |
| `get_assignee_email` | `skills/_shared/scripts/win/get_assignee_email.ps1` | Prints the email every issue should be assigned to (`JIRA_EXECUTOR_EMAIL` → `JIRA_ACCOUNT_EMAIL` fallback). One line on stdout. Exit 0/1, reason on stderr. | **assigner** only (to set sub-task assignees) |
| `check_assignee` | `skills/_shared/scripts/win/check_assignee.ps1` `[ISSUE-KEY]` | Is this issue assigned to the account `acli` is logged in as? Compares **accountId** (not email — email is hidden on others' assignee objects). Run **after** `jira_acli_login`. Exit 0 = mine → CONTINUE; 1 = unassigned / someone else / unreadable → STOP + fix on stderr. | **executor** only (before working an issue) |
| `acli-list-subtasks` | `skills/_shared/scripts/win/acli-list-subtasks.ps1` `-Parent <KEY> [-EnvPath …] [-Json]` | Lists a Jira parent's sub-tasks (key + summary); `acli workitem view --json` omits `subtasks` by default, so it requests `subtasks,issuetype`. Text or `-Json` output. Exit 0/1/<acli code>. | **None of the three skills** (they fetch subtasks inline). Operator/standalone helper a human runs from the CLI; documented in `skills/_shared/jira-acli-reference.md` §10 |

> **Note on `acli-list-subtasks`:** its POSIX sibling is now
> `skills/_shared/scripts/posix/acli-list-subtasks.sh` — a bash original like
> the other five, in the normal bash↔ps1 parity loop (the old python version
> is kept for reference at `docs/examples/acli-list-subtasks.py`, outside the
> active toolset). One asymmetry remains: the bash twin requires `jq` to
> address the nested per-sub-task fields reliably (see the script's own
> comment), while the `.ps1` port still needs neither `python3` nor `jq` (see
> "No python, no jq" below) — so on a `jq`-less POSIX box, the `.ps1` port run
> under `pwsh` is still the one that works.

## PowerShell 5.1 + 7 compatibility (load-bearing)

Every `win/*.ps1` port runs on **both** Windows PowerShell 5.1 (`powershell.exe`,
shipped with Windows) **and** PowerShell 7 (`pwsh`, installed separately). They
contain **no** PS7-only syntax — no ternary `?:`, null-coalescing `??`,
pipeline-chain `&&`/`||`, and no reliance on the `$IsWindows`/`$IsMacOS`/`$IsLinux`
automatic variables (those are PS6+, undefined on 5.1). Concretely:

- **OS detection** uses `$env:OS -eq 'Windows_NT'` (`statuscheck.ps1`'s
  `Get-DetectedOS`), with an explicit `$null -eq $IsWindows` fallback so 5.1
  falls through to the `$env:OS` branch.
- **Child exec** (`statuscheck.ps1` delegating to `ensure_local_env.ps1`) is
  runtime-agnostic: it picks `$PSHOME\pwsh.exe` if present, otherwise
  `$PSHOME\powershell.exe`.
- `statuscheck.sh`'s platform row (the POSIX twin, the source the skills'
  dispatch reads) tries `pwsh` first, then falls back to `powershell`, accepting
  version **≥ 5**.

### Invocation

```powershell
# PowerShell 7 (if installed) — default ExecutionPolicy is RemoteSigned, no bypass needed:
pwsh -NoProfile -File skills/_shared/scripts/win/<name>.ps1 [args]

# Windows PowerShell 5.1 ( shipped with Windows ) — default policy is Restricted:
powershell -NoProfile -ExecutionPolicy Bypass -File skills/_shared/scripts/win/<name>.ps1 [args]
```

The `-ExecutionPolicy Bypass` on the 5.1 form is not optional on a stock Windows
install: 5.1's default policy is `Restricted`, which refuses to load any
`.ps1`; 7 defaults to `RemoteSigned`, which loads local unsigned scripts fine.

### Verified

(Ported during JST-94.) All six ports pass the language tokenizer
(`System.Management.Automation.Language.Parser::ParseFile`) on **both** runtimes
and were live-run on a real Windows 11 box against a real Jira instance under:

- Windows PowerShell 5.1.26100.6584 (the only runtime initially on the box —
  no `pwsh`), and
- PowerShell 7.6.3 (installed via `winget install Microsoft.PowerShell`; it
  installs *alongside* 5.1 — `pwsh` ↔ 7, `powershell` ↔ 5.1, nothing overwritten).

`statuscheck.ps1` reports `PowerShell 5 + …` or `PowerShell 7 + …` under the
respective runtime; `jira_acli_login.ps1`, `check_assignee.ps1`, and
`acli-list-subtasks.ps1` were exercised live against Jira under both.

## Two gotchas to never undo

### 1. `jira_acli_login.ps1` token delivery — temp-file, NOT a native pipe

The raw API-token **value** is fed to `acli` on stdin. You **cannot** use
PowerShell's native string pipe (`"$Token" | & acli … --token`): on **Windows
PowerShell 5.1** the piped bytes arrive CRLF-corrupted, so `acli` rejects the
token. The bash twin's `printf '%s' "$token"` is byte-clean — so the port
matches that by writing the exact token bytes to a transient temp file (UTF-8,
no BOM, no trailing newline) and feeding it via `Start-Process
-RedirectStandardInput`, with a 180s `WaitForExit` cap (acli login can take
2–3 minutes on a real Jira instance). stdout and stderr go to **separate** temp
files — PS 5.1 throws if both are redirected to the same device/path (`NUL`).
Byte-clean on both 5.1 and 7. **Do not "simplify" this block back to a bare
pipe** — it breaks silently only on a real PS-5.1 box.

### 2. No python, no jq — the ports are dependency-free

The `win/*.ps1` ports parse `acli`'s `--json` output (and, for `acli-list-subtasks`,
the subtask list) with PowerShell's **built-in `ConvertFrom-Json`** — they need
neither `python3` nor `jq`. This matters on default Windows 11, where `python3`
on PATH is an "App Execution Alias" stub (prints a Microsoft Store nag, exits
non-zero — *not* real Python): the **bash** `check_assignee.sh`, which parses
with `… | python3 -c … 2>/dev/null || true`, silently fails there and
false-reports "UNASSIGNED". The ps1 twin is correct there. (Confirmed on the
JST-94 box.) The python dependency is a *bash-twin* Windows fragility, out of
this port's scope by design — the Windows dispatch path is ps1 precisely to
side-step it.

## See also

- **Repo-root `AGENTS.md`** → "Touched a `_shared/scripts/posix/*.sh`? Its `win/*.ps1`
  twin must stay in sync" — the parity contract, the `STATUSCHECK_FORCE_OS`-forced
  bash↔pwsh diff loop, and the residual Windows-only surface a Linux+pwsh diff
  can't reproduce.
- `skills/_shared/jira-acli-reference.md` §10 — `acli-list-subtasks.sh` /
  `acli-create-parent-and-subtasks.sh` operator helpers (the ps1 twin is the
  Windows form of the former).
- `skills/_shared/project-config.md` — the `jira-sdlc-tools.env` /
  `jira-sdlc-tools.local.env` variables the ports resolve (PROJECT-KEY,
  JIRA_*_EMAIL, JIRA_TOKEN, JIRA_ACCOUNT_URL, status names, etc.).
