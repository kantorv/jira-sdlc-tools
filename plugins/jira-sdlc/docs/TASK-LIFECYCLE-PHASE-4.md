# Task Lifecycle — Phase 4: Human merge + re-run wrap-up

The release phase of [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md). This phase
is deliberately the **only step that stays human** in the cascade: the
sub-task PRs and the parent PR are *never* auto-merged by the reviewer.
The user merges each approved PR on GitHub, then re-invokes the
reviewer so it can pick up the merged state and close out the parent
issue.

The diagram surfaces the two systems this phase drives as their own
swimlanes — **GIT** (the manual GitHub merge that *the user* performs
directly, the reviewer's phase-check `gh pr list` that detects
`state == MERGED`, and the cleanup-time orphan-local-branch listing)
and **JIRA** (the final wrap-up comment on the parent — GitHub-for-Jira
automation has already transitioned all related issues to Done via the PR
merge) — so the full interaction reads `User ↔ Reviewer ↔ GIT ↔ JIRA`
left to right, with one defining quirk: this is the only phase where
the user's arrow reaches past the reviewer straight to GIT.

## Sequence diagram

```mermaid
sequenceDiagram
    actor User
    participant Reviewer
    participant GIT
    participant JIRA

    Note over User,JIRA: Phase 4 — Human merge + re-run wrap-up<br/>(always manual — heaviest release decision)
    User->>GIT: merge sub-task PR(s) on GitHub<br/>(manual — the human's step)
    User->>GIT: merge parent PR on GitHub<br/>(manual — the human's step)
    User->>Reviewer: re-invoke /jira-task-reviewer <PARENT-KEY>

    activate Reviewer
    Reviewer->>GIT: git fetch --prune, then phase-check<br/>(list parent PR, state all)
    GIT-->>Reviewer: parent PR state == MERGED
    Note right of Reviewer: short-circuit — skip sub-task cascade<br/>(step 1 dispatches to post-merge wrap-up)
    Reviewer->>JIRA: post final wrap-up comment on <PARENT-KEY><br/>(what landed, sub-tasks that contributed)
    Note right of Reviewer: GitHub-for-Jira already handled<br/>all status transitions → Done
    Reviewer->>GIT: list orphaned local branches<br/>(git branch --merged origin/<BASE_BRANCH>)
    GIT-->>Reviewer: orphaned branch list
    deactivate Reviewer

    Reviewer-->>User: final report (everything landed, cleanup hints)
```

## What the diagram shows

- **Participant routing** — phase 4's defining trait is that the *only*
  GIT mutation in this phase is made by the user, not the reviewer: the
  manual GitHub merge is drawn as `User → GIT`, jumping over the
  reviewer (the only such arrow in the whole four-phase sequence). The
  reviewer's re-run is book-keeping only — one JIRA write (the final
  wrap-up comment), one GIT read up front (the phase-check `gh pr list`
  that detects `MERGED`), and one GIT read at the end (the
  orphan-local-branch list). No GIT or JIRA writes originate from the
  reviewer here.
- **The handover** — phase 3 ended with `gh pr review --approve` on the
  parent PR, not `gh pr merge`. This phase starts with the user merging
  sub-tasks and then the parent PR themselves on GitHub (`User → GIT`,
  manual). The assignment is deliberately arranged this way (see the
  **Safety model** section of [README.md](../README.md)): the heaviest
  release decision in the cascade stays human.
- **Automation handles Done transitions** — GitHub-for-Jira automation
  transitions all related issues to Done automatically when the PR is
  merged. The reviewer no longer performs any Jira status transitions in
  this phase. The final wrap-up comment posted on the parent (JIRA) is
  for historical record and completeness only.
- **Phase detection on re-invoke** — when the reviewer is re-invoked
  here, re-running phase 3's step 1, its phase check sees
  `state == MERGED` via GIT and short-circuits straight to the wrap-up
  (step 6), never re-running the sub-task review cascade.
- **Skipped transitions are intentional** — note that in this phase no
  executor or reviewer touches a *remote* directly anymore; the only
  remote action is the user's manual merge (`User → GIT`). The
  reviewer's remaining work is book-keeping.

This phase is also the lifetime of `<PARENT-KEY>` on the board: it
entered at *In Review* when the executor created the first sub-task PR,
and exits at *Done* when the PRs are merged (and optionally re-confirmed
by the reviewer's re-invocation).

**Single-step top-level issues skip phases 3 and 4's reviewer wrap-up
entirely.** There's no parent-PR cascade and no reviewer re-run: the
user merges the one PR directly into `<BASE_BRANCH>`, and
GitHub-for-Jira's merge automation (or a manual `acli jira workitem transition`)
takes the issue to *Done*.

## Related

- [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md) — full lifecycle with all four phases
- [jira-task-reviewer SKILL.md](../skills/jira-task-reviewer/SKILL.md)
