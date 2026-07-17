# `jira_attach` — logic and execution nuances

`jira_attach` uploads one or more local files to a Jira issue as
attachments. It ships twice — `posix/jira_attach.sh` (bash + `curl` +
`python3`) and `win/jira_attach.ps1` (PowerShell 5.1+, native
`Invoke-RestMethod`/`Invoke-WebRequest`, no bash/python3/curl) — same
arguments, same stdout shape, same exit codes, same env precedence. This
doc covers what it does once (so it isn't duplicated across two script
headers) and the nuances that only show up when you run it for real.

Its main caller is `sync_conversations` (its `--attach` leg), which hands
`jira_attach` the transcript path list it just computed. You can also run
`jira_attach` directly with any files.

## Why REST instead of `acli`

`acli jira workitem attachment` only supports **list** and **delete** — it
can't upload. So `jira_attach` goes through Jira Cloud's REST API on the
`api.atlassian.com` gateway, authenticating with the executor's
`email:token` basic auth (the same identity `jira_acli_login` logs in as).
acli's keyring isn't reusable for raw REST, so the credentials are read
straight from the env files.

## Usage / dispatch

Pick the branch from your own runtime before running it — never infer it
from output:

```bash
bash  posix/jira_attach.sh  [--dry-run] <ISSUE-KEY> <file> [<file> ...]
pwsh  win/jira_attach.ps1    [--dry-run] <ISSUE-KEY> <file> [<file> ...]
```

(paths are relative to this file's own directory,
`conversation-debugger/scripts/`)

- `--dry-run` (must be the **first** argument) reports the upload/skip
  decision for each file without POSTing anything.
- `<ISSUE-KEY>` is a Jira key like `PROJ-123`.
- One or more file paths follow. Missing `<ISSUE-KEY>` or zero files is a
  usage error (exit 1).

### Output

One line per file, then a summary line:

```
attached: transcript-a.jsonl → PROJ-123
already attached, skipped: transcript-b.jsonl
jira_attach: uploaded 1, 1 already present
```

Under `--dry-run` the verb becomes `would upload` (`would upload: … → KEY`
per file, `jira_attach: would upload N, M already present` summary). If any
file failed, the summary gains a `, some failed` suffix and the exit code
is 1. Per-file errors (`no such file`, `FAILED (HTTP <code>)`) go to
stderr; the loop continues to the remaining files.

**Exit codes:** `0` if every file uploaded or was already present; `1` on
any usage / auth / config / upload failure.

## Idempotent by filename

Before uploading, `jira_attach` fetches the issue's current attachments and
**skips any file whose basename already matches** — so a re-run only
uploads what's new. This matters because **Jira does not dedupe**: the same
name POSTed twice yields two separate copies. Matching is on basename
(what the upload sets as the attachment filename), not full path or
content.

A **failed** attachment listing is fatal (exit 1, "aborting to avoid
duplicates") rather than silently risking duplicate uploads.

## Configuration and precedence

Credentials and site are read from `jira-sdlc-tools.local.env` then
`jira-sdlc-tools.env` in the repo root, with the same `NAME = value` parser
and **local-overrides-team, last-match-wins** precedence as the other
scripts:

- `JIRA_ACCOUNT_URL` — the site host.
- `JIRA_EXECUTOR_EMAIL` / `JIRA_EXECUTOR_TOKEN`, each **falling back to**
  `JIRA_ACCOUNT_EMAIL` / `JIRA_TOKEN` when the executor-specific value is
  unset.

`JIRA_ACCOUNT_URL` is stored **without a scheme** (and maybe a trailing
slash); both ports strip `https?://` and a trailing `/` before building
URLs, or the `tenant_info` cloud-id lookup 404s. The cloud id (needed for
the `api.atlassian.com/ex/jira/<cloudId>/…` gateway path) is resolved at
runtime from `https://<site>/_edge/tenant_info`, which redirects — both
ports follow the redirect.

## Execution nuances

**The bash original needs a real `python3` and `curl`; the Windows port
needs neither.** The posix script parses `tenant_info` and the attachment
list with `python3` and uploads with `curl -F`. On a machine where
`python3`/`python` resolve only to the Windows Store app-execution-alias
stub (not a real interpreter — common on a fresh Windows box), the bash
script fails at cloud-id resolution with "could not resolve cloudId" even
though the endpoint itself is reachable. The `.ps1` port sidesteps this
entirely by using native `Invoke-RestMethod`/`Invoke-WebRequest`.

**The multipart upload is the one genuinely runtime-divergent piece.**
PowerShell 7's `Invoke-WebRequest` has `-Form`, but **5.1 does not** — so
the `.ps1` port builds the `multipart/form-data` body as **raw bytes**
(UTF-8 header + the file's exact bytes + closing boundary) and sends it via
`-Body [byte[]]`, which transmits the payload unmodified and binary-safe on
both runtimes. Error-body extraction also differs (PS 7 surfaces it in
`$_.ErrorDetails.Message`; 5.1 only via the `HttpWebResponse` stream); the
port handles both. Verified end-to-end — real upload + idempotent skip —
under **both** `powershell.exe` 5.1 and `pwsh` 7, with byte-identical
stdout.

**Windows PowerShell 5.1 needs its execution policy addressed before an
unsigned `.ps1` runs at all.** Under the default `Restricted` policy,
`powershell -File jira_attach.ps1 …` fails with `UnauthorizedAccess:
running scripts is disabled on this system` before the script runs. This is
standard Windows behavior for any unsigned script, shared by every port
under `win/` — run with `-ExecutionPolicy Bypass` for just that invocation,
or have the machine's policy set to `RemoteSigned`/`Unrestricted`. `pwsh`
(7+) was not observed to require this on the same machine.
