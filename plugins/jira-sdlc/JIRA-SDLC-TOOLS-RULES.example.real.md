# Project rules for jira-sdlc-tools

Project conventions for the three `jira-sdlc` skills when they run against
this repo. Each skill reads `## COMMON` plus its own section and ignores
the other two; where a rule here disagrees with a `SKILL.md` instruction,
the rule here wins. Format and load contract:
[`plugins/jira-sdlc/skills/_shared/project-config.md`](plugins/jira-sdlc/skills/_shared/project-config.md).

## COMMON

[AGENTS.md](AGENTS.md) is the authority on how to work in this repo — read
it before acting, and treat the rules below as the skill-facing summary of
it, not a replacement.

The two rules worth repeating here, because breaking either is invisible
in review:

- **Never write a project-specific literal into anything under
  `plugins/`.** A real Jira key, a real path, a specific framework name —
  each of those quietly breaks the next project that installs this plugin.
  Use a `<TOKEN>` and describe it in `jira-sdlc-tools.env`'s example table.
  This file is the exception: it *is* a destination-repo file, so real
  values belong here.
- **`SKILL.md` files are prompts an LLM re-reads on every run**, not
  documentation. Every line costs context and adds a place to misread, so
  prefer one line where one line does, explain *why* instead of stacking
  MUSTs, and push detail that isn't needed on every run down into
  `skills/_shared/`.

## JIRA-TASK-ASSIGNER

Split along the file boundaries the repo already has — skills, `_shared/`
references, `scripts/`, `docs/` — rather than by topic. Two sub-tasks that
both edit the same `SKILL.md` will conflict in a file where every line is
load-bearing prose, and the conflict is expensive to resolve well.

A change to a `_shared/scripts/posix/*.sh` script and the matching
`win/*.ps1` port belong in the **same** sub-task, never split across two.
They're a contract pair; landing one without the other ships a silently
broken Windows path.

## JIRA-TASK-EXECUTOR

**There is no test suite here, and that's deliberate** — this repo is
prompt files plus two JSON manifests. At step 7, don't offer to install a
test runner. Run these instead, and report them as the test results:

```bash
claude plugin validate .                     # both manifests + source paths
bash scripts/check-mermaid.sh <changed.md>   # only if you touched a ```mermaid block
```

Beyond those, "testing" means re-reading the changed skill end to end for
the scenario you changed (single-step vs. multistep, parent vs. sub-task,
each review dimension). These files *are* the behaviour — there's no
implementation to run against them.

Two traps that produce a change which looks correct in the diff and fails
in use:

- **A `;` inside mermaid message text truncates the line** and breaks the
  whole diagram, and the parser's error points at the token *after* it.
  Write `—` or `·`. Render anything you touched; don't eyeball it.
- **Editing one script port without the other.** `statuscheck`,
  `ensure_local_env`, `jira_acli_login`, `get_assignee_email`, and
  `check_assignee` ship as a bash/PowerShell pair with identical
  arguments, output, and exit codes. Change one, change its twin, then
  diff the two with `STATUSCHECK_FORCE_OS=windows` as AGENTS.md shows.

## JIRA-TASK-REVIEWER

Review the same two invariants the executor is told to protect, since
neither shows up as a broken build: every `_shared/scripts/posix/*.sh`
change has a matching `win/*.ps1` change, and every touched mermaid block
still parses.

Then check the change against the skill-writing guidance in AGENTS.md —
a `SKILL.md` edit that is correct but bloated, buries a rule mid-file, or
adds an ALL-CAPS imperative where one clause of reasoning would
generalize better is a legitimate finding here, not a nitpick.
