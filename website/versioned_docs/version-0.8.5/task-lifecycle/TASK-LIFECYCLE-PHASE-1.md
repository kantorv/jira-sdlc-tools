---
slug: /task-lifecycle-phase-1
sidebar_position: 2
sidebar_label: Phase 1 · Plan
---

# Task Lifecycle — Phase 1: Plan

Phase 1 of the task lifecycle, run by the **`jira-task-assigner`** skill.
Triggered once per task, **from the main repo checkout** — never a linked
worktree, the opposite reading from phases 2 and 3, because this is the skill
that *creates* the worktrees — and **on the default base branch** (or on the
production branch, which is accepted only for an emergency hotfix). The
assigner refuses to run on an existing `feature/`/`hotfix/` issue branch or
from a detached HEAD (which gives the new branches nothing nameable to be
cut from), and asks the user how to proceed on any other branch.

This phase ends when the assigner reports back: issues exist, branches
and worktrees are ready, a `"PR target branch: ... Worktree: ..."`
comment is posted on every leaf issue (plus one more on the parent
issue itself in the multistep case) for the next phase to read, and
the report itself is posted as a Jira comment on the parent issue in
addition to the chat reply.

The diagram surfaces the two systems the assigner actually drives as
their own swimlanes — **GIT** (anything that mutates repo state:
the pre-branch fetch/pull, creating branches, setting
`parentbranch` config, pushing, adding worktrees) and **JIRA**
(anything that mutates issue state: creating the top-level or sub-task
issue, posting comments) — so the full interaction reads
`User ↔ Assigner ↔ GIT ↔ JIRA` left to right. The healthcheck and
`get_assignee_email.sh` are drawn as self-calls because they **gather facts
rather than mutate** either system — not because they stay local.
`get_assignee_email.sh` genuinely only reads `.jst/` config, but the
healthcheck also *probes* both credentials over the network
(`GET /myself` for Jira, `GET /repos/…` for GitHub). Both reads, neither a
write.

## Sequence diagram

```mermaid
sequenceDiagram
    actor User
    participant Assigner
    participant GIT
    participant JIRA

    Note over User,JIRA: Phase 1 — Plan<br/>(runs once, from the base branch — or production, hotfix only)
    User->>Assigner: invoke /jira-task-assigner "<task description>"

    activate Assigner
    Note right of Assigner: there is no login step — every call below authenticates<br/>per-request as --role assigner, so everything is filed BY the assigner<br/>(Jira sets creator + reporter from it)
    Assigner->>Assigner: Step 1 — Discovery & healthcheck<br/>statuscheck.sh --role assigner<br/>(worktree · branch · worktrees_dir · env_local · jira_auth ·<br/>gh_auth · gh_repo_access · jira_account_url — any FAIL → stop)
    Note right of Assigner: main checkout required — a linked worktree → stop (this skill CREATES worktrees).<br/>worktrees_dir missing reads WARN, not FAIL → stop and ask, never mkdir it.<br/>the healthcheck already read the current branch —<br/>step 2 judges that row rather than asking GIT again
    Assigner->>Assigner: Step 2 — branch context, from the healthcheck's branch row
    Note right of Assigner: base → continue · production → continue, hotfix only (step 5C decides)<br/>feature/hotfix → stop · detached HEAD → stop (nothing nameable to cut from)<br/>other → ask user
    Assigner->>Assigner: Step 3 — investigate codebase

    loop Step 4 — clarify until scope/types settled
        Assigner->>User: ask clarifying questions (scope, AC, priority...)
        User-->>Assigner: answers
    end

    Assigner->>Assigner: Step 5 — decide scope (single-step vs multistep)<br/>+ top-level type (Task / Story / Bug)<br/>+ base — planned work (default) or explicit hotfix

    opt Step 5C — the base decision needs the user
        Assigner->>User: emergency production fix? name the path and get a yes<br/>(only deliberate wording counts — "urgent" or "asap" is not the signal)
        User-->>Assigner: confirm | decline
        Note right of Assigner: no yes → create nothing · hotfix with production_branch unset → stop and ask ·<br/>standing on production but the decision is planned work → stop and say to<br/>checkout the base branch, or tomorrow's feature is cut from production
    end

    Assigner->>GIT: Step 6 — git fetch origin<br/>+ git pull --ff-only origin BRANCH_FROM (planned work only)
    GIT-->>Assigner: refs up to date
    Assigner->>Assigner: Step 6A — get_assignee_email.sh → ASSIGNEE_EMAIL<br/>(reads .jst config, no Jira call — no email configured → stop)
    Note right of Assigner: every create below carries<br/>--assignee ASSIGNEE_EMAIL

    alt Multistep (split into parallel sub-tasks)
        Assigner->>JIRA: Step 6A.1 — create <PARENT-KEY> issue (Task / Story / Bug)<br/>--assignee ASSIGNEE_EMAIL<br/>--desc-file (step 3 findings + step 4 acceptance criteria)
        JIRA-->>Assigner: <PARENT-KEY>
        Assigner->>GIT: Step 6A.2-4 — create branch feature/<PARENT-KEY>-<slug> + git push -u origin<br/>(multistep is always the planned path — feature/ from development),<br/>set parentbranch config = BASE_BRANCH, add parent worktree
        GIT-->>Assigner: branch + worktree ready
        loop Step 6C — per sub-task
            Assigner->>JIRA: create sub-task issue (link parent <PARENT-KEY>)<br/>--assignee ASSIGNEE_EMAIL
            JIRA-->>Assigner: sub-task key
            Assigner->>GIT: create sub-task branch + worktree off the parent branch<br/>(one git worktree add -b), set parentbranch config = parent branch<br/>— no push here, the executor pushes it in phase 2
            GIT-->>Assigner: branch + worktree ready
            Assigner->>JIRA: post "PR target branch: ... Worktree: ..." comment
        end
        Assigner->>JIRA: Step 6C — post "PR target branch: <BASE_BRANCH>.<br/>Worktree: worktree-<PARENT-KEY>" comment (on the parent)
    else Single-step (one cohesive task, and every hotfix)
        Assigner->>JIRA: Step 6A.1 — create single top-level issue<br/>--assignee ASSIGNEE_EMAIL<br/>--desc-file (step 3 findings + step 4 acceptance criteria)
        JIRA-->>Assigner: issue key
        Assigner->>GIT: Step 6A.2-4 — create branch from the chosen base + git push -u origin<br/>(feature/ off development — hotfix/ off origin/main),<br/>set parentbranch config = BASE_BRANCH, add worktree
        GIT-->>Assigner: branch + worktree ready
        Assigner->>JIRA: Step 6B — post "PR target branch: ... Worktree: ..." comment
    end
    Assigner->>JIRA: Step 7 — post report comment (on the parent issue)<br/>first line is the "Assignment report" marker the executor greps for
    deactivate Assigner

    Assigner-->>User: Step 7 — report (keys + links, scope and base path with reasons,<br/>branches, worktrees — plus the back-merge reminder on the hotfix path)
    Note over User,JIRA: Step 8 — no code, no commits, no PRs.<br/>Hand-off: cd into each worktree and run /jira-sdlc:jira-task-executor<br/>with no key argument (optionally with free-form notes) — phase 2 starts there
```

## What the diagram shows

- **Step labelling** — every node carries the step number
  `jira-task-assigner`'s own `SKILL.md` gives it, so the diagram and the
  skill can be read side by side. The assigner numbers **Discovery &
  healthcheck as its step 1**; phases 2 and 3 run the same check as an
  *unnumbered pre-step*, so their diagrams label it `Pre-step — Discovery & healthcheck` instead. The step, its name, and the `statuscheck.sh` call
  are identical in all three — only the `--role` argument, the rerun-hint
  override (the assigner and reviewer wrap the call in `STATUSCHECK_RERUN`,
  the executor doesn't) and each skill's own numbering differ, and the
  diagrams follow the skill rather than renumbering it.
- **Two preconditions step 1 judges for itself** — the `worktree` row never
  FAILs, and `worktrees_dir` FAILs only when the path isn't absolute, so the
  skill decides both rather than the script. The assigner requires the **main
  checkout**, stopping on a linked-worktree reading because it *creates*
  worktrees rather than running inside one, and it requires `<WORKTREES_DIR>`
  to already exist — a missing one reads WARN, and the skill stops to ask
  rather than `mkdir`ing it, since the convention may have changed.
- **Participant routing** — the assigner is the orchestrator between
  three parties. **GIT** owns repo state (the pre-branch
  `fetch`/`pull --ff-only`, branch creation, the
  `branch.<branch>.parentbranch` git config entry, the push, and
  `git worktree add`). **JIRA** owns issue state (creating the top-level or
  sub-task issue — the sub-task carries its parent link — and posting the
  durable `PR target branch` comment). Everything else (the healthcheck,
  reading the branch context off its rows, investigating the codebase,
  deciding scope, and resolving `ASSIGNEE_EMAIL`) stays inside the assigner.
- **The branch context is read once, by the healthcheck** — step 2 judges
  the `branch` row step 1 already produced rather than asking GIT again;
  `SKILL.md` says so explicitly ("the script already ran
  `git branch --show-current`; don't re-run it"). The same is true of
  `get_assignee_email.sh` (step 6A), which only reads `.jst/` config — it
  makes no Jira call, so it is drawn as a self-call, not a JIRA arrow.
- **Refresh before branching (step 6)** — both paths `git fetch origin`
  first; only planned work also runs `git pull --ff-only origin <BRANCH_FROM>`,
  because the hotfix path cuts from the freshly fetched
  `origin/<PRODUCTION_BRANCH>` and a pull there would only move whichever
  branch happens to be checked out.
- **Two identities, and they are not the same one** — there is no login
  step: every Jira call carries `--role assigner` and authenticates on that
  credential per request, so Jira records the assigner as the `creator` and
  `reporter` of every issue
  here — both are derived from the authenticated account, no flag needed.
  But each issue is **assigned to the executor** (`get_assignee_email.sh`
  → `--assignee` on every create, top-level *and* sub-task), because the
  executor is who will pick it up — and phase 2 *refuses* an issue that
  isn't assigned to it. So the board reads correctly end to end: filed by
  the assigner, owned by the executor. Both identities come from that role's
  own required credential pair — there is no default account either can fall
  back to. See
  [`plugins/jira-sdlc/skills/_shared/project-config.md`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md).
- **Investigate + clarify loop** — the main place the user is asked
  anything by `jira-task-assigner`; questions persist until scope,
  acceptance criteria, and priority are settled, and the answers are then
  written into the issue description at step 6A.1 rather than left in chat.
  It is not the only place, though. Five other points can put a question to
  the user, none of them drawn as this loop: an empty `$ARGUMENTS` (asked for
  before anything runs, the healthcheck included), a `worktrees_dir` row that
  read WARN, the branch-context "ask otherwise" path, a
  `git pull --ff-only` that exits on real divergence at step 6, and the
  hotfix confirmation below — which carries a sixth of its own, the
  `production_branch`-unset stop.
- **The hotfix path has an explicit user gate (step 5C)** — the `opt` after
  step 5. The assigner takes it *only* when the user deliberately asked for
  an emergency production fix; urgency wording ("urgent", "asap",
  "blocking") is not that signal, and even on deliberate wording it names
  the path and waits for a yes before creating anything. A false positive
  points a PR at production, shipping code that never sat in staging — which
  is why this is a gate rather than an inference. The `opt`'s note carries
  all three of 5C's stop conditions — the gate itself (no yes → create
  nothing) plus two that fire independently of the answer: a hotfix whose
  `production_branch` row read `unset` (don't invent the name of the branch
  you're about to target), and standing on the production branch when the
  decision turns out to be planned work (continuing would cut tomorrow's
  feature from production). Two more hotfix-only obligations land later and
  aren't drawn as nodes: step 6 confirms the `PR target branch` comment
  actually posted (the base resolver's last fallback is
  `<DEFAULT_BASE_BRANCH>`, so a hotfix that lost its comment reads as
  ordinary planned work to a later session), and step 7's report has to say
  the fix still needs to reach `<DEFAULT_BASE_BRANCH>` after it lands on
  production, or the bug returns with the next sprint release.
- **Scope decision first** — the assigner settles scope and the
  top-level type (`alt Multistep / else Single-step`); inside the
  multistep loop it provisions each sub-task's issue (JIRA) and then its
  branch and worktree (GIT) uniformly.
- **The base decision rides along with scope** — planned work (the
  default) branches `feature/` off `development`, while an *explicitly
  requested* emergency production fix branches a single `hotfix/` off
  `origin/main` ([SDLC.md](../process/SDLC.md) §4). Because it cuts from the
  fetched remote ref rather than checking production out, the hotfix works
  the same whether you invoke it from `development` or from `main` — `main`
  is a permitted start state, never a required one, and step 5C stops if it
  turns out to be planned work. Either way the `Multistep` arm is always the
  planned path, and the two never mix within a run.
- **Provisioning is uniform, with one exception — the push** — *every*
  scenario (single-step, multistep parent, sub-task) records
  `branch.<branch>.parentbranch` in git config via GIT and ends with the
  assigner posting a `PR target branch: ... Worktree: ...` comment to JIRA for
  that leaf — the durable source of truth the executor and reviewer will read
  later. In the multistep case that comment happens once per sub-task *and*
  once more on the parent issue after the sub-task loop, so it's neither
  one-per-leaf nor a single comment overall. **The branch is pushed only on
  the top-level path**: step 6A.2 is the assigner's one and only
  `git push -u origin`, for the single-step issue's branch or the multistep
  parent's. Step 6C's three actions for a sub-task are `git worktree add -b`,
  the `parentbranch` config, and the comment — no push. A sub-task branch
  first reaches the remote in phase 2, at the executor's own step 09.
  The recorded `parentbranch` value differs with it: `<BASE_BRANCH>` for a
  top-level branch (never `<BRANCH_FROM>` — on the hotfix path `gh` can
  target `main` but not `origin/main`), and the parent's branch for a
  sub-task.
- **The final report is durable too** — before `deactivate Assigner`,
  the report goes to JIRA as a comment on the parent issue in addition
  to the chat reply to the user, so a later phase (or a fresh session)
  can recover it without relying on chat history. Its first line is the
  literal `Assignment report` marker, which is how phase 2's step 4 finds
  it among the issue's other comments.
- **Step 8 is the hand-off, and it is a real step** — the assigner
  deliberately stops short of writing any code, commits, or PRs, and ends
  by pointing the user (or one subagent per worktree) at
  `/jira-sdlc:jira-task-executor`, run from inside each worktree with **no
  key argument** — optionally with free-form prose notes for that run. Also
  out of scope here: merging the parent branch back into its own base once
  the sub-tasks land. That closing note is where phase 2's diagram picks up.

## Related

- [Phase 2 — Implement](TASK-LIFECYCLE-PHASE-2.md)
- [Phase 3 — Review & aggregate approval](TASK-LIFECYCLE-PHASE-3.md)
- [jira-task-assigner SKILL.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/jira-task-assigner/SKILL.md)
