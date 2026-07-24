# jira-reference.md — moved

This file used to be `jira-acli-reference.md`, the call-site reference for the
Atlassian CLI (`acli`). **The skills no longer use `acli`.** They drive Jira
over the REST API v3 through a small client, `jira.sh` (POSIX) / `jira.ps1`
(Windows), that authenticates **per-request** — no login, no machine-global
active account.

**→ The single operational reference is now
[`jira-api-reference.md`](jira-api-reference.md).**
It covers both the `jira.sh` command surface the skills invoke (§9–§13) and the
raw REST substrate underneath it (§0–§8). The client itself lives at
`scripts/posix/jira.sh` (+ its `scripts/win/jira.ps1` twin).

### Where each old `acli-reference` section went

| old `acli-reference` § | now in `jira-api-reference.md` |
|---|---|
| §0 Auth (`acli auth login`) | §9 — `--role` per-request auth (no login) |
| §2 Creating issues | §9 command surface (`jira issue create`) |
| §3 Reading / field lists | §10 issue field lists |
| §4 Transition / assign | §9 command surface (`jira issue transition` / `assign`) |
| §6 Comments / markers | §11 comments & markers |
| §7 Git branch convention | §12 git branch convention |
| §8 Destructive (`delete`) | §9 command surface (`jira issue delete`) |
| §12 PR-base resolver | §13 PR-base resolver |

### `acli` → `jira` command map

| was (`acli`) | now (`jira.sh` / `jira.ps1`) |
|---|---|
| `acli jira workitem view K --json --fields …` | `jira issue view K --fields …` (always JSON) |
| `acli jira workitem create --project … --description-file F` | `jira issue create --project … --desc-file F` (prints the key) |
| `acli jira workitem transition --key K --status "S" --yes` | `jira issue transition K --to "S"` |
| `acli jira workitem assign --key K --assignee E --yes` | `jira issue assign K --to E` (or `--remove`) |
| `acli jira workitem comment create --key K --body-file F` | `jira issue comment add K --body-file F` |
| `acli jira workitem comment list --key K --json` | `jira issue comment list K` |
| `acli jira workitem delete --key K --yes` | `jira issue delete K` (`--with-subtasks`) |
| `acli jira project list … \| grep K` | `jira project exists K` |
| `acli jira auth status` | `jira whoami` |

The narrative `acli` companion `../../docs/JIRA-ACLI.md` is retained as
historical background only — nothing a skill runs depends on it.
