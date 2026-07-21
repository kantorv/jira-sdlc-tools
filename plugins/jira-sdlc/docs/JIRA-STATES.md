# Jira states — who moves a card, and when

The four `<STATUS_*>` tokens in `jira-sdlc-tools.env` are **anchor
states**: names mapped onto whichever real statuses your board uses for
those roles. This document says which moves the skills make themselves,
which they ask about, and which belong to you.

Everything below is a **default**. A rule in `JIRA-SDLC-TOOLS-RULES.md`
overrides any of it and wins wherever it disagrees with a `SKILL.md` — see
[Overriding the defaults](#overriding-the-defaults).

## The four transitions a skill makes

| # | Skill | When | Transition |
|---|---|---|---|
| 1 | `jira-task-executor` | it picks the issue up (step 3) | → `<STATUS_IN_PROGRESS>` |
| 2 | `jira-task-executor` | it has just opened the PR (step 11) | → `<STATUS_IN_REVIEW>` |
| 3 | `jira-task-reviewer` | verdict is CHANGES REQUESTED on a sub-task or single-step PR (step 3d) | → `<STATUS_IN_PROGRESS>` |
| 4 | `jira-task-reviewer` | verdict is CHANGES REQUESTED on the aggregate parent PR (step 5b) | → `<STATUS_IN_PROGRESS>` |

3 and 4 are the same rule applied to every reject path. They're listed
separately because they haven't always behaved alike: 5b used to post its
verdict comment and move nothing, so a rejected parent PR sat in
`<STATUS_IN_REVIEW>` reading as "waiting for the reviewer" when it was
really waiting on a human. If you write your own reject rule, phrase it as
*every* reject path so it can't re-acquire that asymmetry.

Transition 2 is load-bearing beyond reporting: `jira-task-reviewer`
reviews only sub-tasks sitting in `<STATUS_IN_REVIEW>`. Suppress it without
arranging another way to set that status and the work becomes invisible to
review.

## The one transition a skill asks about

**`<STATUS_DONE>` on an approved PR.** When `jira-task-reviewer` finishes a
run in which anything was approved, it asks you — once, naming every
approved issue — whether to move them to `<STATUS_DONE>`, and transitions
only what you say yes to.

It asks rather than decides because an approval is not a merge. On most
boards Done means merged, and an approved PR is still open, so setting it
would be premature. But plenty of teams do close the card at approval, and
nothing in the repo tells the reviewer which kind of team yours is. If a
rejection was the only outcome, there's no question — 3d/5b already sent
that issue back.

## What no skill does

- **Nothing sets `<STATUS_DONE>` unprompted.** Normally GitHub-for-Jira's
  merge automation does it when the human merges. The reviewer's question
  above is the only skill-side path, and it needs your yes.
- **Nothing sets `<STATUS_TODO>`.** New issues land in whatever status your
  workflow makes the creation default; the token exists so the rest of the
  config can name that state.
- **`jira-task-assigner` transitions nothing.** It creates issues,
  branches, and worktrees, and leaves status alone.
- **Nothing moves a card through intermediate states** your board may have
  between these anchors. That's the anchor-mapping contract: the skills
  touch the anchors, everything between them is yours.

## Overriding the defaults

Put the rule in **`JIRA-SDLC-TOOLS-RULES.md`** in your project root rather
than editing a `SKILL.md` — the skills ship generic and the next update
overwrites them. Every skill reads that file at the start of a run, and
where a rule disagrees with a skill instruction, **the rule wins**.

Suppressing a transition, in the section for the skill that makes it:

```markdown
## JIRA-TASK-EXECUTOR

Don't transition to <STATUS_IN_REVIEW> when you open the PR — our Jira
automation moves the card off the back of the PR event, and a second
transition trips its rule quota.
```

Answering the Done question up front, so the reviewer stops asking:

```markdown
## JIRA-TASK-REVIEWER

When you approve a PR, transition the issue to <STATUS_DONE> yourself —
don't ask. We have no GitHub-for-Jira connection, so nothing else will.
```

Or the opposite, if Done should only ever follow a merge:

```markdown
## JIRA-TASK-REVIEWER

Never move an issue to <STATUS_DONE>, and don't ask about it — merging is
what closes a card here, and our automation handles that.
```

Routing through a state specific to your board:

```markdown
## COMMON

Our board has a "Blocked" column. If you stop and hand back to a human
for any reason, move the issue there first and say so in your report —
otherwise the card looks like it's still being worked.
```

## Reference

- [`../skills/_shared/project-config.md`](../skills/_shared/project-config.md)
  — the rules file's format and full load contract, and every `<TOKEN>`.
- [`../JIRA-SDLC-TOOLS-RULES.example.md`](../JIRA-SDLC-TOOLS-RULES.example.md)
  — template to copy.
- [`CI.md`](CI.md) — the GitHub Actions transition workflows, the other
  supported way to drive a board.
