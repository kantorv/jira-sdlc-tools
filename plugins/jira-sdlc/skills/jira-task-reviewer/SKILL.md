---
name: jira-task-reviewer
description: Given a parent Jira issue key (e.g. PROJ-286), finds all sub-tasks in "In Review" status that have an open PR into the parent branch, reviews each PR (approve or request changes), posts findings to Jira, and continues past any rejections to report the full state. After a reject-and-fix cycle, re-run to resume. Once all sub-task PRs are merged (by a human), the skill reviews the parent PR into the base branch. Also handles single-step top-level issues (no sub-tasks) by reviewing their PR directly into the base branch. Never merges anything.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are acting as the code reviewer for the **`<PROJECT-KEY>`** project. Given a parent Jira issue key ($ARGUMENTS, e.g. `PROJ-286`):

**Conventions used below:**
- `<PARENT-KEY>` = the Jira issue key passed as $ARGUMENTS. It just means "the key you passed" — it is only literally the parent of sub-tasks on the multistep track; on the single-step track it is a standalone issue with no sub-tasks.
- `<PARENT-BRANCH>` = the git branch for `<PARENT-KEY>`, always named `feature/<PARENT-KEY>-<slug>` or `hotfix/<PARENT-KEY>-<slug>`.
- `<BASE_BRANCH>` = whatever `<PARENT-BRANCH>` itself should merge into — resolve per `../_shared/jira-acli-reference.md` §12 (git-config → Jira "PR target branch" comment → `<DEFAULT_BASE_BRANCH>` env default).
- Sub-task PRs all target `<PARENT-BRANCH>` — every sub-task gets its own dedicated branch and PR.
- **Single-step top-level issues** (no sub-tasks) have a PR targeting `<BASE_BRANCH>` directly.
- Reviewer only processes sub-tasks whose Jira status is `<STATUS_IN_REVIEW>`. Those not yet in review (e.g. still `<STATUS_IN_PROGRESS>`) are silently ignored — the executor will transition them when ready.
- Auth follows `../_shared/jira-acli-reference.md` §0 — `acli` stores credentials after a one-time `acli jira auth login`, so no per-command `JIRA_API_TOKEN` prefix; run commands bare.
- **Your GitHub identity** = `gh api user --jq .login` — resolve it once and reuse it for the whole run (hold it in a shell variable, e.g. `SELF=$(gh api user --jq .login)`). The executor opens PRs with the *same* `gh` account in this plugin's default deployment, and GitHub blocks an author from approving *or* requesting changes on their own PR, so both verdicts are recorded as **review comments** carrying the decision in their body prefix (`APPROVED — …` / `CHANGES REQUESTED — …`; see 3d/5b); the Jira transition to `<STATUS_IN_PROGRESS>` is the actual workflow gate, the comment only records findings. The idempotency check (3a) and the verdict-comment detection both key on this identity.
- **Jira-comment mechanics**: reports and updates are multi-line — write them to a temp file and post with `acli jira workitem comment create --key <KEY> --body-file <file>` (see `../_shared/jira-acli-reference.md` §6). Single-line comments can use the `--body "<text>"` form. *Never wrap markdown in a quoted inline `--body` string* — backticks are interpreted as shell command substitutions, and `--body-file -` / stdin does not work.
- **GitHub-body mechanics**: the same backtick hazard applies to `gh pr review` / `gh pr create` bodies. Write every GitHub-side body to a temp file and pass `--body-file` (never inline `--body "…"`). The `APPROVED — …` / `CHANGES REQUESTED — …` body prefix is what makes a prior verdict machine-detectable later (see 3a) — keep it verbatim, byte-for-byte.

## 1. Resolve the parent, sub-tasks, and pick a track

- `git fetch origin --prune` first. Branches created or merged by parallel sub-task executors (possibly from different worktrees) may not be visible locally yet.
- Fetch the parent issue: `acli jira workitem view <PARENT-KEY> --json --fields '*all'`. Confirm `fields.issuetype.name` is a top-level type (`Task`, `Story`, `Bug`). If it's a `Subtask`, stop — this skill operates on parent issues only; the user should pass the parent key, not a sub-task key.
- **Resolve `<PARENT-BRANCH>`**: `git branch -a | grep <PARENT-KEY>`. Exactly one match → that's the parent branch. Zero or multiple → ask the user rather than guessing.
- **Resolve `<BASE_BRANCH>`** per `../_shared/jira-acli-reference.md` §12. Only ask the user if both the config and the Jira-comment fallback come up empty.
- **Determine the track** from `fields.subtasks` (absent, `null`, or empty `[]` → **single-step**; anything else → **multistep**). This sets the run's **PR set** and the steps you will walk. Name the track explicitly so the rest of the skill reads as one track at a time:
  - **Single-step track** — the PR set is *just the one parent PR* (`<PARENT-BRANCH>` → `<BASE_BRANCH>`). Walk: *Single-step phase check* → review loop (step 3, with the parent PR as the sole PR) → 4c → 6 → 7.
  - **Multistep track** — the PR set is *each in-review sub-task PR*. Extract sub-task keys from `fields.subtasks` (the default `--json` omits subtasks, so `--fields '*all'` is required — see `../_shared/jira-acli-reference.md` §3; the shape is an array of objects, i.e. `fields.subtasks[].key`, not bare strings). For each sub-task key run `acli jira workitem view <SUBTASK-KEY> --json --fields '*all'` and keep only those whose `fields.status.name` matches `<STATUS_IN_REVIEW>` (e.g. "In Review") — others are not reviewed yet, skip quietly. Walk: *Multistep phase check* → step 2 → review loop (step 3) → 4a/4b → 5 → 6 → 7.

### Single-step phase check (only for the single-step track)

For a single-step issue (no sub-tasks), check if a PR already exists targeting `<BASE_BRANCH>`:

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all --json number,state,url
```

- **No PR exists yet** → The executor hasn't opened one. Report: "Single-step issue `<PARENT-KEY>` has no open PR yet. The reviewer will run once the PR is created." Exit.
- **PR exists and is OPEN** → Proceed to step 3 to review this PR (skip step 2; jump to the review loop).
- **PR exists and is MERGED** → The human already merged it. Skip to step 6 for post-merge wrap-up.

### Multistep phase check (only for the multistep track)

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all --json number,state,url
```

- **No parent PR exists yet** → Sub-tasks aren't all merged. Continue to step 2 for a full review pass.
- **A parent PR exists and is OPEN** → Sub-tasks are already merged; skip straight to step 5 to review the parent PR.
- **A parent PR exists and is MERGED** → The user merged the aggregate PR manually. Skip straight to step 6 for post-merge wrap-up.

## 2. Discover open PRs for each In Review sub-task (multistep only)

*(Multistep track only — the single-step track's PR set is just the parent PR, set up in step 1, so it skips straight to the review loop.)*

For each `<SUBTASK-KEY>` that passed the status filter:

- Find its branch: `git branch -a | grep <SUBTASK-KEY>`. If no branch exists yet, that sub-task hasn't been implemented — flag it in the report and skip it.
- Find the open PR: `gh pr list --head <subtask-branch> --base <PARENT-BRANCH> --json number,title,state,url`. If no PR exists, flag and skip. If more than one open PR, ask the user which one to review.
- Record: `{ key, branch, prNumber, prUrl }`.

If **zero** sub-tasks have open PRs, report and exit.

## 3. Sequential per-PR review loop

Iterate through **the PR set** (defined in step 1 — the one parent PR on the single-step track, each in-review sub-task PR on the multistep track) in ascending key order. Treat each PR individually — do not hold results for a batch. The loop body below is the same for every PR in the set regardless of track.

### 3a. Check idempotency — already reviewed by me?

Before reviewing a PR, check whether **this skill's GitHub identity** has already left a verdict comment on it. Resolve your identity once (per the Conventions preamble) and reuse it for the whole run:

```bash
SELF=$(gh api user --jq .login)
gh pr view <prNumber> --json reviews --jq \
  '.reviews[] | select(.author.login == "'"$SELF"'") | .body'
```

(`SELF` must resolve — if `gh api user` errors, gh isn't installed or authenticated; see the edge case in step 8.) Inspect the prior self-review bodies this returns. An `APPROVED —` body wins over a `CHANGES REQUESTED —` one — approval is terminal (the reviewer doesn't keep re-reviewing something it already approved; request a forced re-review via the step-8 flag if you genuinely need a fresh pass):

- **A prior self-review whose body starts `APPROVED —`** → already approved. Report the PR as "already approved — waiting for manual merge" and move to the next PR without re-reviewing.
- **A prior self-review whose body starts `CHANGES REQUESTED —` (and none starts `APPROVED —`)** → re-review: this is a fix-and-re-run scenario, and fresh code may have been pushed since. Continue to 3b.
- **No prior review body from this identity** → continue to 3b.

Matching by author **and body prefix** — not by review `state` — is what makes the check correct in this plugin's same-account deployment: both verdicts land as comments (3d/5b), so there is no `APPROVED`/`CHANGES_REQUESTED` review *state* from this identity to key on; the leading header is the contract the detection relies on.

### 3b. Fetch the diff

```
gh pr diff <prNumber>
```

Read the full diff. If it's very large (>1000 lines), list changed files via `gh pr diff <prNumber> --name-only` and `Read` relevant files for context. Do not skip any file in the diff.

### 3c. Review criteria

Evaluate the diff against these dimensions (all must pass for approve):

1. **Correctness** — Does the code fulfill the Jira description without bugs?
2. **Pattern consistency** — Matches codebase naming, structure, and idioms?
3. **No scope creep** — The change only addresses what the PR's issue describes. Unrelated refactors, formatting changes, or "while I'm here" additions belong in a separate issue. Flag these but don't block on trivial cases (e.g. a typo fix in an adjacent comment is fine; a refactor of an unrelated module is not).
4. **No obvious regressions** — Won't break imports, types, or dependencies.
5. **Test coverage** — Has corresponding test coverage if changes are non-trivial.
6. **Build hygiene** — No debug leftovers (`console.log`, TODO markers not in original codebase style), no accidentally-committed files (`.env`, large binaries, etc.).

### 3d. Execute verdict immediately

Record the verdict as a **review comment** — both verdicts go through `gh pr review <prNumber> --comment --body-file`: in this plugin's default deployment the executor and reviewer share one `gh` account, and GitHub blocks an author from approving *or* requesting changes on their own PR — the self-review restriction covers both verdicts, not just approval. So neither verdict can use a state-based review. The Jira transition to `<STATUS_IN_PROGRESS>` (on the reject path) is the actual workflow gate; the GitHub comment only records the verdict and makes it detectable by 3a. The leading `APPROVED — …` / `CHANGES REQUESTED — …` header is that detection contract — keep it verbatim.

* **If APPROVE (all dimensions pass):** write the verdict to a temp file and post it as a review comment:
  ```bash
  cat > /tmp/<KEY>-verdict.md <<'EOF'
  APPROVED — <2-3 sentence review summary: what was reviewed and any notable observations>
  EOF
  gh pr review <prNumber> --comment --body-file /tmp/<KEY>-verdict.md
  ```
  Then post a Jira comment on the reviewed PR's issue (`<SUBTASK-KEY>` for a sub-task PR, `<PARENT-KEY>` for the single-step parent PR) via the §6 `--body-file` convention, saying `PR #<prNumber> has been reviewed and approved.` plus the short review summary:
  ```
  acli jira workitem comment create --key <SUBTASK-KEY-or-PARENT-KEY> --body-file /tmp/<KEY>-approve.md
  ```
  Do NOT move the Jira status — let the GitHub-for-Jira automation handle it when the PR is merged.

* **If REQUEST_CHANGES (one or more dimensions fail):** write the findings to a temp file with the `CHANGES REQUESTED —` header, post it as a review comment, then transition the issue back to `<STATUS_IN_PROGRESS>` (that is the actual gate):
  ```bash
  cat > /tmp/<KEY>-findings.md <<'EOF'
  CHANGES REQUESTED — <file:line findings and required changes>
  EOF
  gh pr review <prNumber> --comment --body-file /tmp/<KEY>-findings.md
  acli jira workitem transition --key <SUBTASK-KEY-or-PARENT-KEY> --status "<STATUS_IN_PROGRESS>" --yes
  ```
  Then post the findings as a Jira comment on the reviewed PR's issue (same `<SUBTASK-KEY>` / `<PARENT-KEY>` as above) via the §6 `--body-file` convention, saying `PR #<prNumber> failed code review. Moving the issue back to In Progress.` plus the findings list:
  ```
  acli jira workitem comment create --key <SUBTASK-KEY-or-PARENT-KEY> --body-file /tmp/<KEY>-reject.md
  ```
  Remember this PR as blocked. Continue the loop — review the next PR.

### 3e. Post a summary on the parent after each sub-task

*(Multistep track only — the single-step track has no sub-tasks to tally: the 3d verdict comment already landed on the one issue, and step 7 carries the report.)*

Regardless of whether the review above was approved or rejected, immediately post a short summary to the parent Jira issue `<PARENT-KEY>` so the progress is visible. A **fresh comment per sub-task is intentional** — it's an audit trail: each sub-task's verdict stands on its own permanent comment (the final report in step 7 is a separate summary, not a replacement for these).

Post it via the §6 `--body-file` convention:
```
acli jira workitem comment create --key <PARENT-KEY> --body-file /tmp/<PARENT-KEY>-summary.md
```
with the content:
```
Review update for sub-task <SUBTASK-KEY> (PR #<prNumber>):
- Status: **APPROVED** / **CHANGES REQUESTED**
- <If approved: one sentence of what was reviewed>
- <If rejected: brief note, full details are in the sub-task's own comment>
```

## 4. After the PR set has been reviewed (loop complete)

Once step 3 has processed every PR in the set, the reviewer ends the session with a report **even if some were rejected**. The human fixes and re-runs; on a later run, any sub-tasks whose Jira status is no longer `<STATUS_IN_REVIEW>` will be skipped, and only resumed-yet-still-in-review items are picked up.

The post-loop outcome is mutually exclusive and **track-dependent** — pick the one matching the track and the run's state; step 7 posts the written report keyed to the same label.

### 4a. *(Multistep)* All approved — merge and re-run

1. Check if **all** of those PRs are already merged (`gh pr view <prNumber> --json state` for each).
2. **If some are still open** → outcome **M-ALL-APPROVED**: tell the user "All sub-task PRs approved. Merge them manually into `<PARENT-BRANCH>`, then re-run `/jira-sdlc:jira-task-reviewer <PARENT-KEY>` to pick up the parent PR." (Step 7 posts the written report to Jira.)
3. **If all are merged** → proceed to step 5 (parent PR handling).

### 4b. *(Multistep)* Some rejected — report and stop

1. **Do not** proceed to the parent PR, regardless of how many other sub-tasks were approved.
2. Outcome **M-SOME-BLOCKED**: tell the human to fix the rejected sub-tasks, wait for the executor to move them back to `<STATUS_IN_REVIEW>`, then re-run `/jira-sdlc:jira-task-reviewer <PARENT-KEY>`. (Step 7 lists **both** approved and rejected items + the file:line findings in the Jira report.)
3. End the session.

### 4c. *(Single-step)* PR reviewed — wait for merge

For a single-step issue (no sub-tasks), after the PR is reviewed in step 3:

- **If approved** → outcome **S-APPROVED**: tell the user "Single-step issue `<PARENT-KEY>` PR #<prNumber> approved. Merge manually into `<BASE_BRANCH>`, then re-run `/jira-sdlc:jira-task-reviewer <PARENT-KEY>` for post-merge wrap-up."
- **If changes requested** → outcome **S-CHANGES-REQUESTED**: report the findings to the user; the human fixes, pushes, and re-runs `/jira-sdlc:jira-task-reviewer <PARENT-KEY>`.

## 5. Parent PR management (multistep only — runs when all sub-task PRs are merged)

*(Multistep track only — runs when all sub-task PRs are merged into `<PARENT-BRANCH>`, either merged by the user in a prior run or already merged before this one. The single-step track never reaches step 5; its one PR is reviewed directly in step 3 and its post-merge flow is step 6.)*

### 5a. Find or create the parent PR

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --json number,title,state,url
```

- **No PR exists** → create one (write the body to a temp file — see the GitHub-body mechanics in the preamble):
  ```bash
  cat > /tmp/<PARENT-KEY>-pr-body.md <<'EOF'
  Aggregate PR for <PARENT-KEY>.

  Sub-tasks merged:
  - <SUBTASK-KEY>: <PR URL>
  - ...
  EOF
  gh pr create --base <BASE_BRANCH> --head <PARENT-BRANCH> \
    --title "<PARENT-KEY>: <summary>" \
    --body-file /tmp/<PARENT-KEY>-pr-body.md
  ```
- **PR exists (state OPEN)** → use it.
- **PR exists and is MERGED** → go straight to step 6 (post-merge actions).
- **PR exists and is CLOSED** → stop and let the user decide (same rule as before).

### 5b. Review the parent PR (apply the 3a idempotency check first)

Apply the **3a body-prefix idempotency check** before reviewing: a prior self-review whose body starts `APPROVED —` → report "Parent PR already reviewed — waiting for manual merge" and skip; one starting `CHANGES REQUESTED —` → re-review the fresh aggregate code. Otherwise:

1. Review the aggregate diff: same criteria as 3c, but lighter. The sub-tasks were already reviewed individually — focus on integration issues, conflicts, and anything that only surfaces when the pieces combine.
2. **If approved** → outcome **M-PARENT-READY**: write `APPROVED — <lighter aggregate summary>` to a temp file and post `gh pr review <prNumber> --comment --body-file` (the verdict-header pattern from 3d). Do NOT merge. Tell the user the parent PR is approved and awaiting their manual merge; step 7 posts the written report.
3. **If changes requested** → write `CHANGES REQUESTED — <integration findings>` and post `gh pr review <prNumber> --comment --body-file`. Report the findings and stop.

*Do not merge here.* Report that the parent PR is reviewed/approved and waiting for the user to merge it manually.

## 6. Post-merge wrap-up

*(Runs on both tracks — detected by a phase check in step 1, or by step 5a on the multistep track after the parent PR merges. On the single-step track it runs after the human merges the one PR and re-runs the reviewer.)*

GitHub-for-Jira will already have moved all related issues to `<STATUS_DONE>`, but a clean Jira comment on the parent is useful for the historical record. Post one via the §6 `--body-file` convention:
```
acli jira workitem comment create --key <PARENT-KEY> --body-file /tmp/<PARENT-KEY>-wrapup.md
```
with the content:
```
All sub-tasks approved and parent branch merged into <BASE_BRANCH>.

Sub-tasks:
- <SUBTASK-KEY>: PR #<n> — merged
- ...
```
*(Single-step track: the "Sub-tasks" section simply lists the single issue and its PR, and the outcome is **S-MERGED** if the single-step PR itself merged. On the multistep track the outcome is **M-FULLY-COMPLETE** once the parent PR has merged.)*

Optionally list any orphaned local branches (`git branch --merged origin/<BASE_BRANCH>`) and report them. Don't auto-delete local branches. Then proceed to step 7 for the final report.

## 7. Report back

Post the review summary to the user in chat **and** as a single Jira comment on `<PARENT-KEY>` via the §6 `--body-file` convention. Emit **exactly one** of the per-outcome blocks below — chosen by the step-1 track × the current phase (decided in step 4 or detected in step 1/5/6) — appended to the shared scaffold. Do not emit more than one outcome block.

**Shared scaffold (always present, then the one outcome block):**
```markdown
## Review Status: <OUTCOME_TITLE>
Parent: <PARENT-KEY> (<PARENT-BRANCH> → <BASE_BRANCH>)

### Pull Request Summary
- <KEY> PR #<n>: [✅ approved | ❌ changes requested | ⏳ skipped]
- ...
```

**Per-outcome block — emit exactly one:**

#### Single-step track

- **S-APPROVED** — single-step PR approved, awaiting manual merge. Outcome title: `Single-step PR approved — merge manually and re-run`. Append:
  ```
  Single-step PR #<n>: ✅ reviewed and approved. Merging is manual — merge it yourself on GitHub when ready: <PR URL>.
  Once merged, re-run /jira-sdlc:jira-task-reviewer <PARENT-KEY> to post the final Jira update.
  ```
- **S-CHANGES-REQUESTED** — single-step PR rejected. Outcome title: `Single-step PR changes requested — see findings`. Append the file:line findings, then:
  ```
  Fix the findings above, push, then re-run /jira-sdlc:jira-task-reviewer <PARENT-KEY>.
  ```
- **S-MERGED** — single-step PR already merged (detected by the step-1 phase check; step 6 already posted the wrap-up comment). Outcome title: `Single-step PR merged — complete`. Append:
  ```
  Single-step PR #<n>: ✅ merged into <BASE_BRANCH> (Jira auto-transitioned by GitHub-for-Jira).
  ```

#### Multistep track

- **M-ALL-APPROVED** — all sub-task PRs approved, some still open. Outcome title: `All sub-task PRs approved — merge manually and re-run`. Append:
  ```
  All sub-task PRs approved. Merge them manually into <PARENT-BRANCH>, then re-run /jira-sdlc:jira-task-reviewer <PARENT-KEY> to pick up the parent PR.
  ```
- **M-SOME-BLOCKED** — some approved, some rejected. Outcome title: `Some PRs approved, some blocked — see below`. Append two sections:
  ```
  #### Approved PRs (waiting for manual merge)
  - <KEY> PR #<n>: <PR URL>
  - ...

  #### Blocked PRs (need fixes)
  <BLOCKED-KEY> PR #<n>: <PR URL>
  1. <file>:<line> — <what's wrong>
  2. ...

  #### Next step:
  Fix the findings above in each blocked branch, push, then re-run /jira-sdlc:jira-task-reviewer <PARENT-KEY>.
  ```
- **M-PARENT-READY** — all sub-tasks merged, parent PR reviewed/approved, awaiting manual merge into base. Outcome title: `All sub-tasks merged — parent PR ready`. Append:
  ```
  Parent PR #<n>: ✅ reviewed and approved. Merging is manual — merge it yourself on GitHub when ready: <PR URL>.
  Once merged, re-run /jira-sdlc:jira-task-reviewer <PARENT-KEY> to post the final Jira update.
  ```
- **M-FULLY-COMPLETE** — parent PR merged into base (step 6 already posted the wrap-up comment). Outcome title: `Fully complete — parent PR merged`. Append:
  ```
  Parent PR #<n>: ✅ merged into <BASE_BRANCH> (Jira auto-transitioned by GitHub-for-Jira).
  ```

## 8. Edge cases

- **No sub-tasks in review status, but sub-tasks exist** → report that the executor hasn't pushed any PRs to In Review yet; the user may re-run later.
- **Sub-task with no branch / no PR**: flag in the report. The skill can only review what has been pushed and has a PR open. Don't attempt to create branches or PRs — that's the executor's job.
- **A review (or approval) from someone else**: the skill always does its own review — an existing review by another account doesn't skip the code-review step. The 3a idempotency check only looks at *this skill's own* prior comments, keyed on `<SELF>`'s login + body prefix.
- **Already reviewed by this skill (idempotency)**: see 3a — a prior self-review whose body starts `APPROVED —` skips re-review (waiting for manual merge); one starting `CHANGES REQUESTED —` triggers a re-review of the fresh code. For a forced re-review, flag it manually.
- **`gh` not installed or not authenticated**: `gh api user --jq .login` fails, so 3a can't resolve the identity — report the error and give the user the PR URLs so they can review/merge manually.
- **Parent branch is behind its base**: If `<BASE_BRANCH>` has advanced, the parent PR may show conflicts. Stop and report. The user can rebase `<PARENT-BRANCH>` onto `<BASE_BRANCH>` and re-run.
- **Single-step PR merged before reviewer runs**: The phase check in step 1 detects this and jumps straight to step 6.

Reference: `../_shared/jira-acli-reference.md` has the full acli syntax, confirmed issue types, and git/branch conventions this skill depends on. The `jira-tools-plugin.env` file in the project root has this repo's specific values for every `<TOKEN>` used above.
