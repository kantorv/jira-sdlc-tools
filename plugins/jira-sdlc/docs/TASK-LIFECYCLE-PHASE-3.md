# Task Lifecycle — Phase 3: Review & aggregate approval

The review phase of [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md), run by the
**`jira-task-reviewer`** skill. Triggered by the user on the
**parent** issue key after every leaf executor has reported back and
transitioned its issue to `<STATUS_IN_REVIEW>`.

The reviewer handles **both** single-step top-level issues (no sub-tasks)
and multistep parents (with sub-tasks). For single-step, it reviews the
one PR and posts a final report — no re-run needed (GitHub-for-Jira
auto-transitions the issue to `<STATUS_DONE>` on merge). For multistep,
it reviews each sub-task PR, finds or creates the aggregate parent PR
once sub-tasks are merged, and reviews that too. The reviewer never
merges anything — that remains the user's deliberate step.

The diagram surfaces the two systems the reviewer drives as their own
swimlanes — **GIT** (anything that mutates or reads repo/PR state:
`git fetch --prune`, resolving the parent/base branches from the
`branch.<PARENT-BRANCH>.parentbranch` git config that the assigner
wrote in phase 1, the phase-check `gh pr list`, fetching PR diffs, `gh
pr review --comment --body-file` with `APPROVED —` / `CHANGES REQUESTED —`
body-prefix verdicts, finding the aggregate parent PR) and **JIRA**
(anything that mutates issue state: fetching parent + In-Review
sub-tasks, each rejected sub-task → In Progress transition,
multi-line comments on the reviewed issue after every verdict, the
per-sub-task summary comment on the parent, the aggregate parent PR
review, and every report comment posted on the parent) — so the full
interaction reads `User ↔ Reviewer ↔ GIT ↔ JIRA` left to right.

## Sequence diagram

```mermaid
sequenceDiagram
    actor User
    participant Reviewer
    participant GIT
    participant JIRA

    Note over User,JIRA: Phase 3 — Review & aggregate approval<br/>(parent key only; single-step or multistep)
    User->>Reviewer: invoke /jira-task-reviewer <PARENT-KEY>

    activate Reviewer
    Reviewer->>GIT: git fetch origin --prune
    Reviewer->>JIRA: fetch parent + sub-tasks from Jira<br/>(determine track: single-step vs multistep)
    JIRA-->>Reviewer: issue type, track (single-step | multistep)
    Reviewer->>GIT: resolve <PARENT-BRANCH> + <BASE_BRANCH><br/>(grep + parentbranch config)
    Reviewer->>GIT: phase check — list PR (state all)
    GIT-->>Reviewer: PR state (none | open | merged)

    alt Single-step — PR open (first run)
        Note over Reviewer: single-step: one PR in the set → review loop (step 3)
        Reviewer->>GIT: fetch PR diff
        GIT-->>Reviewer: diff
        Reviewer->>Reviewer: review 6 dimensions<br/>(correctness • patterns • scope<br/>regressions • tests • hygiene)

        alt APPROVE
            Reviewer->>GIT: gh pr review --comment --body-file<br/>"APPROVED — <summary>"
            Reviewer->>JIRA: comment (<PARENT-KEY>)<br/>"PR reviewed and approved"
            Reviewer->>JIRA: post final report on <PARENT-KEY><br/>(S-APPROVED block, step 7)
            Reviewer-->>User: "approved — merge manually<br/>GitHub-for-Jira handles Done, no re-run needed"
        else REQUEST_CHANGES
            Reviewer->>GIT: gh pr review --comment --body-file<br/>"CHANGES REQUESTED — <findings>"
            Reviewer->>JIRA: transition <PARENT-KEY> → <STATUS_IN_PROGRESS>
            Reviewer->>JIRA: comment (<PARENT-KEY>)<br/>"PR failed review, findings:..."
            Reviewer-->>User: "changes requested — fix, push & re-run"
        end

    else Single-step — PR merged (re-run, optional)
        Note over Reviewer: post-merge wrap-up (step 6)<br/>optional historical record — GitHub-for-Jira<br/>already handled the Done transition
        Reviewer->>JIRA: post wrap-up comment on <PARENT-KEY>
        Reviewer-->>User: "merged — complete (S-MERGED)"

    else Multistep — no parent PR yet (first pass)
        loop per sub-task PR (In Review, sequential, one pass)
            Reviewer->>GIT: fetch PR diff
            GIT-->>Reviewer: diff
            Reviewer->>Reviewer: review 6 dimensions<br/>(correctness • patterns • scope<br/>regressions • tests • hygiene)

            alt APPROVE
                Reviewer->>GIT: gh pr review --comment --body-file<br/>"APPROVED — <summary>"
                Reviewer->>JIRA: comment (<SUBTASK-KEY>)<br/>"PR reviewed and approved"
                Reviewer->>JIRA: update summary on <PARENT-KEY><br/>"Sub-task <KEY>: ✅ approved"
            else REQUEST_CHANGES
                Reviewer->>GIT: gh pr review --comment --body-file<br/>"CHANGES REQUESTED — <findings>"
                Reviewer->>JIRA: transition <SUBTASK-KEY> → <STATUS_IN_PROGRESS>
                Reviewer->>JIRA: comment (<SUBTASK-KEY>)<br/>"Findings: ...<br/>Moving back to In Progress."
                Reviewer->>JIRA: update summary on <PARENT-KEY><br/>"Sub-task <KEY>: ❌ changes requested"
                Note over Reviewer: continue to next sub-task PR
            end
        end

        Note over Reviewer: all sub-task PRs visited
        alt All approved and all already merged
            Reviewer->>GIT: find or create parent PR<br/>(<PARENT-BRANCH> → <BASE_BRANCH>)
            GIT-->>Reviewer: parent PR (open)
            Reviewer->>GIT: fetch aggregate diff
            GIT-->>Reviewer: aggregate diff
            Reviewer->>Reviewer: review aggregate diff (lighter pass)
            Reviewer->>GIT: gh pr review --comment --body-file<br/>"APPROVED — <summary>" (no auto-merge — manual)
            Reviewer->>JIRA: post report on <PARENT-KEY><br/>(parent PR ready for manual merge)
            Reviewer-->>User: "parent PR reviewed and approved — merge manually & re-run"
        else All approved, some not yet merged
            Reviewer->>JIRA: post report on <PARENT-KEY><br/>(all approved, waiting for merge)
            Reviewer-->>User: "all approved — merge manually, then re-run to pick up parent PR"
        else Some rejected (changes requested)
            Reviewer->>JIRA: post full report on <PARENT-KEY><br/>(approved + rejected list)
            Reviewer-->>User: "some PRs blocked — fix & re-run"
        end

    else Multistep — parent PR open (re-run while open)
        Note over Reviewer: sub-tasks already merged<br/>(refresh the aggregate review)
        Reviewer->>GIT: refresh parent PR state + aggregate diff
        GIT-->>Reviewer: parent PR open + aggregate diff
        Reviewer->>Reviewer: refresh aggregate review (lighter pass)<br/>skip if already approved (APPROVED — prefix)
        Reviewer->>GIT: gh pr review --comment --body-file<br/>"APPROVED — <summary>"
        Reviewer->>JIRA: post status-refresh comment on <PARENT-KEY><br/>"Parent PR still open, review confirmed."
        Reviewer-->>User: "parent PR reviewed and approved — merge manually"

    else Multistep — parent PR merged (re-run wrap-up)
        Note over Reviewer: post-merge wrap-up (step 6)
        Reviewer->>JIRA: post wrap-up comment (sub-task summary) on <PARENT-KEY><br/>(GitHub-for-Jira handled the status → Done)
        Reviewer->>GIT: git fetch origin (refresh refs, list orphaned branches)
        Reviewer-->>User: "fully complete — all PRs merged"
    end
    deactivate Reviewer
```

## What the diagram shows

- **Two tracks, one skill** — step 1 determines the track from
  `fields.subtasks`: empty → **single-step** (the PR set is the one parent
  PR), non-empty → **multistep** (the PR set is each In Review sub-task
  PR). Each track walks its own branches from the same phase check; the
  review-loop body (step 3) is identical — only the PR set and the
  post-loop outcomes differ.
- **Participant routing** — the reviewer orchestrates three parties.
  **GIT** owns repo/PR state: the opening fetch, resolving
  `<PARENT-BRANCH>` + `<BASE_BRANCH>` (the latter read from the
  `parentbranch` git config the assigner wrote in phase 1 — the
  phase-1 → phase-3 thread), the phase-check `gh pr list`, fetching PR
  diffs, the verdict comment (`gh pr review --comment --body-file`), and
  finding the aggregate parent PR. **JIRA** owns issue state: fetching
  the parent + sub-tasks (filtering to `<STATUS_IN_REVIEW>`), each
  rejected issue → In Progress transition with its findings comment, and
  the summary/report comments posted on the parent after every review.
- **Parent-only, refuses sub-task keys** — the reviewer is triggered on
  the parent key; a sub-task key is rejected. A top-level issue with
  no sub-tasks follows the single-step track (review the one PR directly
  into `<BASE_BRANCH>`).
- **Phase check first** — visible as an explicit GIT `gh pr list`
  whose return dispatches the branches: *no* PR means a full review pass,
  an *open* PR skips straight to review (single-step) or the aggregate
  review (multistep), a *merged* PR short-circuits to the post-merge
  wrap-up (step 6 — optional for single-step, where GitHub-for-Jira
  already handled `<STATUS_DONE>`).
- **Both verdicts go through `--comment --body-file`** — in this plugin's
  default deployment the executor and reviewer share one `gh` account, and
  GitHub blocks an author from approving *or* requesting changes on their
  own PR. Both verdicts are recorded as review comments with the decision
  in their body prefix (`APPROVED — …` / `CHANGES REQUESTED — …`). The
  Jira transition to `<STATUS_IN_PROGRESS>` (reject path) is the actual
  workflow gate; the GitHub comment records findings and makes the verdict
  machine-detectable by the idempotency check (step 3a).
- **Single-step is one-and-done** — on the single-step track, approval
  posts the final report immediately (S-APPROVED outcome, step 7).
  GitHub-for-Jira auto-transitions the issue to `<STATUS_DONE>` when the
  user merges; no reviewer re-run is required. Only the
  S-CHANGES-REQUESTED outcome (reject) needs a re-run after fixes.
- **Single pass, no merge cascade** — each In Review sub-task PR is
  reviewed **in order, one at a time**. The verdict happens
  immediately per-PR. There is no separate "batch merge" step; approved
  PRs are left for the human to merge manually, and rejected items keep
  the loop going so the full state is known. The only thing that stops
  the loop is running out of sub-task PRs.
- **Continue on rejection, don't stop** — when a PR fails the review,
  the reviewer posts the `CHANGES REQUESTED —` verdict comment, transitions
  that issue back to `<STATUS_IN_PROGRESS>`, **records it as blocked**, and
  continues to the next sub-task. After every single PR (approved or
  rejected), a short summary comment is posted on the parent so the human
  can see progress in real time (intentional audit trail). The final
  report at the end (step 7) lists both approved and rejected items so the
  fix-and-re-run cycle is clear.
- **Parent PR: review and approve, still never merge (multistep only)** —
  the reviewer reviews the lighter aggregate diff (GIT) and approves the
  parent PR (`gh pr review --comment --body-file`, GIT). It explicitly
  does *not* call `gh pr merge` on the parent — merging the parent branch
  into `<BASE_BRANCH>` is the human release decision. After the parent PR
  merges, a re-run posts the final wrap-up comment (step 6) listing all
  sub-tasks that contributed (optional — GitHub-for-Jira already handled
  `<STATUS_DONE>`).
- **Automated status transitions removed** — the reviewer no longer moves
  issues to Done on merge (GitHub-for-Jira automation handles that) and
  no longer moves the parent to Done. Transitions that the reviewer still
  performs: rejected issue → In Progress.
- **Every terminal branch posts a JIRA report comment on the parent**
  — per step 7, the report goes to chat *and* as a single Jira comment
  on `<PARENT-KEY>` in all branches: the single-step approve/reject
  reports, the "all approved, merge manually" report, the "some rejected,
  fix and re-run" report, the parent-ready report, the status-refresh
  report (re-run while open), and the wrap-up report (post-merge).

## Related

- [TASK-LIFECYCLE.md](TASK-LIFECYCLE.md) — full lifecycle with all phases
- [jira-task-reviewer SKILL.md](../skills/jira-task-reviewer/SKILL.md)