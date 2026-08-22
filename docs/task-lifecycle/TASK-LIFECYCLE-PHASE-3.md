---
slug: /task-lifecycle-phase-3
sidebar_position: 4
sidebar_label: Phase 3 · Review
---

# Task Lifecycle — Phase 3: Review & aggregate approval

Phase 3 of the task lifecycle, run by the **`jira-task-reviewer`** skill.
Triggered from an issue's own worktree (branch-derived key, no key
argument) after every leaf executor has reported back and transitioned
its issue to `<STATUS_IN_REVIEW>`.

**Scope is set by the worktree you stand in**, and there are three entry
shapes, not two. From the **parent's** worktree the reviewer handles both
single-step top-level issues (no sub-tasks) and multistep parents (with
sub-tasks): for single-step it reviews the one PR and posts a final report
— no re-run needed (GitHub-for-Jira auto-transitions the issue to
`<STATUS_DONE>` on merge); for multistep it reviews each sub-task PR, finds
or creates the aggregate parent PR once sub-tasks are merged, and reviews
that too. From a **sub-task's own** worktree it reviews *that sub-task's PR
and nothing else* — no sibling, no parent PR, and no track determined; a
full pass is then a separate run from the parent's worktree. The reviewer
never merges anything — that remains the user's deliberate step. When a run
approved anything, its last step (7) asks whether to move those issues to
`<STATUS_DONE>` and transitions only what the user says yes to.

The diagram surfaces the two systems the reviewer drives as their own
swimlanes — **GIT** (anything that mutates or reads repo/PR state:
`git fetch origin --prune`, the anchored `git branch -a --list` that finds
`<PARENT-BRANCH>`, resolving this skill's own GitHub identity with
`gh api user`, the phase-check `gh pr list`, the per-PR `3a`
idempotency lookup, fetching PR diffs, the step-4a per-PR merge-state
lookup, `gh pr review --comment --body-file` with `APPROVED —` / `CHANGES REQUESTED —` body-prefix
verdicts, and finding, mergeability-checking, or creating the aggregate
parent PR) and **JIRA**
(anything that mutates issue state: fetching the parent and then *every*
sub-task — the `<STATUS_IN_REVIEW>` ones become the PR set, but all statuses
are kept — reading `fields.parent.key` off a sub-task's own fetch to reach
its parent, each rejected issue → In Progress transition (a sub-task on the
multistep track, `<PARENT-KEY>` itself on single-step), multi-line comments on the reviewed
issue after every verdict, the per-sub-task summary comment on the
parent, every report comment posted on the parent, and the step-7
user-approved → Done transitions) — so the full
interaction reads `User ↔ Reviewer ↔ GIT ↔ JIRA` left to right. The two
pre-flight scripts (`ensure_local_env`, `statuscheck`) and `pr_base.sh` are
drawn as self-calls because they **neither mutate GIT nor JIRA state** — not
because they stay local. Only `ensure_local_env` does: the
healthcheck *probes* both credentials over the network (`GET /myself` for
Jira, `GET /repos/…` for GitHub), and `pr_base.sh`'s second source is the
issue's own `PR target branch:` **Jira comment**. Read-only of *those two
systems*, not of the machine: `statuscheck.sh` also re-logs `gh` in from the
stored PAT (`gh auth logout`, then `gh auth login --with-token`), a
deliberate local mutation that exists so a stale read-only token can't 403 at
`gh pr create` later.

## Sequence diagram

```mermaid
sequenceDiagram
    actor User
    participant Reviewer
    participant GIT
    participant JIRA

    Note over User,JIRA: Phase 3 — Review & aggregate approval<br/>(scope follows the worktree — parent single-step, parent multistep, or one sub-task)
    User->>Reviewer: cd worktree-<PARENT-KEY>, invoke /jira-task-reviewer (no key arg)

    activate Reviewer
    Reviewer->>Reviewer: Pre-step — ensure_local_env.sh<br/>(credentials file exists — there is no login step)
    Reviewer->>Reviewer: Pre-step — Discovery & healthcheck<br/>statuscheck.sh --role reviewer<br/>(worktree · branch · issue_key · parent_branch · gh_auth ·<br/>jira_auth probes the reviewer credential — any FAIL → stop)
    Note right of Reviewer: not a linked worktree, or not a feature/ or hotfix/ issue branch → stop.<br/>Every verdict comment + reject transition below<br/>authenticates per-request as the reviewer
    Reviewer->>GIT: Step 1 — git fetch origin --prune
    Reviewer->>JIRA: Step 1 — fetch issue from branch key<br/>(summary, description, type, status, parent, subtasks — never comment)
    JIRA-->>Reviewer: issue fields
    opt branch key is a Subtask — run from a sub-task's own worktree
        Note over Reviewer,JIRA: Different run shape — scope is that ONE sub-task PR.<br/>fields.parent.key is read only to resolve <PARENT-BRANCH> (the PR's base)<br/>via pr_base.sh --parent-key · the parent is never re-fetched as an acting issue ·<br/>fields.subtasks is never read · no track is determined · the parent PR is never touched
        Note over Reviewer: walk: step 2 (this sub-task alone) → 3 → 6 → 7, then the run ends.<br/>A full pass is a separate run from the parent's worktree — the rest of this diagram
    end
    Reviewer->>GIT: Step 1 — resolve <PARENT-BRANCH><br/>(git branch -a --list globs, anchored on the key)
    GIT-->>Reviewer: exactly one branch (zero or several → ask the user)
    Reviewer->>Reviewer: Step 1 — resolve <BASE_BRANCH><br/>pr_base.sh --role reviewer --branch <PARENT-BRANCH><br/>(never --parent-key here — it would match <PARENT-BRANCH><br/>itself and open the parent PR into itself)
    Note right of Reviewer: source=env-default → proceed but flag it · unresolved → ask ·<br/>a hotfix/ <PARENT-BRANCH> resolving to the staging base means the env<br/>default fired on a production fix → stop and ask which base is right
    Note over Reviewer: Step 1 — determine track from fields.subtasks<br/>(empty → single-step · non-empty → multistep)
    opt multistep — fetch every sub-task's status
        Reviewer->>JIRA: Step 1 — issue view per sub-task key
        JIRA-->>Reviewer: statuses — the PR set is the <STATUS_IN_REVIEW> ones,<br/>but every status is kept: the phase check reads the whole set<br/>to tell "still in flight" from "all merged"
    end
    Reviewer->>GIT: Step 1 — phase check — gh pr list (state all)
    GIT-->>Reviewer: PR state (none | open | merged | closed-unmerged)
    Note over Reviewer: both phase checks share two rules — several PRs back → act on the OPEN one<br/>(several open → ask which) · a CLOSED, unmerged PR matches no enumerated state,<br/>so stop and ask: someone abandoned this branch's PR deliberately, and both<br/>opening a replacement and reviewing a dead one would guess at intent

    Note over Reviewer: <SELF> — this skill's GitHub identity — is resolved ONCE per run,<br/>but only on the branches that actually review something. The four exits below that<br/>review nothing (no PR yet · S-MERGED · M-FULLY-COMPLETE · nothing to review)<br/>never reach step 3 and never resolve it. Two branches DO review without entering<br/>step 3 — both every-sub-task-DONE splits below (no parent PR → 5a+5b · open parent<br/>PR → 5b) — so 5b resolves <SELF> itself on each

    alt Single-step — no PR yet
        Note over Reviewer: executor hasn't opened a PR
        Reviewer->>JIRA: Step 6 — post report on <PARENT-KEY><br/>(no PR yet — nothing to review)
        Reviewer-->>User: "no open PR yet — reviewer runs once it exists"

    else Single-step — PR open (first run)
        Note over Reviewer: single-step: the one PR is the whole set → review loop (step 3).<br/>Step 2 is skipped — its PR set is the parent PR itself
        Reviewer->>GIT: Step 3 — gh api user --jq .login → <SELF><br/>(resolved here, at the top of the review loop)
        GIT-->>Reviewer: login
        Note right of Reviewer: gh missing or logged out → report the error and hand back the PR URLs
        Reviewer->>GIT: Step 3a — idempotency: my prior verdict comment on this PR?
        GIT-->>Reviewer: none | "APPROVED —" | "CHANGES REQUESTED —"<br/>(the MOST RECENT verdict wins — a later one supersedes an earlier)
        alt most recent is "APPROVED —" and no re-review requested
            Reviewer->>JIRA: Step 6 — post report on <PARENT-KEY><br/>(already approved — waiting for merge)
            Reviewer-->>User: "already approved — merge manually"
        else none · most recent "CHANGES REQUESTED —" · or $ARGUMENTS forces a re-review
            Reviewer->>GIT: Step 3b — fetch PR diff
            GIT-->>Reviewer: diff
            Reviewer->>Reviewer: Step 3c — review 6 dimensions<br/>(correctness • patterns • scope<br/>regressions • tests • hygiene)
            alt APPROVE
                Reviewer->>GIT: Step 3d — gh pr review --comment --body-file<br/>"APPROVED — <summary>"
                Note right of Reviewer: no Jira post in 3d on this track — 3d's destination and step 6's are<br/>both <PARENT-KEY>, so step 6 is the single Jira record. Step 3e is skipped too
                Reviewer->>JIRA: Step 6 — canonical report on <PARENT-KEY><br/>(S-APPROVED, outcome named in step 4c)
                Reviewer-->>User: "approved — merge manually<br/>GitHub-for-Jira handles Done, no re-run needed"
            else REQUEST_CHANGES
                Reviewer->>GIT: Step 3d — gh pr review --comment --body-file<br/>"CHANGES REQUESTED — <findings>"
                Reviewer->>JIRA: Step 3d — transition <PARENT-KEY> → <STATUS_IN_PROGRESS><br/>(the actual workflow gate — the GitHub comment only records the verdict)
                Reviewer->>JIRA: Step 6 — canonical report on <PARENT-KEY><br/>(S-CHANGES-REQUESTED, outcome named in step 4c)
                Reviewer-->>User: "changes requested — fix, push & re-run"
            end
        end

    else Single-step — PR merged (re-run)
        Note over Reviewer: detect merged PR — GitHub-for-Jira<br/>already handled Done, no wrap-up
        Reviewer->>JIRA: Step 6 — post final report on <PARENT-KEY><br/>(S-MERGED)
        Reviewer-->>User: "merged — complete (S-MERGED)"

    else Multistep — no parent PR yet
        Note over Reviewer: "no parent PR" splits on sub-task status —<br/>EVERY sub-task <STATUS_DONE> → the PRs are already merged and only the<br/>parent PR is missing, so skip to step 5 (the only place it is created) ·<br/>any sub-task not yet <STATUS_DONE> → still in flight, full pass below.<br/>The skip-to-5 route never enters step 3, so 5b resolves <SELF> itself there<br/>— the same as the open-parent-PR path further down
        loop Step 2 — per In Review sub-task: discover branch + PR
            Reviewer->>GIT: git branch -a --list "*feature/<SUBTASK-KEY>-*"<br/>"*hotfix/<SUBTASK-KEY>-*" (anchored, strips the + worktree marker), then<br/>gh pr list --head <subtask-branch> --base <PARENT-BRANCH> --state open
            GIT-->>Reviewer: sub-task branch + open PR (or none)
            Note over Reviewer: no branch / no open PR → flag & skip this sub-task ·<br/>more than one open PR → ask the user which to review
        end
        alt zero sub-tasks have an open PR
            Reviewer->>JIRA: Step 6 — post report on <PARENT-KEY> (nothing to review)
            Reviewer-->>User: "no sub-task PRs to review — re-run later"
        else at least one sub-task PR to review
            Reviewer->>GIT: Step 3 — gh api user --jq .login → <SELF><br/>(resolved once here, before the loop — not per PR)
            GIT-->>Reviewer: login
            loop Step 3 — per sub-task PR (In Review, sequential, one pass)
                Reviewer->>GIT: Step 3a — idempotency: my prior verdict comment on this PR?
                GIT-->>Reviewer: none | "APPROVED —" | "CHANGES REQUESTED —"<br/>(most recent wins)
                alt most recent is "APPROVED —" and no re-review requested
                    Note over Reviewer: record approved, skip re-review → next sub-task PR
                else none · most recent "CHANGES REQUESTED —" · or $ARGUMENTS forces a re-review
                    Reviewer->>GIT: Step 3b — fetch PR diff
                    GIT-->>Reviewer: diff
                    Reviewer->>Reviewer: Step 3c — review 6 dimensions<br/>(correctness • patterns • scope<br/>regressions • tests • hygiene)
                    alt APPROVE
                        Reviewer->>GIT: Step 3d — gh pr review --comment --body-file<br/>"APPROVED — <summary>"
                        Reviewer->>JIRA: Step 3d — canonical report on <SUBTASK-KEY><br/>(M-SUBTASK-APPROVED)
                        Reviewer->>JIRA: Step 3e — the SAME report body again, on <PARENT-KEY><br/>(one fresh comment per sub-task — the intentional audit trail)
                    else REQUEST_CHANGES
                        Reviewer->>GIT: Step 3d — gh pr review --comment --body-file<br/>"CHANGES REQUESTED — <findings>"
                        Reviewer->>JIRA: Step 3d — canonical report on <SUBTASK-KEY><br/>(M-SUBTASK-CHANGES-REQUESTED, with the file:line findings)
                        Reviewer->>JIRA: Step 3d — transition <SUBTASK-KEY> → <STATUS_IN_PROGRESS>
                        Reviewer->>JIRA: Step 3e — the SAME report body again, on <PARENT-KEY>
                        Note over Reviewer: continue to next sub-task PR
                    end
                end
            end

            Note over Reviewer: Step 4 — all sub-task PRs visited
            alt Step 4b — some rejected (changes requested)
                Reviewer->>JIRA: Step 6 — full report on <PARENT-KEY><br/>(M-SOME-BLOCKED: approved + rejected + findings)
                Reviewer-->>User: "some PRs blocked — fix & re-run"
            else Step 4a — all approved
                Reviewer->>GIT: Step 4a — gh pr view --json state, once per PR in the set
                GIT-->>Reviewer: merged | open, per PR
                alt some not yet merged
                    Reviewer->>JIRA: Step 6 — report on <PARENT-KEY><br/>(M-ALL-APPROVED — waiting for merge)
                    Reviewer-->>User: "all approved — merge manually, then re-run for the parent PR"
                else all merged, guard passed → step 5
                    Note over Reviewer: guard: "every PR in the set is merged" is NOT "the feature is complete".<br/>The set only ever held sub-tasks that were <STATUS_IN_REVIEW> at step 1, so any<br/>sub-task not yet <STATUS_DONE> — still in progress, or skipped by step 2 for having<br/>no branch or no PR — stays on M-ALL-APPROVED and goes to step 6 instead.<br/>Otherwise step 5 would open an aggregate PR missing the outstanding work
                    Reviewer->>GIT: Step 5a — find or create parent PR<br/>(<PARENT-BRANCH> → <BASE_BRANCH>, gh pr list --state all)
                    GIT-->>Reviewer: parent PR (open | created | merged | closed)<br/>several back → act on the OPEN one, several open → ask (same rule as step 2)
                    alt parent PR CLOSED
                        Reviewer-->>User: "parent PR is closed — stop, user decides"
                    else parent PR MERGED
                        Reviewer->>JIRA: Step 6 — final report on <PARENT-KEY><br/>(M-FULLY-COMPLETE — 5a is its second detector, after the step-1 phase check)
                        Reviewer-->>User: "fully complete — all PRs merged"
                    else parent PR open or newly created
                        Reviewer->>GIT: Step 5b — 3a idempotency check first,<br/>then gh pr view --json mergeable,mergeStateStatus
                        GIT-->>Reviewer: prior verdict + mergeable state
                        Note right of Reviewer: CONFLICTING → <PARENT-BRANCH> has fallen behind <BASE_BRANCH>.<br/>Stop and report — a diff that cannot merge gives the user nothing to act on.<br/>This is the only detector the "parent branch is behind its base" case has,<br/>and it exits without a step-6 report
                        alt prior verdict is "APPROVED —"
                            Note over Reviewer: skip the re-review — nothing is posted to GitHub
                            Reviewer->>JIRA: Step 6 — report on <PARENT-KEY><br/>(parent PR already reviewed — waiting for manual merge)
                            Reviewer-->>User: "parent PR already approved — merge manually"
                        else none, or "CHANGES REQUESTED —"
                            Reviewer->>GIT: Step 5b — fetch aggregate diff
                            GIT-->>Reviewer: aggregate diff
                            Reviewer->>Reviewer: Step 5b — review aggregate diff (lighter pass — integration focus)
                            alt APPROVE
                                Reviewer->>GIT: Step 5b — gh pr review --comment --body-file<br/>"APPROVED — <summary>" (no auto-merge)
                                Reviewer->>JIRA: Step 6 — report on <PARENT-KEY><br/>(M-PARENT-READY)
                                Reviewer-->>User: "parent PR approved — merge manually"
                            else REQUEST_CHANGES
                                Reviewer->>GIT: Step 5b — gh pr review --comment --body-file<br/>"CHANGES REQUESTED — <findings>"
                                Note right of Reviewer: a parent-PR reject transitions NO Jira issue —<br/>unlike a sub-task reject, <PARENT-KEY> stays as it is
                                Reviewer->>JIRA: Step 6 — report on <PARENT-KEY><br/>(M-PARENT-CHANGES-REQUESTED)
                                Reviewer-->>User: "parent PR changes requested — fix on <PARENT-BRANCH> & re-run"
                            end
                        end
                    end
                end
            end
        end

    else Multistep — parent PR open
        Note over Reviewer: an open parent PR splits on sub-task status too —<br/>EVERY sub-task <STATUS_DONE> → the merges have happened, go straight to 5b below ·<br/>any sub-task not yet <STATUS_DONE> → the parent PR was opened early and the sub-tasks<br/>are still the work, so run the full step-2 pass and leave the parent PR to a later run
        Reviewer->>GIT: Step 5b — gh api user --jq .login → <SELF><br/>(this path skipped step 3, so 5b resolves it itself)
        GIT-->>Reviewer: login
        Reviewer->>GIT: Step 5b — 3a idempotency + mergeable check
        GIT-->>Reviewer: prior verdict + mergeable state
        Note right of Reviewer: CONFLICTING → stop and report, with no step-6 report
        alt prior verdict is "APPROVED —"
            Note over Reviewer: skip the re-review — nothing is posted to GitHub
            Reviewer->>JIRA: Step 6 — report on <PARENT-KEY><br/>(parent PR already reviewed — waiting for manual merge)
            Reviewer-->>User: "parent PR already approved — merge manually"
        else none, or "CHANGES REQUESTED —"
            Reviewer->>GIT: Step 5b — fetch the aggregate diff
            GIT-->>Reviewer: aggregate diff
            Reviewer->>Reviewer: Step 5b — review aggregate diff (lighter pass — integration focus)
            alt APPROVE
                Reviewer->>GIT: Step 5b — gh pr review --comment --body-file<br/>"APPROVED — <summary>"
                Reviewer->>JIRA: Step 6 — report on <PARENT-KEY><br/>(M-PARENT-READY)
                Reviewer-->>User: "parent PR reviewed and approved — merge manually"
            else REQUEST_CHANGES
                Reviewer->>GIT: Step 5b — gh pr review --comment --body-file<br/>"CHANGES REQUESTED — <findings>"
                Reviewer->>JIRA: Step 6 — report on <PARENT-KEY><br/>(M-PARENT-CHANGES-REQUESTED)
                Reviewer-->>User: "parent PR changes requested — fix & re-run"
            end
        end

    else Multistep — parent PR merged (re-run)
        Note over Reviewer: detect merged parent PR — GitHub-for-Jira<br/>handled Done, no wrap-up
        Reviewer->>JIRA: Step 6 — post final report on <PARENT-KEY><br/>(M-FULLY-COMPLETE)
        Reviewer-->>User: "fully complete — all PRs merged"
    end

    opt Step 7 — this run approved something (not the already-merged exits)
        Reviewer->>User: move the approved issues to <STATUS_DONE>?<br/>(names every approved key — asked once)
        User-->>Reviewer: yes (all or some) | no
        Reviewer->>JIRA: transition each approved key → <STATUS_DONE><br/>(only the ones the user said yes to)
        Note over Reviewer,JIRA: declined or non-interactive → nothing moves<br/>merge automation closes them later · no extra Jira comment
    end
    deactivate Reviewer
```

## What the diagram shows

- **Step labelling** — every node carries the step number
  `jira-task-reviewer`'s own `SKILL.md` gives it, sub-steps included
  (`Step 3a`, `Step 5b`). `ensure_local_env.sh` and **Discovery &
  healthcheck run before step 1 and are unnumbered in the skill**, so they
  are labelled `Pre-step` here, exactly as in phase 2. Phase 1 runs the same
  healthcheck but numbers it *its* step 1, so its diagram reads `Step 1 — Discovery & healthcheck`. The step and its name are identical across all
  three phases, and so is the `statuscheck.sh` call apart from its required
  `--role` — `assigner`, `executor` and `reviewer` respectively, since auth is
  role-scoped and the script has no default credential. Only each skill's own
  numbering differs, and the diagrams follow the skill rather than
  renumbering it.
- **Two tracks, three entry shapes, one skill** — from the parent's
  worktree, step 1 determines the track from `fields.subtasks`: empty →
  **single-step** (the PR set is the one parent PR), non-empty →
  **multistep** (the PR set is each In Review sub-task PR). Each track walks
  its own branches from the same phase check. The third entry shape — a run
  from a **sub-task's own** worktree — determines no track at all: its PR set
  is that one sub-task's PR, and it never reaches the phase checks, step 4
  or step 5. In all three the review-loop body (step 3, including its 3a
  idempotency check) is identical — only the PR set and the post-loop
  outcomes differ.
- **Participant routing** — the reviewer orchestrates three parties.
  **GIT** owns repo/PR state: the opening fetch, the anchored
  `git branch -a --list` that resolves `<PARENT-BRANCH>`, the phase-check
  `gh pr list`, the per-PR 3a
  idempotency lookup, fetching PR diffs, step 4a's per-PR
  `gh pr view --json state` merge check, the verdict comment (`gh pr review --comment --body-file`), and finding or creating the aggregate
  parent PR. **JIRA** owns issue state: fetching the parent + sub-tasks
  (every sub-task is fetched and every status kept; `<STATUS_IN_REVIEW>` only
  selects the PR set), climbing from a sub-task branch to
  its parent, each rejected issue → In Progress transition with its
  findings comment — a sub-task on the multistep track, `<PARENT-KEY>` itself
  on the single-step track — and the summary/report comments posted on the parent
  after every review. `<BASE_BRANCH>` sits in neither lane: `pr_base.sh`
  resolves it as a self-call. On *this* call three of its four sources are
  live, in order: the `parentbranch` git config the assigner wrote in phase 1
  — the phase-1 → phase-3 thread — then the issue's `PR target branch:` Jira
  comment, then the env default. The fourth, the parent-branch search, is
  gated on `--parent-key`, which this call deliberately never passes; that is
  what keeps the env default reachable and stops `<BASE_BRANCH>` resolving to
  `<PARENT-BRANCH>`. Phase 2 draws the same script the same way.
- **A sub-task branch does not climb into a full pass** — the reviewer
  derives the key from the current branch (feature/<KEY>-slug or
  hotfix/<KEY>-slug) and `jira.sh` fetches that issue. A top-level issue with
  no sub-tasks follows the single-step track. If the issue is a **Subtask**,
  the run's scope stays that one sub-task's PR: `fields.parent.key` (already
  on the sub-task's own fetch) is read *only* to resolve `<PARENT-BRANCH>`,
  the base its PR targets, via `pr_base.sh --parent-key`. The parent is never
  re-fetched as an acting issue, `fields.subtasks` is never read, no track is
  determined, and the parent PR is never touched — that sweep belongs to a
  separate run from the parent's own worktree. Its walk is step 2 (for this
  one sub-task) → 3 → 6 → 7.
- **Phase check first, and track-aware** — an explicit GIT `gh pr list`
  whose return dispatches the top-level branches. On the **single-step**
  track it has three outcomes: *no* PR → report that the executor hasn't
  opened one yet and exit (nothing to review); an *open* PR → the step-3
  review loop; a *merged* PR → the S-MERGED report and exit. On the
  **multistep** track both the *no parent PR* and the *open parent PR*
  outcomes split further on the **sub-task statuses**, because neither state
  means what it looks like on its own: every sub-task `<STATUS_DONE>` → the
  merges have happened, so skip to step 5 (the only place the parent PR is
  ever created, and where 4a's "merge them manually, then re-run" lands);
  any sub-task not yet `<STATUS_DONE>` → the work is still in flight, so run
  the full step-2 pass and leave the parent PR to a later run. A *merged*
  parent PR → the M-FULLY-COMPLETE report and exit. Both phase checks also
  share two rules: several PRs back → act on the OPEN one (several open →
  ask which), and a **CLOSED, unmerged** PR matches no enumerated state, so
  stop and ask — someone abandoned that branch's PR deliberately, and both
  opening a replacement and reviewing a dead one would be guessing at intent.
  Every merged-state exit posts the step-6 report only — GitHub-for-Jira
  already handled `<STATUS_DONE>`, so there is no wrap-up to take and step 7
  has nothing to offer.
- **The reviewer carries its own Jira identity on every call** — there is no
  login step to run first. `jira.sh` / `jira.ps1` authenticates
  **per-request** as `--role reviewer`, picking that role's `email:token`
  pair out of `jira-sdlc-tools.local.env` for the one call, so every
  canonical report and every reject-path transition below is attributed to
  the reviewer's Jira account. Nothing is stored and no account is "active",
  which is why a reviewer run can overlap a phase-2 executor run without
  either one displacing the other's credentials. Note this is the reviewer's
  **Jira** identity; its **GitHub** identity is a separate thing, and the one
  that matters for the idempotency check below. See
  [`plugins/jira-sdlc/skills/_shared/project-config.md`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md)
  and
  [`plugins/jira-sdlc/skills/_shared/jira-api-reference.md`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/jira-api-reference.md)
  §9.
- **`<SELF>` is resolved once per run — but only where a review happens** —
  `gh api user --jq .login` runs at the top of step 3, before the review
  loop, and its value is substituted literally into every 3a check. That is
  why the diagram draws it *inside* the branches that review something
  rather than once up front: the exits that review nothing — no PR yet,
  S-MERGED, M-FULLY-COMPLETE, and the multistep nothing-to-review case —
  never reach step 3 and never resolve it. **Two** branches review without
  entering step 3, and both are the multistep phase check's
  every-sub-task-`<STATUS_DONE>` split: the *open parent PR* path, which jumps
  from step 1 straight to 5b, and the *no parent PR* path, which jumps from
  step 1 to 5a — where the parent PR is created — and on into 5b. Neither
  passes through step 3, so **5b resolves `<SELF>` itself** on both. That is
  what the skill's 5b means by "the all-sub-tasks-merged re-run path": one
  class, two routes. If that call errors,
  `gh` is missing or logged out: the run reports the error and hands the
  user the PR URLs rather than proceeding.
- **Idempotent review (step 3a)** — before every PR review — the
  single-step PR, each multistep sub-task PR, and the aggregate parent PR
  (5b) — the reviewer checks whether *its own* GitHub identity already left
  a verdict comment (matched on author + body prefix, never on review
  `state` — both verdicts land as comments, so this identity leaves no
  review state to key on). The **most recent** verdict wins: a later one
  supersedes an earlier, which is what makes an approve→regression→reject
  sequence readable. Most recent `APPROVED —` → skip re-review and report
  the PR as already approved/awaiting merge, *unless* `$ARGUMENTS` asks for
  a re-review — that is the manual override for exactly this case. Most
  recent `CHANGES REQUESTED —` → a fresh re-review of the pushed fixes.
  This is the `3a idempotency` node drawn in each review branch.
- **Empty exits and flag-and-skip (step 2)** — the reviewer first discovers
  each In Review sub-task's branch (anchored `git branch -a --list` globs
  that also strip git's `+` marker for a branch checked out in another
  worktree) and its open PR — `gh pr list --head <subtask-branch> --base <PARENT-BRANCH> --state open`. A sub-task with **no branch or no open PR** is
  flagged and skipped, not reviewed; **more than one** open PR is a question
  for the user, the same rule the phase checks carry. If **zero** sub-tasks have an open PR,
  the run reports that there is nothing to review and exits before the
  review loop — except on the multistep track, where the phase check's split
  applies first: every sub-task `<STATUS_DONE>` means the PRs are merged and
  only the parent PR is missing, so the run goes to step 5 instead of
  exiting. Step 2 also runs on the sub-task-worktree path, for that one
  sub-task alone — it is the only place a branch becomes the `prNumber` that
  3a needs.
- **Both verdicts go through `--comment --body-file`** — in this plugin's
  default deployment the executor and reviewer share one `gh` account, and
  GitHub blocks an author from approving *or* requesting changes on their
  own PR. Both verdicts are recorded as review comments with the decision
  in their body prefix (`APPROVED — …` / `CHANGES REQUESTED — …`). The
  Jira transition to `<STATUS_IN_PROGRESS>` (reject path) is the actual
  workflow gate; the GitHub comment records findings and makes the verdict
  machine-detectable by the idempotency check (step 3a).
- **Single-step is one-and-done** — on the single-step track, approval
  posts the final report immediately (S-APPROVED outcome, step 6), then
  step 7 offers to close the issue. Decline and GitHub-for-Jira
  auto-transitions it to `<STATUS_DONE>` when the user merges instead;
  either way no reviewer re-run is required. Only the
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
  continues to the next sub-task. The final
  report at the end (step 6) lists both approved and rejected items so the
  fix-and-re-run cycle is clear.
- **One report body, posted to every destination that needs it** — 3d, 3e,
  5b and 6 all emit *the same* canonical review report, filled from
  `_shared/templates/review-report.md`. On the multistep track 3d writes one
  body to a temp file, posts it to GitHub and to `<SUBTASK-KEY>`, and **3e
  posts that identical file again to `<PARENT-KEY>`** — a fresh comment per
  sub-task, which is the intentional audit trail, not a one-line tally. On
  the single-step track 3d's Jira destination and step 6's are both
  `<PARENT-KEY>`, so 3d posts only the GitHub half and 3e is skipped
  entirely: step 6 is that run's single Jira record. The same reasoning
  skips 3e on the sub-task-worktree path.
- **Parent PR: review, approve *or reject*, still never merge (multistep
  only)** — once every sub-task PR is merged, the reviewer finds or creates
  the aggregate parent PR (GIT). `gh pr list --state all` there returns four
  states, not three: if that PR is already **CLOSED** it stops
  and lets the user decide (5a) — it never reopens or recreates it; if it is
  already **MERGED**, 5a is the second detector of M-FULLY-COMPLETE, after
  the step-1 phase check.
  Otherwise 5b runs the 3a idempotency check first — a prior `APPROVED —`
  self-review means the parent PR is already reviewed, so the run reports it
  as awaiting manual merge and posts **nothing** to GitHub. Past that it asks
  GitHub whether the
  PR is **mergeable** (`gh pr view --json mergeable,mergeStateStatus`):
  `CONFLICTING` means `<PARENT-BRANCH>` has fallen behind `<BASE_BRANCH>`,
  so it stops and reports rather than reviewing a diff that cannot merge —
  this is the *only* detector the "parent branch is behind its base" edge
  case has. Past that it reviews the lighter aggregate diff (integration
  focus) and
  records a verdict on the parent PR via `gh pr review --comment --body-file`: **approve** → M-PARENT-READY (awaiting the human's manual
  merge), or **request changes** → M-PARENT-CHANGES-REQUESTED (integration
  `file:line` findings; fix on `<PARENT-BRANCH>` and re-run). Unlike a
  sub-task reject, the parent reject does **not** transition any Jira issue
  — the aggregate `<PARENT-KEY>` stays as-is. The reviewer never calls
  `gh pr merge` on the parent — merging into `<BASE_BRANCH>` is the human
  release decision. After the parent PR merges, no re-run is required; a
  re-run only reports the already-merged state (M-FULLY-COMPLETE).
- **No automatic status transitions** — the reviewer never moves an issue
  to Done on its own. The only transition it performs unprompted is a
  **rejected** issue → In Progress, and only on a *sub-task* reject (3d) or
  a *single-step* reject (3d) — never on the multistep parent-PR reject
  (5b), where no executor will pick the parent branch up anyway.
- **Done is offered, never assumed (step 7)** — the run's last step names
  every issue it approved and asks once whether to close them, moving only
  what the user confirms. It asks because an approval is not a merge: the
  reviewer never merges, so those PRs are still open, and on boards where
  Done means merged the card would be jumping ahead of the automation that
  really closes it. Boards that close at approval want the opposite, and
  nothing in the repo says which kind this project is. Declining (or a
  non-interactive run) leaves everything as-is and GitHub-for-Jira's merge
  automation closes the issues later. The already-merged exits (S-MERGED,
  M-FULLY-COMPLETE) skip the question — those issues are Done already. No
  extra Jira comment is posted either way: the step-6 report is still the
  run's single final comment.
- **Every terminal branch posts a JIRA report comment on the parent**
  — per step 6, the report goes to chat *and* as a single Jira comment
  on `<PARENT-KEY>`: the single-step *no-PR-yet* exit, the single-step
  approve/reject (S-APPROVED / S-CHANGES-REQUESTED) and merged (S-MERGED)
  reports, the multistep *nothing-to-review* exit, the M-ALL-APPROVED and
  M-SOME-BLOCKED reports, the parent approve (M-PARENT-READY) and parent
  reject (M-PARENT-CHANGES-REQUESTED) reports, the 5b already-approved skip
  (which posts no GitHub comment but still reports), and the merged-state report
  (M-FULLY-COMPLETE). **Three** branches stop without a step-6 report, all of
  them surfacing state to the user in chat and waiting: the
  parent-PR-CLOSED case (5a), 5b's `CONFLICTING` stop, and the failure to
  resolve `<SELF>` (`gh` missing or logged out), which hands back the PR URLs
  instead. None of the three has a report to post — the outcome catalogue in
  `_shared/templates/review-report.md` holds exactly ten blocks and no block
  describes any of them.

## Related

- [Phase 1 — Plan](TASK-LIFECYCLE-PHASE-1.md)
- [Phase 2 — Implement](TASK-LIFECYCLE-PHASE-2.md)
- [jira-task-reviewer SKILL.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jira-task-reviewer/SKILL.md)
