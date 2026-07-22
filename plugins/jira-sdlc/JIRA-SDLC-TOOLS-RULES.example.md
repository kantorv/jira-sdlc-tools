# JIRA-SDLC-TOOLS-RULES.md — template

Copy this file to the **root of your own repo**, next to
`jira-sdlc-tools.env`, and drop the `.example` from the name:

```bash
cp "${CLAUDE_PLUGIN_ROOT}/JIRA-SDLC-TOOLS-RULES.example.md" JIRA-SDLC-TOOLS-RULES.md
```

Then delete everything above the first `## COMMON` heading and write your
own rules. **The file is optional** — if you have no project conventions
to declare, don't create it; the skills run exactly as before when it's
absent.

## How the skills read it

Each of `jira-task-assigner`, `jira-task-executor`, and
`jira-task-reviewer` reads this file at the very start of its run, before
its own discovery/healthcheck work, and:

- **adopts `## COMMON` plus the section named after itself**, ignoring the
  other two skills' sections;
- treats those instructions as project conventions layered on top of its
  own logic — and **where a rule here and a skill instruction disagree,
  the rule here wins**. That is the point of the file: it exists to
  override generic skill defaults with what your project actually does;
- proceeds silently when the file doesn't exist.

Keep the four headings below, spelled and ordered as they are — that's
what each skill looks for. Any of them may be left empty. Content is
free-form prose; write instructions the way you'd write them for a new
teammate, and say *why*, not just *what*, so the reasoning generalizes to
cases you didn't enumerate.

Everything below the next line is the part you keep and edit.

---

## COMMON

<!--
Rules every skill should follow in this repo. Examples of the kind of
thing that belongs here (delete these and write your own):

- Conventions the whole workflow depends on: which docs are authoritative,
  which directories are generated and must never be hand-edited, whether
  commits need a sign-off trailer.
- Anything the skills would otherwise have to guess at and could guess
  wrong.

Refer to configured values by their token names (<STATUS_DONE>,
<DEFAULT_BASE_BRANCH>, …) where a rule is really about the configured
value rather than a literal — the tokens resolve from jira-sdlc-tools.env.
-->

## JIRA-TASK-ASSIGNER

<!--
Rules for planning work into issues, branches, and worktrees. Examples:

- How to split work: "prefer one sub-task per deployable unit, never split
  a schema change from the code that reads it — the two can't be reviewed
  independently."
- Issue hygiene: components, labels, or a description template your board
  expects on every issue.
-->

## JIRA-TASK-EXECUTOR

<!--
Rules for implementing an issue. Examples:

- Test policy beyond what CLAUDE.md / AGENTS.md already state.
- PR conventions: body template, required reviewers, labels this repo's
  release tooling reads.
- Board conventions that differ from the defaults. By default the executor
  moves the issue to <STATUS_IN_PROGRESS> when it picks it up and
  <STATUS_IN_REVIEW> when it opens the PR (docs/JIRA-STATES.md) — override
  either here, e.g.:

Don't transition to <STATUS_IN_REVIEW> at the end — opening the PR is
enough, our automation moves the card.
-->

## JIRA-TASK-REVIEWER

<!--
Rules for reviewing. Examples:

- Extra review dimensions this codebase cares about: migrations,
  public API surface, generated artifacts, accessibility.
- The <STATUS_DONE> question. By default the reviewer ASKS you, at the end
  of a run, whether to move approved issues to <STATUS_DONE>. Answer it
  once here and it stops asking — either:

When you approve a PR, transition the issue to <STATUS_DONE> yourself —
don't ask. We have no GitHub-for-Jira connection, so nothing else will.

  or the opposite:

Never move an issue to <STATUS_DONE>, and don't ask about it — merging is
what closes a card here, and our automation handles that.
-->
