# Task Lifecycle — Phase 2: Implement

The implementation phase of [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md), run
by the **`jira-task-executor`** skill. Triggered **once per leaf
issue**, from inside its dedicated—or shared parent—worktree. Multiple
executors run in parallel against the worktrees the assigner set up.

## Sequence diagram

```mermaid
sequenceDiagram
    actor User
    participant Executor

    Note over User,Executor: Phase 2 — Implement<br/>(one Executor per leaf issue, runs in parallel worktrees)

    par in separate worktrees
        User->>Executor: invoke /jira-task-executor <KEY-A>
        activate Executor
        Executor->>Executor: fetch issue + read Git strategy comment
        Executor->>Executor: branch / worktree setup
        Executor->>Executor: transition → In Progress
        Executor->>Executor: investigate • clarify • implement • test

        alt Dedicated branch
            Executor->>Executor: commit + push + open PR (with semver label)
            Executor->>Executor: transition → In Review
            Executor-->>User: report (PR URL, branch, status)
        else Smart commit
            Executor->>Executor: commit "<KEY-A> #done <msg>" on parent branch (local)
            Executor-->>User: report (commit on parent branch)
        end
        deactivate Executor
    and
        User->>Executor: invoke /jira-task-executor <KEY-B>
        activate Executor
        Executor->>Executor: same flow as KEY-A (in parallel)
        deactivate Executor
    and
        User->>Executor: invoke /jira-task-executor <KEY-C> (smart commit)
        activate Executor
        Executor->>Executor: see "smart commit on parent branch"<br/>stay in parent worktree, no new branch
        Executor->>Executor: commit "<KEY-C> #done <msg>" (local)
        Executor-->>User: report (commit on parent branch)
        deactivate Executor
    end
```

## What the diagram shows

- **Parallel lanes** — the `par / and / and / end` block encodes the
  worktree-level parallelism that the assigner's phase 1 setup makes
  possible. Each lane is a separate executor invocation with its own
  worktree.
- **Branch of two paths** — the executor reads the `Git strategy:`
  comment and follows one of two shapes:
  - **Dedicated branch** (default): commit on its own branch, push,
    open a PR (with a required semver label), transition to
    *In Review*. The PR is the thing phase 3 reviews.
  - **Smart commit** (small focused fixes): local commit on the
    parent branch using the `<KEY> #done <msg>` message — no push, no
    PR. GitHub-for-Jira picks up the `#done` and transitions the issue
    straight to *Done* once the parent branch reaches the remote.
- **Status transitions the executor owns** — to *In Progress* on
  start, to *In Review* on PR open (dedicated branch only). Smart
  commits deliberately *stay* at *In Progress* here; the `#done`
  message owns their final transition.
- **Single closing comment** — the executor posts one Jira comment
  per run, not a short "PR opened" earlier in the flow.

## Related

- [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md) — full lifecycle with all four phases
- [jira-task-executor SKILL.md](../skills/jira-task-executor/SKILL.md)
