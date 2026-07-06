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

    Note over User,Executor: Phase 2 — Implement<br/>(one Executor per leaf)

    par dedicated-branch leaves — own worktree each (truly parallel)
        User->>Executor: invoke /jira-task-executor <KEY-A>
        activate Executor
        Executor->>Executor: fetch issue + read Git strategy comment
        Executor->>Executor: validate worktree belongs to <KEY-A> (else stop & ask)
        Executor->>Executor: branch / worktree setup (resume or create)
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
    and dedicated-branch leaf (same flow, in parallel)
        User->>Executor: invoke /jira-task-executor <KEY-B>
        activate Executor
        Executor->>Executor: same flow as KEY-A (in parallel)
        deactivate Executor
    and smart-commit leaves — share the parent worktree (must run serially)
        User->>Executor: invoke /jira-task-executor <KEY-C>
        activate Executor
        Executor->>Executor: see "smart commit on parent branch"<br/>stay in parent worktree, no new branch
        Executor->>Executor: commit "<KEY-C> #done <msg>" (local, no push)
        Executor-->>User: report (commit on parent branch)
        deactivate Executor
    end
```

## What the diagram shows

- **Parallel lanes** — the `par / and / and / end` block encodes the
  worktree-level parallelism the assigner's phase 1 setup makes
  possible. **Dedicated-branch leaves each have their own worktree**
  and can run concurrently; **smart-commit leaves share the parent
  worktree**, so two smart-commit invocations must run serially (they'd
  collide in the same working tree).
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
- **Guards before work starts** — the executor validates that its
  worktree actually belongs to `<KEY>` (or its parent family) before
  doing anything, and if `<KEY>` turns out to be a multistep parent it
  asks the user to confirm rather than silently implementing on it.

## Related

- [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md) — full lifecycle with all four phases
- [jira-task-executor SKILL.md](../skills/jira-task-executor/SKILL.md)
