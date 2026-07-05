# Task Lifecycle — Phase 1: Plan

The planning phase of [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md), run by the
**`jira-task-assigner`** skill. Triggered once per task, **must be
invoked from the default base branch** (the assigner refuses to run on
an existing feature/hotfix branch).

This phase ends when the assigner reports back: issues exist, branches
and worktrees are ready, and `"PR target branch: ..."` plus
`"Git strategy: ..."` comments are posted on every leaf issue for the
next phase to read.

## Sequence diagram

```mermaid
sequenceDiagram
    actor User
    participant Assigner

    Note over User,Assigner: Phase 1 — Plan<br/>(runs once, must be invoked from base branch)
    User->>Assigner: invoke /jira-task-assigner "<task description>"

    activate Assigner
    Assigner->>Assigner: check branch context (must be base branch)
    Assigner->>Assigner: investigate codebase

    loop clarify until scope/types settled
        Assigner->>User: ask clarifying questions (scope, AC, priority...)
        User-->>Assigner: answers
    end

    Assigner->>Assigner: decide scope (single-step vs multistep)<br/>+ top-level type (Task / Story / Bug)<br/>+ per-sub-task strategy (dedicated branch / smart commit)

    alt Multistep (split into parallel sub-tasks)
        Assigner->>Assigner: create <PARENT-KEY> (Task / Story / Bug)
        Assigner->>Assigner: create branch feature/<PARENT-KEY>-<slug><br/>+ create parent worktree (home for smart-commit work)
        loop per sub-task
            alt Dedicated branch (default)
                Assigner->>Assigner: create sub-task issue<br/>+ sub-task branch & worktree
            else Smart commit (small focused fix)
                Assigner->>Assigner: create sub-task issue<br/>(no branch — uses parent worktree)
            end
            Assigner->>Assigner: post "PR target branch" + "Git strategy" comments
        end
    else Single-step (one cohesive task)
        Assigner->>Assigner: create single top-level issue<br/>+ branch + worktree
        Assigner->>Assigner: post "PR target branch" + "Git strategy" comments
    end
    deactivate Assigner

    Assigner-->>User: report (keys, branches, worktrees, strategy)
```

## What the diagram shows

- **Investigate + clarify loop** — the only place the user is asked
  anything by `jira-task-assigner`; questions persist until scope,
  acceptance criteria, and priority are settled.
- **One decision point** that admits three dimensions at once
  (`alt Multistep / else Single-step`, with another nested
  `alt Dedicated branch / else Smart commit` per leaf): whether the
  request is single-step, how to type the top-level issue, and how each
  sub-task should land in git.
- **Provisioning is uniform** — *every* scenario (single-step,
  multistep parent, dedicated-branch sub-task, smart-commit sub-task)
  ends with the assigner posting the `PR target branch` and
  `Git strategy` comments that the executor and reviewer will read
  later as their durable source of truth.

The assigner deliberately stops short of writing any code, commits, or
PRs — those are phase 2's job.

## Related

- [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md) — full lifecycle with all four phases
- [jira-task-assigner SKILL.md](../skills/jira-task-assigner/SKILL.md)
