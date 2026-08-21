---
slug: /jira-board-preparation
sidebar_position: 4
sidebar_label: 3. Jira board preparation
---

# Section 3. Jira board preparation

## 3.1 Create the board

Create a Jira project and its board. **This plugin was tested on a simple
Kanban board** — the default Kanban template, with its default columns, is
the known-good setup. Scrum boards and custom workflows should work provided
step 3.2 holds, but they aren't what was exercised.

## 3.2 Read the four statuses off your board

The skills move issues through four workflow statuses, and they match names
**literally** — `In progress` and `In Progress` are different statuses. So don't
type them from memory: ask your board what it actually has. Run these from your
skills folder (Section "Loading the skills" in the README says where that is on
your platform); the second one needs the key from the first:

```bash
# the projects this credential can see — key, name, type/style
bash _shared/scripts/posix/jira.sh --role executor raw GET /project/search \
  | jq -r '.values[] | "\(.key)\t\(.name)\t\(.projectTypeKey)/\(.style)"'
# the statuses your chosen project really has
bash _shared/scripts/posix/jira.sh --role executor raw GET /project/<KEY>/statuses \
  | jq -r '[.[].statuses[].name] | unique | .[]'
```

```powershell
pwsh -File _shared\scripts\win\jira.ps1 --role executor raw GET /project/search
pwsh -File _shared\scripts\win\jira.ps1 --role executor raw GET /project/<KEY>/statuses
```

Then map each setting onto a name from that list:

| Setting | Default Kanban name | Who sets it |
| -- | -- | -- |
| `STATUS_TODO` | `To Do` | no skill does — it names the status new issues land in, and it's the only status the optional branch-create Action advances *from* |
| `STATUS_IN_PROGRESS` | `In Progress` | `jira-task-executor`, when it starts work |
| `STATUS_IN_REVIEW` | `In Review` | `jira-task-executor`, when its PR opens |
| `STATUS_DONE` | `Done` | `jira-task-reviewer` step 7, but only for approved issues and only if you say yes — otherwise GitHub-for-Jira automation on merge, or you, by hand |

Those defaults are the **Kanban template's** names, not a requirement — treat
them as a hint for which real status to pick, not as the answer. Boards
routinely differ: `In Review` is missing from several Jira templates, and a
board with `Backlog` / `Selected for Development` instead of `To Do` is normal
too. Where two of your statuses could fit, pick by consequence — `STATUS_TODO`
should be the status your new issues actually land in, since that's where work
is picked up from.

To prove the names *and* the workflow rather than assume either, spend one
scratch issue: create it, walk it through your four configured names, delete it,
and confirm the delete came back 404. `/jira-sdlc:jst-install` §3d does exactly
that (after asking), and a wrong name or a transition your workflow forbids
surfaces there, at setup, instead of mid-run.

## 3.3 Record the project key and statuses

Put all five in `.jst/jira-sdlc-tools.env` (the shared/team file — the tokens
and paths from [Section 1](PREPARING-ENVIRONMENT.md) live in
`.jst/jira-sdlc-tools.local.env` instead):

```
PROJECT_KEY=PROJ
STATUS_TODO=To Do
STATUS_IN_PROGRESS=In Progress
STATUS_IN_REVIEW=In Review
STATUS_DONE=Done
```

That block is the shape, not the values — substitute the key and the four names
3.2 turned up on your own board. `PROJECT_KEY` is the prefix in your issue
keys — `PROJ` in `PROJ-278` — and the skills match branch names against it, so
a wrong one is caught rather than worked.

Next: [Section 4. Run the healthcheck](RUN-THE-HEALTHCHECK.md).
