---
slug: /step-by-step-installation/add-bootstrap-and-teardown-scripts
sidebar_position: 2
sidebar_label: Add bootstrap and teardown scripts
---

# Add bootstrap and teardown scripts

**Only if more than one worktree's app will run at a time.** The assigner gives
each issue its own worktree, which isolates the source tree and nothing else. A
database, a cache, an uploads tree or a fixed port stays shared between every
worktree until something provisions a per-worktree copy. That something is
`.jst/bootstrap.sh`, and this task writes it. Why it matters, and how to decide
what to isolate: [Optional: parallel worktrees](../optional-parallel-worktrees.md)
and [Parallel instances](../../parallel-instances/RUNNING-MULTIPLE-COPIES.md).

What the scripts contain depends entirely on the kind of project, so this page
doesn't give you a script. It gives you the contract, the example closest to
your stack, and a task prompt that points the skills back at this page.

## What the task produces

| file | who runs it | when |
| -- | -- | -- |
| `.jst/bootstrap.sh` (POSIX) / `.jst/bootstrap.ps1` (Windows) | `jira-task-executor`, step 1 — automatically, no prompt | once per worktree, each time someone starts work in it |
| `.jst/teardown.sh` | you, by hand — no skill runs it | before `git worktree remove` |

All three are **tracked** files, so every new worktree is born with them. Ship
the `.ps1` twin only if someone on the team runs Windows.

## Pick the example closest to your stack

| your project | start from | what it provisions |
| -- | -- | -- |
| Python / tooling only | [Python toolchain](../../parallel-instances/python.md) | a per-worktree `venv/`, nothing else |
| Frontend SPA | [React / Vite SPA](../../parallel-instances/react.md) | host ports and `node_modules` |
| Services with state | [Multi-service docker-compose](../../parallel-instances/docker-compose.md) | network, database, media, certificates |

The annotated example pair
[`bootstrap.example.sh`](../../examples/bootstrap.example.sh) /
[`bootstrap.example.ps1`](../../examples/bootstrap.example.ps1) is modelled on
the docker-compose case. Take the shape from these, not the values.

## The contract, in brief

The executor exports five variables before it runs the hook:

| variable | value |
| -- | -- |
| `JST_ISSUE_KEY` | the issue key derived from the branch, e.g. `PROJ-402` |
| `JST_WORKTREE_DIR` | absolute path of this worktree's root |
| `JST_BRANCH` | the current branch, e.g. `feature/PROJ-402-some-slug` |
| `JST_PARENT_BRANCH` | the PR base from `git config branch.<branch>.parentbranch`; empty when unset |
| `JST_PROJECT_KEY` | `PROJECT_KEY` from `.jst/jira-sdlc-tools.env` |

Four rules make a hook that holds up:

1. **Fail-soft.** A non-zero exit is reported and the executor carries on.
   Exit non-zero to mean "this worktree isn't runnable yet", and print how to
   finish the job by hand.
2. **Idempotent.** A re-run of the executor re-runs the hook. Write every step
   as create-if-missing or reuse.
3. **Deterministic instance index.** Derive ports, container names and data
   directories from one index computed from `JST_ISSUE_KEY`, never from "the
   next free slot", which two worktrees bootstrapping at once would race for.
   Index 0 is the main checkout.
4. **Runnable by hand.** Give each variable a fallback equivalent to it, so you
   can debug the script outside the executor. For `JST_ISSUE_KEY`, extract the
   key from the branch name rather than using the whole branch.

Teardown undoes what bootstrap provisioned. In the worked examples, both scripts
refuse to run in the main checkout, which holds the originals the copies were
made from — copy that guard.

Full details:
[Setting it up — the worktree hook](../../parallel-instances/RUNNING-MULTIPLE-COPIES.md#setting-it-up--the-worktree-hook)
and
[`project-config.md` → the optional worktree hook](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md#jstbootstrapsh--jstbootstrapps1--the-optional-worktree-hook).

## Done when

- statuscheck's `bootstrap` row reports the script as present (it is INFO
  either way and never blocks).
- Running `.jst/bootstrap.sh` twice in a fresh worktree succeeds both times,
  and the second run changes nothing.
- Two worktrees can run their apps side by side without sharing the state you
  chose to isolate.
- `.jst/teardown.sh` removes what bootstrap created and refuses to run in the
  main checkout.

## Task prompt

Paste this into your coding assistant from the main checkout. It names this page
so the executor works from the contract rather than rediscovering it:

```text
/jira-sdlc:jira-task-assigner "Add .jst/bootstrap.sh and .jst/teardown.sh so
several worktrees of this project can run at the same time. Follow
https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/add-bootstrap-and-teardown-scripts
— the JST_* environment contract, fail-soft and idempotent, a deterministic
instance index from JST_ISSUE_KEY with 0 reserved for the main checkout — and
start from the worked example closest to this stack. Decide which state to
isolate per worktree (database, cache, storage, ports) and record that decision
in the script's header comment. Add .jst/bootstrap.ps1 only if the team uses
Windows."
```
