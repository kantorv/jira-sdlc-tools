# Task Lifecycle — Phase 1: Plan

The planning phase of [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md), run by the
**`jira-task-assigner`** skill. Triggered once per task, **invoked from
the default base branch** — the assigner refuses to run on an existing
`feature/`/`hotfix/` issue branch, and asks the user how to proceed on
any other non-base branch.

This phase ends when the assigner reports back: issues exist, branches
and worktrees are ready, and a single
`"PR target branch: ... Worktree: ..."` comment is posted on every
leaf issue for the next phase to read.

## Sequence diagram

```mermaid
sequenceDiagram
    actor User
    participant Assigner

    Note over User,Assigner: Phase 1 — Plan<br/>(runs once, from the base branch)
    User->>Assigner: invoke /jira-task-assigner "<task description>"

    activate Assigner
    Assigner->>Assigner: check branch context (base ok, feature/hotfix stop, ask otherwise)
    Assigner->>Assigner: investigate codebase

    loop clarify until scope/types settled
        Assigner->>User: ask clarifying questions (scope, AC, priority...)
        User-->>Assigner: answers
    end

    Assigner->>Assigner: decide scope (single-step vs multistep)<br/>+ top-level type (Task / Story / Bug)

    alt Multistep (split into parallel sub-tasks)
        Assigner->>Assigner: create <PARENT-KEY> (Task / Story / Bug)
        Assigner->>Assigner: create branch feature/<PARENT-KEY>-<slug><br/>+ set parentbranch config + push + parent worktree
        loop per sub-task
            Assigner->>Assigner: create sub-task issue + branch & worktree<br/>+ set parentbranch config + push
            Assigner->>Assigner: post "PR target branch: ... Worktree: ..." comment
        end
    else Single-step (one cohesive task)
        Assigner->>Assigner: create single top-level issue + branch<br/>+ set parentbranch config + push + worktree
        Assigner->>Assigner: post "PR target branch: ... Worktree: ..." comment
    end
    deactivate Assigner

    Assigner-->>User: report (keys, branches, worktrees, strategy)
```

## What the diagram shows

- **Investigate + clarify loop** — the only place the user is asked
  anything by `jira-task-assigner`; questions persist until scope,
  acceptance criteria, and priority are settled.
- **Scope decision first** — the assigner settles scope and the
  top-level type (`alt Multistep / else Single-step`); inside the
  multistep loop it creates each sub-task's branch + worktree uniformly.
- **Provisioning is uniform** — *every* scenario (single-step,
  multistep parent, sub-task) records `branch.<branch>.parentbranch`
  in git config, pushes the branch to the remote, and ends with the
  assigner posting a single `PR target branch: ... Worktree: ...`
  comment that the executor and reviewer will read later as the durable
  source of truth.

The assigner deliberately stops short of writing any code, commits, or
PRs — those are phase 2's job.

## Related

- [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md) — full lifecycle with all four phases
- [jira-task-assigner SKILL.md](../skills/jira-task-assigner/SKILL.md)
