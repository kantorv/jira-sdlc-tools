# Project configuration reference

This file describes every variable used in `jira-tools-plugin.env`
(the `.env` file in the project root). All project-specific values
live in `jira-tools-plugin.env` — nothing else under `skills/` should need editing
after that.

Each skill's "Conventions used below" section names the tokens it needs
(e.g. `<PROJECT-KEY>`). Before following a skill's instructions, resolve
every token it references against `jira-tools-plugin.env`; the tables below describe
what each variable means.

## Required

| Token | What it is | Example |
|---|---|---|
| `<PROJECT-KEY>` | Your Jira project key. | `PROJ` |
| `<WORKTREES_DIR>` | Path to the sibling directory where per-issue worktrees are created, relative to the repo root. Must already exist — `jira-task-assigner` will not create it. | `../myapp-worktrees` |
| `<DEFAULT_BASE_BRANCH>` | The branch new top-level work starts from when there's no parent context yet. | `development` |
| `<CONVENTIONS_PATH>` | Where this repo's coding conventions live, for `jira-task-reviewer` to check changes against. | `.claude/rules/` |
| `<CONVENTION_HIGHLIGHTS>` | Freeform, optional: specific patterns worth flagging during review — your state-management library, component library, i18n approach, whatever's easy to get subtly wrong here. Leave blank to review generically. | `XState conventions, MUI usage, translation keys` |

## Testing — used by `jira-task-executor` step 7

| Token | What it is | Example |
|---|---|---|
| `<TEST_SINGLE_CMD>` | Command to run one test in isolation. | `yarn playwright test {file}:{line}` |
| `<TEST_SUITE_CMD>` | Command to run a whole affected suite. | `yarn playwright test {file}` |

If your runner can't select a single test by line number, adapt step 7 of
`jira-task-executor` to select by name or pattern instead — the *policy*
(individually first, full suite second, re-run only the failures before
trusting a red suite) is framework-agnostic even though these two example
commands aren't.

## Jira workflow status names

These are already flagged as "confirm once" inside the skills, because
Jira status *names* vary by project even when the underlying states are the
same. Check yours with `jira issue view <any-existing-key>`.

| Token | What it is | Example |
|---|---|---|
| `<STATUS_TODO>` | Status used for newly created issues. | `To Do` |
| `<STATUS_IN_PROGRESS>` | Status `jira-task-executor` transitions an issue to when it starts work. | `In Progress` |
| `<STATUS_IN_REVIEW>` | Status used when a PR is opened and under review. | `In Review` |
| `<STATUS_DONE>` | Final status the reviewer (and the single-step flow) transitions issues to once their work has landed. Must match your workflow's real status name exactly. | `Done` |

## Optional — sensible defaults, override if yours differ

| Token | What it is | Default |
|---|---|---|
| `<SEMVER_LABELS>` | The three GitHub label names `jira-task-executor` applies to PRs for release automation. Must already exist on the repo. | `patch` / `minor` / `major` |
| `<JIRA_TOKEN_PATH>` | Fallback token file, used when `JIRA_API_TOKEN` isn't already exported. | `.jira/token.txt` |
| `<HAS_EPIC_TYPE>` | Whether your Jira project has an `Epic` type above Task/Story/Bug. These skills assume a two-level hierarchy and don't handle Epics — if yours has one, extend `jira-task-assigner` step 5 and the hierarchy checks in `jira-cli-reference.md` §1/§3 yourself before relying on this. | `no` |

## Worked example

The README's usage walkthrough assumes this filled-in `.env`:

```
PROJECT-KEY           = PROJ
WORKTREES_DIR         = ../myapp-worktrees
DEFAULT_BASE_BRANCH   = development
CONVENTIONS_PATH      = .claude/rules/
CONVENTION_HIGHLIGHTS =
TEST_SINGLE_CMD       = yarn playwright test {file}:{line}
TEST_SUITE_CMD        = yarn playwright test {file}
STATUS_TODO           = To Do
STATUS_IN_PROGRESS    = In Progress
STATUS_IN_REVIEW      = In Review
STATUS_DONE           = Done
SEMVER_LABELS         = patch / minor / major
JIRA_TOKEN_PATH       = .jira/token.txt
HAS_EPIC_TYPE         = no
```
