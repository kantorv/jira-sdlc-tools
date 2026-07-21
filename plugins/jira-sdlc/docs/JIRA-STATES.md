# Jira states — who moves a card, and when

The four `<STATUS_*>` tokens in `jira-sdlc-tools.env` are **anchor
states**: names mapped onto whichever real statuses your board uses for
those roles.

**No skill moves a card by itself.** All three read the board where they
need to, and none of them writes to it — not at pickup, not when a PR
opens, not on either review verdict. A skill transitions an issue only
when something explicitly asks it to:

1. a rule in `JIRA-SDLC-TOOLS-RULES.md` — `## COMMON` or the section named
   after that skill, or
2. you, in chat, during a run.

The reasoning is that status is a *shared* signal. Humans, GitHub-for-Jira,
Jira Automation, and your own workflows all write to the same field, and
none of them can tell a card an agent moved from one a person moved. A
transition nobody asked for is therefore a claim your team has no way to
audit — so the default is to make none, and to say in the run report which
status the issue is actually in.

This also means the anchors are yours to map freely: a board with six
columns between "picked up" and "merged" needs no special handling,
because the skills aren't trying to drive it.

## What each token is for

| Token | Read by a skill? | Written by a skill? |
|---|---|---|
| `<STATUS_TODO>` | no | no |
| `<STATUS_IN_PROGRESS>` | no | no |
| `<STATUS_IN_REVIEW>` | **yes** — `jira-task-reviewer` reviews only sub-tasks sitting in this status | no |
| `<STATUS_DONE>` | no | no |

The one read matters: `<STATUS_IN_REVIEW>` is how the reviewer decides
which sub-tasks are in scope. Since nothing writes it by default,
**something else has to** — a rule below, your automation, or a person —
or the reviewer will find nothing to review.

## Restoring the built-in transitions

Earlier versions of these skills made three transitions automatically.
That behaviour now lives here as a rule you opt into. Copy what you want
into `JIRA-SDLC-TOOLS-RULES.md` in your project root:

| # | Skill | When | Transition |
|---|---|---|---|
| 1 | `jira-task-executor` | it picks up the issue (step 3) | → `<STATUS_IN_PROGRESS>` |
| 2 | `jira-task-executor` | it has just opened the PR (step 11) | → `<STATUS_IN_REVIEW>` |
| 3 | `jira-task-reviewer` | verdict is CHANGES REQUESTED (step 3d) | → `<STATUS_IN_PROGRESS>` |

```markdown
## JIRA-TASK-EXECUTOR

Move the issue as you work it — our board is how the team sees progress:
- when you pick it up (step 3) → <STATUS_IN_PROGRESS>
- once you've opened the PR (step 11) → <STATUS_IN_REVIEW>

The second one matters beyond reporting: jira-task-reviewer only reviews
sub-tasks sitting in <STATUS_IN_REVIEW>, so skipping it leaves the work
invisible to review.

## JIRA-TASK-REVIEWER

When your verdict is CHANGES REQUESTED, transition the issue back to
<STATUS_IN_PROGRESS> — the review comment records *what* was wrong, but
the status is what tells the board the work bounced.

This applies to every reject path, including step 5b (the aggregate
parent PR on the multistep track). Step 3d and step 5b behave the same
way here.
```

That last paragraph closes a gap the built-in behaviour had: step 3d
transitioned on reject, step 5b didn't, so a rejected multistep *parent*
PR left its issue sitting in `<STATUS_IN_REVIEW>` with no board signal at
all. Stating the rule once for "every reject path" avoids re-inheriting
that asymmetry.

## Going further than the old defaults

Nothing restricts you to the three above. Rules can add transitions the
skills never made:

```markdown
## JIRA-TASK-REVIEWER

When you approve a PR, transition the issue to <STATUS_DONE> yourself.
We have no GitHub-for-Jira connection, so nothing else will.
```

Or route through states specific to your board:

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
  — template to copy, with the transition rules above pre-filled and
  commented out.
- Precedence: where a rule and a `SKILL.md` instruction disagree, **the
  rule wins**. Overriding a skill default is what the file is for.
