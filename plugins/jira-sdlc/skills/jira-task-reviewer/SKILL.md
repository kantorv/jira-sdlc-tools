---
name: jira-task-reviewer
description: Given a parent Jira issue key (e.g. PROJ-286), finds all sub-tasks in "In Review" status that have an open PR into the parent branch, reviews each PR (approve or request changes), posts findings to Jira, and continues past any rejections to report the full state. After a reject-and-fix cycle, re-run to resume. Once all sub-task PRs are merged (by a human), the skill reviews the parent PR into the base branch. Also handles single-step top-level issues (no sub-tasks) by reviewing their PR directly into the base branch. Never merges anything.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are acting as the code reviewer for the **`<PROJECT-KEY>`** project. Given a parent Jira issue key ($ARGUMENTS, e.g. `PROJ-286`):

**Conventions used below:**
- `<PARENT-KEY>` = the Jira issue key passed as $ARGUMENTS.
- `<PARENT-BRANCH>` = the git branch for `<PARENT-KEY>`, always named `feature/<PARENT-KEY>-<slug>` or `hotfix/<PARENT-KEY>-<slug>`.
- `<BASE_BRANCH>` = whatever `<PARENT-BRANCH>` itself should merge into (typically `<DEFAULT_BASE_BRANCH>` — see `jira-tools-plugin.env` in the project root) — recovered from `git config branch.<PARENT-BRANCH>.parentbranch` (set by `jira-task-assigner` when it created the branch), falling back to that issue's `"PR target branch: ..."` Jira comment if the config is missing.
- Sub-task PRs all target `<PARENT-BRANCH>` — every sub-task gets its own dedicated branch and PR.
- **Single-step top-level issues** (no sub-tasks) have a PR targeting `<BASE_BRANCH>` directly.
- Reviewer only processes sub-tasks whose Jira status is `<STATUS_IN_REVIEW>`. Those not yet in review (e.g. still `In Progress`) are silently ignored — the executor will transition them when ready.
- Auth follows `../_shared/jira-cli-reference.md` §0 — check `JIRA_API_TOKEN` first, fall back to `<JIRA_TOKEN_PATH>` (see `jira-tools-plugin.env` in the project root).
- **Jira Comment Mechanics**: Since reports and updates are multi-line, **always pipe via heredoc to `--template -`** (see `../_shared/jira-cli-reference.md` §6). Single-line comments can use the positional `jira issue comment add <KEY> "<text>"` form. *Never wrap markdown in a quoted inline string*—backticks are interpreted as shell command substitutions.

## 1. Resolve the parent, sub-tasks, and filter by status

- `git fetch origin --prune` first. Branches created or merged by parallel sub-task executors (possibly from different worktrees) may not be visible locally yet.
- Fetch the parent issue: `jira issue view <PARENT-KEY> --raw`. Confirm `fields.issuetype.name` is a top-level type (`Task`, `Story`, `Bug`). If it's a `Sub-task`, stop — this skill operates on parent issues only; the user should pass the parent key, not a sub-task key.
- **Determine if this is a single-step or multistep parent.** After viewing the raw parent JSON once, note the value of `fields.subtasks`. Treat it as **single-step** when `fields.subtasks` is absent, `null`, or an empty array (`[]`). Anything else is **multistep**.
  - If **single-step**: Skip the sub-task steps below and go straight to the *Single-step phase check*.
  - If **multistep**:
    1. Extract sub-task keys from `fields.subtasks` (CHECK the exact shape once against real output — likely an array of objects, i.e. `fields.subtasks[].key`, not bare strings).
    2. For each sub-task key, run:
       ```
       jira issue view <SUBTASK-KEY> --raw
       ```
       Keep only those where `fields.status.name` matches `<STATUS_IN_REVIEW>` (e.g. "In Review"). Others are not reviewed yet — skip quietly.
    3. Proceed to the *Multistep phase check* below.
- Resolve `<PARENT-BRANCH>`: `git branch -a | grep <PARENT-KEY>`. Exactly one match → that's the parent branch. Zero or multiple → ask the user rather than guessing.
- Resolve `<BASE_BRANCH>` per the convention above. Only ask the user if both the config and the Jira-comment fallback come up empty.

### Single-step phase check (only for single-step top-level issues)

For a single-step issue (no sub-tasks), check if a PR already exists targeting `<BASE_BRANCH>`:

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all --json number,state,url
```

- **No PR exists yet** → The executor hasn't opened one. Report: "Single-step issue `<PARENT-KEY>` has no open PR yet. The reviewer will run once the PR is created." Exit.
- **PR exists and is OPEN** → Proceed to step 3 to review this PR (skip steps 2, jump to review loop).
- **PR exists and is MERGED** → The human already merged it. Skip to step 6 for post-merge wrap-up.

### Multistep phase check (only for multistep parents with sub-tasks)

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all --json number,state,url
```

- **No parent PR exists yet** → Sub-tasks aren't all merged. Continue to step 2 for a full review pass.
- **A parent PR exists and is OPEN** → Sub-tasks are already merged; skip straight to step 5 to review the parent PR.
- **A parent PR exists and is MERGED** → The user merged the aggregate PR manually. Skip straight to step 6 for post-merge wrap-up.

## 2. Discover open PRs for each In Review sub-task (multistep only)

*Only runs for multistep parents. Single-step issues skip directly to step 3 (review loop) with the parent's PR.*

For each `<SUBTASK-KEY>` that passed the status filter:

- Find its branch: `git branch -a | grep <SUBTASK-KEY>`. If no branch exists yet, that sub-task hasn't been implemented — flag it in the report and skip it.
- Find the open PR: `gh pr list --head <subtask-branch> --base <PARENT-BRANCH> --json number,title,state,url`. If no PR exists, flag and skip. If more than one open PR, ask the user which one to review.
- Record: `{ key, branch, prNumber, prUrl }`.

If **zero** sub-tasks have open PRs, report and exit.

## 3. Sequential per-PR review loop

Iterate through sub-task PRs in ascending key order (or the single parent PR for single-step issues). Treat each PR individually — do not hold results for a batch.

### 3a. Check idempotency — already reviewed by me?

Before reviewing a PR, check if **this skill's GitHub identity** has already left a review on it:

```bash
gh pr view <prNumber> --json reviews --jq '.reviews[] | select(.author.login == "<your-github-login>")'
```

- **An approving review already exists** → report the PR as "already approved — waiting for manual merge" and move to the next PR without re-reviewing.
- **A "changes requested" review already exists** → re-review: this is a fix-and-re-run scenario, and fresh code may have been pushed since. Continue to 3b.
- **No prior review from this identity** → continue to 3b.

For the single-step parent PR, use the same idempotency check.

### 3b. Fetch the diff

```
gh pr diff <prNumber>
```

Read the full diff. If it's very large (>1000 lines), list changed files via `gh pr diff <prNumber> --name-only` and `Read` relevant files for context. Do not skip any file in the diff.

### 3c. Review criteria

Evaluate the diff against these dimensions (all must pass for approve):

1. **Correctness** — Does the code fulfill the Jira description without bugs?
2. **Pattern consistency** — Matches codebase naming, structure, and idioms?
3. **No scope creep** — The change only addresses what the sub-task (or single-step issue) describes. Unrelated refactors, formatting changes, or "while I'm here" additions belong in a separate issue. Flag these but don't block on trivial cases (e.g. a typo fix in an adjacent comment is fine; a refactor of an unrelated module is not).
4. **No obvious regressions** — Won't break imports, types, or dependencies.
5. **Test coverage** — Has corresponding test coverage if changes are non-trivial.
6. **Build hygiene** — No debug leftovers (`console.log`, TODO markers not in original codebase style), no accidentally-committed files (`.env`, large binaries, etc.).

### 3d. Execute verdict immediately

* **If APPROVE (all dimensions pass):**

  1. **Approve on GitHub**:
     ```
     gh pr review <prNumber> --approve --body "<concise review summary, 2-5 sentences>"
     ```

  2. **Post a Jira comment to the sub-task (or parent for single-step)** (via heredoc, per the global convention):
     ```bash
     cat <<'EOF' | jira issue comment add <SUBTASK-KEY-or-PARENT-KEY> --template -
     PR #<prNumber> has been reviewed and approved.

     **Review summary:**
     <2-3 sentences: what was reviewed and any notable observations>
     EOF
     ```
     Do NOT move the Jira status — let the GitHub-for-Jira automation handle it when the PR is merged.

* **If REQUEST_CHANGES (one or more dimensions fail):**

  1. **Reject the PR on GitHub**:
     ```
     gh pr review <prNumber> --request-changes --body "<findings summary>"
     ```

  2. **Move the sub-task to `<STATUS_IN_PROGRESS>`** and post the findings as a Jira comment on the sub-task (or parent for single-step):
     ```bash
     jira issue move <SUBTASK-KEY-or-PARENT-KEY> "<STATUS_IN_PROGRESS>"
     cat <<'EOF' | jira issue comment add <SUBTASK-KEY-or-PARENT-KEY> --template -
     PR #<prNumber> failed code review. Moving the issue back to In Progress.

     ### Findings:
     <Clear file:line findings and required changes>
     EOF
     ```

  3. **Remember** this PR as blocked. Continue the loop — review the next sub-task PR.

### 3e. Post a summary on the parent after each sub-task

Regardless of whether the review above was approve or reject, immediately post a short summary to the parent Jira issue `<PARENT-KEY>` so the progress is visible in one place:

```bash
cat <<'EOF' | jira issue comment add <PARENT-KEY> --template -
Review update for sub-task <SUBTASK-KEY> (PR #<prNumber>):
- Status: **APPROVED** / **CHANGES REQUESTED**
- <If approved: one sentence of what was reviewed>
- <If rejected: brief note, full details are in the sub-task's own comment>
EOF
```

*For single-step issues, the post-review summary goes to the parent (which is the same issue), so this step still applies.*

## 4. After all sub-task PRs have been reviewed (loop complete)

Once the loop in step 3 has processed every In Review sub-task PR (or the single parent PR for single-step issues), the reviewer ends the session with a report **even if some were rejected**. The human fixes and re-runs; on a later run, any sub-tasks whose Jira status is no longer `<STATUS_IN_REVIEW>` will be skipped, and only resumed-yet-still-in-review items are picked up.

At this point the outcomes are mutually exclusive:

### 4a. All approved — merge and re-run (multistep only)

1. Check if **all** of those PRs are already merged (`gh pr view <prNumber> --json state` for each).
2. **If some are still open** → report: "All approved. Merge manually, then re-run `/jira-sdlc:jira-task-reviewer <PARENT-KEY>` to pick up the parent PR."
3. **If all are merged** → proceed to step 5 (parent PR handling).

### 4b. Some rejected — report and stop

1. **Do not** proceed to the parent PR, regardless of how many other sub-tasks were approved.
2. In the report, list **both** approved and rejected items so the human sees the full state.
3. End the session: the human fixes the rejected sub-tasks, waits for the executor to move them back to `<STATUS_IN_REVIEW>`, then re-runs `/jira-sdlc:jira-task-reviewer <PARENT-KEY>`.

### 4c. Single-step issue — PR reviewed, wait for merge

For single-step issues (no sub-tasks), after the PR is reviewed in step 3:

- **If approved** → report: "Single-step issue `<PARENT-KEY>` PR #<prNumber> approved. Merge manually into `<BASE_BRANCH>`, then re-run `/jira-sdlc:jira-task-reviewer <PARENT-KEY>` for post-merge wrap-up."
- **If changes requested** → report the findings. The human fixes, pushes, and re-runs the reviewer.

## 5. Parent PR management (multistep only — runs when all sub-task PRs are merged)

*Runs only for multistep parents when all sub-task PRs are merged into `<PARENT-BRANCH>` (either the user merged them, or they were already merged before this run).*

### 5a. Find or create the parent PR

```
gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --json number,title,state,url
```

- **No PR exists** → create one:
  ```
  gh pr create --base <BASE_BRANCH> --head <PARENT-BRANCH> \
    --title "<PARENT-KEY>: <summary>" \
    --body "Aggregate PR for <PARENT-KEY>. Sub-tasks merged: <list of keys + PR links>."
  ```
- **PR exists (state OPEN)** → use it.
- **PR exists and is MERGED** → go straight to step 6 (post-merge actions).
- **PR exists and is CLOSED** → stop and let the user decide (same rule as before).

### 5b. Review the parent PR (apply same idempotency check from 3a first)

A parent PR should only be reviewed once. If the `reviews` field already contains an entry from this skill's identity, report "Parent PR already reviewed — waiting for manual merge" and skip the review. Otherwise:

1. Review the aggregate diff: same criteria as 3c, but lighter. The sub-tasks were already reviewed individually — focus on integration issues, conflicts, and anything that only surfaces when the pieces combine.
2. **If approved** → `gh pr review <prNumber> --approve --body "<summary>"`. Do NOT merge.
3. **If changes requested** → `gh pr review <prNumber> --request-changes --body "<findings>"`. Report the findings and stop.

*Do not merge here.* Report that the parent PR is reviewed/approved and waiting for the user to merge it manually.

## 6. Post-merge wrap-up

Runs when a parent PR already merged is detected (step 5a phase check or step 1 phase check). For single-step issues, this runs after the human merges the single PR and re-runs the reviewer.

GitHub-for-Jira will already have moved all related issues to `<STATUS_DONE>`, but a clean Jira comment on the parent is useful for the historical record:

```bash
cat <<'EOF' | jira issue comment add <PARENT-KEY> --template -
All sub-tasks approved and parent branch merged into <BASE_BRANCH>.

Sub-tasks:
- <SUBTASK-KEY>: PR #<n> — merged
- ...
EOF
```

*For single-step issues, the "Sub-tasks" section simply lists the single issue and its PR.*

Optionally list any orphaned local branches (`git branch --merged origin/<BASE_BRANCH>`) and report them. Don't auto-delete local branches.

## 7. Report back

Post the review summary to the user in chat **and** as a single Jira comment on `<PARENT-KEY>` using the global heredoc convention. Construct the layout using the conditional structures below depending on the outcome:

```markdown
## Review Status: <OUTCOME_TITLE>
<!--
  Outcomes:
  - "All sub-task PRs approved — merge manually and re-run"
  - "Some PRs approved, some blocked — see below"
  - "All sub-tasks merged — parent PR ready"
  - "Fully complete — parent PR merged"
  - "Single-step PR approved — merge manually and re-run"
  - "Single-step PR changes requested — see findings"
  - "Single-step PR merged — complete"
-->

Parent: <PARENT-KEY> (<PARENT-BRANCH> → <BASE_BRANCH>)

### Pull Request Summary
- <KEY> PR #<n>: [✅ approved | ❌ changes requested | ⏳ skipped]
- ...

### [Details / Next Steps]
<!-- IF ALL APPROVED (multistep): -->
Parent PR #<n>: ✅ reviewed and approved. Merging is manual — merge it yourself on GitHub when ready: <PR URL>
Once merged, re-run /jira-sdlc:jira-task-reviewer <PARENT-KEY> to post the final Jira update.

<!-- IF FULLY COMPLETE (parent PR merged): -->
Parent PR #<n>: ✅ merged into <BASE_BRANCH> (Jira auto-transitioned by GitHub-for-Jira).

<!-- IF SINGLE-STEP APPROVED: -->
Single-step PR #<n>: ✅ reviewed and approved. Merging is manual — merge it yourself on GitHub when ready: <PR URL>
Once merged, re-run /jira-sdlc:jira-task-reviewer <PARENT-KEY> to post the final Jira update.

<!-- IF SINGLE-STEP MERGED: -->
Single-step PR #<n>: ✅ merged into <BASE_BRANCH> (Jira auto-transitioned by GitHub-for-Jira).

<!-- IF SOME BLOCKED (multistep): -->
#### Approved PRs (waiting for manual merge)
- <KEY> PR #<n>: <PR URL>
- ...

#### Blocked PRs (need fixes)
<BLOCKED-KEY> PR #<n>: <PR URL>
1. <file>:<line> — <what's wrong>
2. ...

<BLOCKED-KEY> PR #<n>: <PR URL>
1. <file>:<line> — <what's wrong>
2. ...

#### Next step:
Fix the findings above in each blocked branch, push, then re-run /jira-sdlc:jira-task-reviewer <PARENT-KEY>.
```

## 8. Edge cases

- **No sub-tasks in review status, but sub-tasks exist** → report that the executor hasn't pushed any PRs to In Review yet; the user may re-run later.
- **Sub-task with no branch / no PR**: flag in the report. The skill can only review what has been pushed and has a PR open. Don't attempt to create branches or PRs — that's the executor's job.
- **PR already approved by someone else**: The skill still does its own review — an existing approval doesn't skip the code review step. It's fine for a PR to have multiple approving reviews.
- **Already reviewed by this skill (idempotency)**: see 3a. The skill skips re-review to avoid wasted work. If the user wants a forced re-review, they can flag it manually.
- **`gh` not installed or not authenticated**: Report the error and give the user the PR URLs so they can review/merge manually.
- **Parent branch is behind its base**: If `<BASE_BRANCH>` has advanced, the parent PR may show conflicts. Stop and report. The user can rebase `<PARENT-BRANCH>` onto `<BASE_BRANCH>` and re-run.
- **Single-step PR merged before reviewer runs**: The phase check in step 1 detects this and jumps straight to step 6.

Reference: `../_shared/jira-cli-reference.md` has the full jira-cli syntax, confirmed issue types, and git/branch conventions. The `jira-tools-plugin.env` file in the project root has this repo's specific values for every `<TOKEN>` used above.