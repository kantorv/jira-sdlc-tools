---
slug: /step-by-step-installation/read-the-project-key-and-statuses
sidebar_position: 3
sidebar_label: Read the project key and statuses from Jira
---

# Read the project key and statuses from Jira

Do not type the project key or status names from memory. Statuses are matched
**literally**, so `In progress` and `In Progress` are different values.

First list the projects the configured Jira credential can see:

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"
bash "$S/jira.sh" --role executor raw GET /project/search \
  | jq -r '.values[] | "\(.key)\t\(.name)\t\(.projectTypeKey)/\(.style)"'
```

Choose the project that should be wired to this repository. Do not silently
auto-select one just because its name resembles the repository name.

Then fetch the statuses for the chosen project:

```bash
bash "$S/jira.sh" --role executor raw GET /project/<CHOSEN-KEY>/statuses \
  | jq -r '[.[].statuses[].name] | unique | .[]'
```

Map the four settings onto names that actually exist on that board:

| Variable | Typical Kanban name | Meaning |
| -- | -- | -- |
| `STATUS_TODO` | `To Do` | status where new issues land; the optional branch-create Action advances from it |
| `STATUS_IN_PROGRESS` | `In Progress` | executor starts work here |
| `STATUS_IN_REVIEW` | `In Review` | executor moves the issue here when its PR opens |
| `STATUS_DONE` | `Done` | reviewer may close it; merge automation or a human may also do so |

These are **hints**, not required literal names. Boards commonly differ. In
particular, `STATUS_TODO` should be the status where newly created work actually
lands, rather than simply the first status whose name looks similar.
