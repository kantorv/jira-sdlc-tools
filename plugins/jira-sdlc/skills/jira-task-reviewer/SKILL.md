---
name: jira-task-reviewer
description: Given a parent Jira issue key (e.g. PROJ-286), reviews all sub-task PRs targeting the parent branch, approves or requests changes per-PR, merges approved PRs into the parent branch, then prepares the parent branch's own PR into its base (typically the project's default base branch) for the user to merge manually. Stops on first rejection and reports which PRs blocked.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob
---

You are acting as the code reviewer and release integrator for the
**`<PROJECT-KEY>`** project. Given a parent Jira issue key ($ARGUMENTS,
e.g. `PROJ-286`):

**Conventions used below:**
- `<PARENT-KEY>` = the Jira issue key passed as $ARGUMENTS.
- `<PARENT-BRANCH>` = the git branch for `<PARENT-KEY>`, always named
  `feature/<PARENT-KEY>-<slug>` or `hotfix/<PARENT-KEY>-<slug>`.
- `<BASE_BRANCH>` = whatever `<PARENT-BRANCH>` itself should merge into
  (typically `<DEFAULT_BASE_BRANCH>` — see
  the `.env` file in the project root) — recovered from
  `git config branch.<PARENT-BRANCH>.parentbranch` (set by
  `jira-task-assigner` when it created the branch), falling back to that
  issue's `"PR target branch: ..."` Jira comment if the config is missing.
- Sub-task PRs all target `<PARENT-BRANCH>`.
- Auth follows `../_shared/jira-cli-reference.md` §0 — check
  `JIRA_API_TOKEN` first, fall back to `<JIRA_TOKEN_PATH>` (see
  the `.env` file in the project root).

## 1. Resolve the parent, sub-tasks, and current phase

- `git fetch origin --prune` first. Branches created or merged by
  parallel sub-task executors (possibly from different worktrees) may
  not be visible locally yet, and merged sub-task branches get deleted
  remotely — every branch lookup below depends on this being current.
- Fetch the parent issue: `jira issue view <PARENT-KEY> --raw`.
  Confirm `fields.issuetype.name` is a top-level type (`Task`,
  `Story`, `Bug`). If it's a `Sub-task`, stop — this skill operates
  on parent issues only; the user should pass the parent key, not a
  sub-task key.
- Extract sub-task keys from `fields.subtasks` (CHECK the exact shape
  once against real output — likely an array of objects, i.e.
  `fields.subtasks[].key`, not bare strings). If empty, there's
  nothing to review — report and exit.
- Resolve `<PARENT-BRANCH>`:
  `git branch -a | grep <PARENT-KEY>`. Exactly one match → that's the
  parent branch. Zero or multiple → ask the user rather than guessing.
- Resolve `<BASE_BRANCH>` per the convention above. Only ask the user if
  both the config and the Jira-comment fallback come up empty.
- **Check the current phase** —
  `gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --state all --json number,state,url`:
  - **No PR found** → sub-tasks haven't all been merged yet (or haven't
    been reviewed at all). Continue to step 2 for a normal review pass.
  - **A PR exists** (open, merged, or closed) → every sub-task PR was
    already reviewed and merged in an earlier run — step 4a only ever
    runs once every sub-task PR is approved, so a parent PR existing at
    all means that already happened. Skip straight to step 4b; don't
    re-discover or re-review sub-tasks, there's nothing left to review.

## 2. Discover open PRs for each sub-task

For each `<SUBTASK-KEY>` from step 1:

- Find its branch: `git branch -a | grep <SUBTASK-KEY>`. If no branch
  exists yet, that sub-task hasn't been implemented — flag it in the
  report and skip it (no PR to review).
- Find the open PR: `gh pr list --head <subtask-branch> --base
  <PARENT-BRANCH> --json number,title,state,url`. If no PR exists,
  flag and skip. If more than one open PR for the same head branch,
  ask the user which one to review.
- Record: `{ key, branch, prNumber, prUrl }`.

If **zero** sub-tasks have open PRs, report and exit.

## 3. Sequential per-PR review

Process sub-task PRs **one at a time, in sub-task key order** (ascending
— this just gives a deterministic, reproducible review order. The
assigner currently creates sub-tasks as independent, parallelizable work
with no dependency ordering between them, so this order doesn't imply
anything about which piece depends on which). For each PR:

### 3a. Fetch the diff

```
gh pr diff <prNumber>
```

Read the full diff. If it's very large (>1000 lines), also read the
individual files for context where the diff alone isn't sufficient:
```
gh pr diff <prNumber> --name-only   # list changed files
```
Then `Read` the relevant files as needed. Do **not** skip any file in
the diff.

### 3b. Review criteria

Evaluate the diff against these dimensions (all must pass for approve):

1. **Correctness** — Does the code do what the sub-task's Jira
   description says? No logic bugs, off-by-ones, wrong conditions.
2. **Pattern consistency** — Does the change match existing codebase
   patterns and conventions (naming, file structure, state-management/
   UI-framework idioms, i18n approach, etc.)? Refer to
   `<CONVENTIONS_PATH>` (see the `.env` file in the project root — `project-config.md`
   also lists `<CONVENTION_HIGHLIGHTS>`, specific patterns worth extra
   attention in this codebase, if any were configured).
3. **No scope creep** — The change should only address what the
   sub-task describes. Unrelated refactors, formatting changes, or
   "while I'm here" additions belong in a separate issue. Flag these
   but don't block on trivial cases (e.g. a typo fix in an adjacent
   comment is fine; a refactor of an unrelated module is not).
4. **No obvious regressions** — Would this change break existing
   functionality? Check imports, exports, type signatures, and any
   files that depend on the changed code.
5. **Test coverage** — If the change is significant (new feature,
   bug fix, non-trivial logic), there should be corresponding test
   coverage. For trivial changes (config, docs) this is not required.
6. **Build hygiene** — No debug leftovers (`console.log`, TODO
   markers that aren't in the original codebase style), no
   accidentally-committed files (`.env`, large binaries, etc.).

### 3c. Record verdict

For each PR, record one of:

- **APPROVE** — all dimensions pass. Save the summary of what was
  reviewed (1–3 sentences per dimension, for the final report).
- **REQUEST_CHANGES** — one or more dimensions failed. Save the
  specific findings with file and line references, and what needs to
  change.

### 3d. Early exit on first rejection

If a PR gets **REQUEST_CHANGES**, **stop the review loop** — do not
continue to the next sub-task PR. The user needs to fix the blocked PR
before the rest can be batch-approved. Record which PRs were reviewed
(and their verdicts) and which were not yet reviewed.

Skip to step 5 (report back). Step 4 (merge cascade) only happens when
all reviewed PRs get **APPROVE**.

## 4. Merge cascade (all PRs approved)

This step only executes if every PR reviewed in step 3 received
**APPROVE**.

### 4a. Approve and merge each sub-task PR

For each sub-task PR (same key order as step 3):

1. **Formal review**:
   ```
   gh pr review <prNumber> --approve --body "<review summary>"
   ```
   The review body should be concise: 2–5 sentences covering
   correctness, pattern consistency, and anything notable.

2. **Merge**:
   ```
   gh pr merge <prNumber> --squash --delete-branch
   ```
   Using `--squash` keeps the parent branch history clean — one commit
   per sub-task, matching the Jira key. `--delete-branch` keeps the
   remote tidy.

3. **Verify**: `gh pr view <prNumber> --json state` — confirm
   `state == "MERGED"`. If not merged, stop and report — don't assume.

4. **Jira update**: Post a comment on the sub-task recording the
   merge (see `../_shared/jira-cli-reference.md` §6 for comment
   variants — single-line via positional arg, multi-line via heredoc
   to `--template -`, or `echo ... | --template -`):
   ```
   echo "PR #<prNumber> approved and merged into <PARENT-BRANCH>." | \
     jira issue comment add <SUBTASK-KEY> --template -
   ```

### 4b. Prepare the parent PR — review only, merging is manual

This step runs once all sub-task PRs are merged into `<PARENT-BRANCH>` —
either just now (4a, this run) or in an earlier run, detected via the
phase check in step 1.

1. Find or create the PR from `<PARENT-BRANCH>` to `<BASE_BRANCH>`:
   ```
   gh pr list --head <PARENT-BRANCH> --base <BASE_BRANCH> --json number,title,state,url
   ```
   - **No PR** → create one:
     ```
     gh pr create --base <BASE_BRANCH> --head <PARENT-BRANCH> \
       --title "<PARENT-KEY>: <summary>" \
       --body "Aggregate PR for <PARENT-KEY>. Sub-tasks merged: <list of keys + PR links>."
     ```
   - **PR exists** → use it.

2. Check its current state:
   `gh pr view <prNumber> --json state,reviewDecision,reviews`.
   - **`state == MERGED`** → the user already merged it manually since
     the last run. Skip the rest of this step — go straight to 4c.
   - **`state == CLOSED`** (closed without merging) → stop, report it,
     and ask the user what they want to do. Don't reopen it or create a
     replacement PR without being asked.
   - **`state == OPEN`** → continue below.

3. If this skill hasn't already left an approving (or requesting-changes)
   review on this PR — check the `reviews` field for one from a prior
   run before redoing this — review the aggregate diff: same criteria as
   3b, but lighter. The sub-tasks were already reviewed individually, so
   focus on integration issues, conflicts, and anything that only
   surfaces when the pieces combine.
   - **Passes** → `gh pr review <prNumber> --approve --body "<summary>"`.
   - **Fails** → `gh pr review <prNumber> --request-changes --body
     "<findings>"`. Report the findings the same way as a sub-task
     rejection (step 3d/5) and stop here — don't proceed to step 4.

4. **Do not call `gh pr merge` here.** Merging the parent branch into
   `<BASE_BRANCH>` is a deliberate release decision — leave it to the
   user. Report that the parent PR is reviewed/approved (or already was,
   on a resumed run) and is waiting for them to merge it manually, with
   the PR URL. Then stop — step 4c only runs on a later invocation, once
   it detects `state == MERGED`.

### 4c. Post-merge actions

Runs only once step 4b's state check finds `state == MERGED` — in
practice this means the user merged the parent PR manually since the
previous run, and this invocation is picking that up.

1. **Jira update** — comment on `<PARENT-KEY>`. For this multi-line
   report use the heredoc pattern (see `../_shared/jira-cli-reference.md`
   §6; never wrap markdown in a quoted inline string — backticks are
   interpreted as command substitution):
   ```
   cat <<'EOF' | jira issue comment add <PARENT-KEY> --template -
   All sub-tasks approved and merged. Parent branch
   <PARENT-BRANCH> merged into <BASE_BRANCH>.

   Sub-tasks:
   - <SUBTASK-KEY>: PR #<n> — merged
   - <SUBTASK-KEY>: PR #<n> — merged
   - ...
   EOF
   ```

2. **Cleanup**: `git fetch origin` — refresh remote refs. Optionally
   list any orphaned local branches
   (`git branch --merged origin/<BASE_BRANCH>`) and report them. Don't
   auto-delete local branches — that's the user's call.

## 5. Report back

Post the review summary to the user in chat **and** as a single Jira
comment on `<PARENT-KEY>`. Three possible outcomes:

### A. Parent PR ready, waiting for manual merge
```
## Sub-tasks merged — parent PR ready for manual merge

Parent: <PARENT-KEY> (<PARENT-BRANCH> → <BASE_BRANCH>)
Sub-tasks:
- <KEY> PR #<n>: ✅ APPROVED + merged
- <KEY> PR #<n>: ✅ APPROVED + merged
- ...

Parent PR #<n>: ✅ reviewed and approved. Merging is manual for this
step — merge it yourself on GitHub when ready: <PR URL>
Once merged, re-run /jira-sdlc:jira-task-reviewer <PARENT-KEY> to post
the final Jira update and check for orphaned branches.
```

### B. Fully complete (parent PR already merged manually)
```
## Review complete — all PRs merged

Parent: <PARENT-KEY> (<PARENT-BRANCH> → <BASE_BRANCH>)
Sub-tasks:
- <KEY> PR #<n>: ✅ APPROVED + merged
- <KEY> PR #<n>: ✅ APPROVED + merged
- ...

Parent PR #<n>: ✅ merged into <BASE_BRANCH> (merged manually by the user)
```

### C. Review blocked — changes requested
```
## Review blocked — changes requested

Parent: <PARENT-KEY> (<PARENT-BRANCH>)

Reviewed:
- <KEY> PR #<n>: ✅ APPROVED
- <KEY> PR #<n>: ❌ REQUEST_CHANGES

Not yet reviewed:
- <KEY> PR #<n> (skipped)
- ...

### Findings for <BLOCKED-KEY> PR #<n>:
1. <file>:<line> — <what's wrong>
2. ...

### Next step:
Fix the findings above in <blocked-branch>, push, then re-run
/jira-sdlc:jira-task-reviewer <PARENT-KEY>.
```
This template applies whether the blocked PR was a sub-task's or the
parent's own aggregate PR (step 4b.3) — same structure either way.

(The `/jira-sdlc:` prefix above assumes this skill is installed as the
`jira-sdlc` plugin — adjust if you renamed it, or drop the prefix if
you installed these skills as loose files rather than as a plugin.)

### Jira comment mechanics

Since the report is multi-line, **always pipe via heredoc to
`--template -`** (see `../_shared/jira-cli-reference.md` §6).
Single-line comments can use the positional `jira issue comment add
<KEY> "<text>"` form. Never wrap markdown in a quoted inline
string — backticks are interpreted as command substitution:
```
cat <<'EOF' | jira issue comment add <PARENT-KEY> --template -
<the report content>
EOF
```

## 6. Re-run semantics

Each invocation checks the current phase first (step 1) rather than
blindly repeating the whole flow:

- **No parent PR exists yet** → full review from step 2: re-discovers
  all open sub-task PRs and reviews everything again. This is
  intentional — previously-approved PRs may have new commits since the
  last run, and an early exit means some PRs were never reviewed at all.
  Re-reviewing is cheap (the diff is usually small).
- **A parent PR exists and is still open** → sub-tasks are already done;
  this run only checks/refreshes the aggregate review (4b) and reports
  the current status. It will not re-discover or re-review sub-tasks.
- **A parent PR exists and is now merged** → this run does the
  post-merge wrap-up (4c) and nothing else.

If the user wants to skip re-reviewing a previously-approved sub-task PR
during a full review pass, they should mention the PR number explicitly —
the skill will still verify it but can note it was previously approved.

## 7. Edge cases

- **Sub-task with no branch / no PR**: Flag in the report. The skill
  can only review what has been pushed and has a PR open. Don't attempt
  to create branches or PRs — that's the executor's job. (In practice
  this shouldn't come up for a parent that's already past the sub-task
  phase, per the phase check in step 1 — but can still happen mid-flight
  if a sub-task simply hasn't been picked up yet.)
- **Conflicts on merge**: If `gh pr merge` reports merge conflicts
  during 4a, stop — report the conflict and let the user resolve it.
  Don't attempt automatic conflict resolution.
- **Parent branch is behind its base**: If `<BASE_BRANCH>` has advanced
  (someone merged into it) while sub-tasks were being merged
  into `<PARENT-BRANCH>`, the parent PR in 4b may show conflicts. The
  same rule applies — stop and report. The user can rebase
  `<PARENT-BRANCH>` onto `<BASE_BRANCH>` and re-run.
- **Parent PR closed without merging**: If `gh pr view` reports
  `state == CLOSED` (not `MERGED`) when checked in 4b, stop and ask the
  user what they want to do — don't reopen it or create a replacement PR
  without being asked.
- **PR already approved by someone else**: If a sub-task or parent PR
  already has an approving review, the skill still does its own review —
  an existing approval doesn't skip the code review step. It's fine for
  a PR to have multiple approving reviews.
- **`gh` not installed or not authenticated**: Report the error and
  give the user the PR URLs so they can review/merge manually.

Reference: `../_shared/jira-cli-reference.md` has the full jira-cli
syntax, confirmed issue types, and git/branch conventions.
The `.env` file in the project root has this repo's specific values for
every `<TOKEN>` used above.
