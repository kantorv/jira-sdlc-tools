# Jira states — who moves a card, and when

The four `<STATUS_*>` tokens in `jira-sdlc-tools.env` are **anchor
states**: names mapped onto whichever real statuses your board uses for
those roles. This document answers the question that matters when you're
wiring a board or an automation up to these skills — *which of those moves
does an agent make by itself, and which does something else have to make?*

The short answer: **an agent writes a Jira status in exactly three
places.** Everything else on your board is moved by a human, by
GitHub-for-Jira, or by your own automation.

## The three agent-initiated transitions

| # | Skill | Where | Transition | Trigger |
|---|---|---|---|---|
| 1 | `jira-task-executor` | step 3 — *Transition the issue* | → `<STATUS_IN_PROGRESS>` | It has picked up the issue and is about to work it |
| 2 | `jira-task-executor` | step 11 — *Update Jira* | → `<STATUS_IN_REVIEW>` | It has just opened the PR |
| 3 | `jira-task-reviewer` | step 3d — reject path | → `<STATUS_IN_PROGRESS>` | The review verdict is CHANGES REQUESTED |

All three are `acli jira workitem transition --key <KEY> --status "…" --yes`.

Site 3 is keyed on `<SUBTASK-KEY-or-PARENT-KEY>`, so it covers both a
multistep sub-task's PR and a single-step top-level issue's PR. It is the
**actual workflow gate** on the reject path — GitHub blocks an author from
formally rejecting their own PR when the executor and reviewer share one
`gh` account, so the verdict is recorded as a review *comment* and the
Jira move is what really sends the work back.

## What no agent ever does

- **`<STATUS_DONE>` is never written by a skill.** It is reached when a
  human merges the PR — by GitHub-for-Jira's merge automation if you have
  it connected, otherwise by a manual transition. `jira-task-executor`
  step 11 says so explicitly ("Don't transition to Done here"), and the
  reviewer never merges anything.
- **`<STATUS_TODO>` is never written by a skill either.** New issues land
  in whatever status your workflow makes the creation default; the token
  exists so the rest of the config can name that state, not because
  anything sets it.
- **`jira-task-assigner` transitions nothing at all.** It creates issues,
  branches, and worktrees, and leaves status entirely alone.
- **Nothing moves a card through intermediate states** your board may have
  between these anchors. That is the anchor-mapping contract: the skills
  touch only the anchors, and every state in between belongs to you.

## Changing this behaviour

Don't edit a `SKILL.md` to change what your project's board does — the
skills ship generic and the next update overwrites them. Put the rule in
**`JIRA-SDLC-TOOLS-RULES.md`** in your project root instead. Every skill
reads it at the start of a run, and **where a rule there disagrees with a
skill instruction, the rule wins** — overriding these defaults is exactly
what the file is for.

Suppressing a transition, in the section for the skill that makes it:

```markdown
## JIRA-TASK-EXECUTOR

Don't transition to <STATUS_IN_REVIEW> when you open the PR — our Jira
automation moves the card off the back of the PR event, and a second
transition trips its rule quota.
```

Adding one the skills don't make:

```markdown
## JIRA-TASK-REVIEWER

When you approve a PR, transition the issue to <STATUS_DONE> yourself.
We have no GitHub-for-Jira connection, so nothing else will.
```

Or routing through an intermediate state your board has:

```markdown
## COMMON

Our board has a "Blocked" column. If you stop and hand back to a human
for any reason, move the issue there first and say so in your report —
otherwise the card looks like it's still being worked.
```

See [`../skills/_shared/project-config.md`](../skills/_shared/project-config.md)
for the file's format and full load contract, and
[`../JIRA-SDLC-TOOLS-RULES.example.md`](../JIRA-SDLC-TOOLS-RULES.example.md)
for a template to copy.

## Known asymmetry on the reject path

The reject path in `jira-task-reviewer` **step 5b** — the aggregate parent
PR on the multistep track — posts its `CHANGES REQUESTED` review comment
but does *not* transition the parent issue, unlike step 3d. A rejected
parent PR therefore leaves its issue in `<STATUS_IN_REVIEW>`.

This may be deliberate: sending a parent back to `<STATUS_IN_PROGRESS>`
implies an executor run against a parent issue, which `jira-task-executor`
step 1 deliberately refuses without confirmation, since implementing on a
parent branch shadows its sub-tasks' own PRs. It is recorded here because
the asymmetry is currently undocumented in either direction — if your
board needs the parent moved, add that rule to
`JIRA-SDLC-TOOLS-RULES.md`'s `## JIRA-TASK-REVIEWER` section.
