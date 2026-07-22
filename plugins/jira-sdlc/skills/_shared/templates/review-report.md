# Canonical review report — template + outcome catalogue

Reference for `jira-task-reviewer`. Read this once per run, before the
first report-shaped output you emit (normally 3d; 5b or 6 when the run
skips the review loop). Everything the skill emits in report shape is
**one and the same report**, defined here and only referenced from
`SKILL.md`:

- the GitHub PR verdict comments (3d approve/reject, 5b parent),
- the Jira per-issue comment (3d),
- the parent per-sub-task tally (3e), and
- the end-of-run chat + parent report (6).

Someone following one review across GitHub, Jira, and chat therefore sees
one layout at one level of detail. An emission varies along exactly two
axes — the section structure never changes:

- **PR set in scope** — a *per-PR* emission (3d, 5b, 3e) fills the report
  for the single PR just reviewed; the *end-of-run* emission (6) fills it
  for every PR in the run's PR set (step 1).
- **Which outcome block is filled** — exactly one, from the catalogue
  below, chosen by track × phase and (for a per-PR emission) by *which* PR.
  It supplies the `<OUTCOME_TITLE>` and the `### Next step` wording;
  everything else is identical across outcomes.

## Template — fill every section

```text
<VERDICT-HEADER>

## Review Status: <OUTCOME_TITLE>
Parent: <PARENT-KEY> (<PARENT-BRANCH> → <BASE_BRANCH>)

### Pull Request Summary
- <KEY> PR #<n>: [✅ approved | ❌ changes requested | ⏳ skipped] <PR URL>
- ...   (one line per PR in scope — a single PR for 3d/5b/3e, every PR in the set for 6)

### What I reviewed
- Track: <single-step | multistep>
- <KEY> PR #<n> — the six 3c dimensions, each ✅/❌ with a one-line note:
  Correctness · Pattern consistency · No scope creep · No obvious
  regressions · Test coverage · Build hygiene.
- Per-AC results, when the issue defines acceptance criteria:
  | # | Acceptance criterion | Result |
  |---|---|---|
  | 1 | <criterion> | ✅ / ❌ <note> |
- On the reject path, the `file:line` findings for each failed dimension
  (this is the detail the CHANGES REQUESTED verdict is made of — never drop it).

### Verdict recorded
- GitHub: <APPROVED / CHANGES REQUESTED comment on PR #<n>, or "—" if none posted this emission>
- Jira: <note posted on <KEY>; whether status moved to <STATUS_IN_PROGRESS>>

### Next step
<the chosen outcome block's `Next step` wording, below>
```

### `<VERDICT-HEADER>` — the load-bearing first line

Always the literal first line of the body, starting with `APPROVED — ` or
`CHANGES REQUESTED — ` followed by a one-line summary:

- On a **GitHub verdict comment** (3d, 5b) this prefix is a byte-for-byte
  contract — 3a's idempotency detection matches on it. Keep it verbatim;
  never reword the two-word prefix or the ` — ` separator.
- On the **Jira per-issue comment** (3d), the **parent tally** (3e), and
  the **end-of-run report** (6), the same line leads the body so every
  destination opens identically. On a per-PR emission it is that PR's
  verdict; on the end-of-run report it is the run's overall verdict
  (`CHANGES REQUESTED — …` whenever any PR in the set was rejected — e.g.
  M-SOME-BLOCKED — otherwise `APPROVED — …`, including the already-merged
  S-MERGED / M-FULLY-COMPLETE outcomes).

### One run-level render per run

A run posts **one** run-level report (step 6) on `<PARENT-KEY>`. The 3e
per-sub-task comments are its audit-trail companions, not competing
copies: each sub-task's verdict stands on its own permanent comment, so
they are posted fresh (never `-e/--edit-last`) while step 6 stays the
single run-level summary. That is the whole of the one-final-comment rule —
3e and 6 coexist by design.

Using this template changes shape only. The idempotency-detection contract
(3a) and the workflow gates (the reject transition to
`<STATUS_IN_PROGRESS>`, the "never merge" rule, step 7's confirmed
`<STATUS_DONE>` moves) are untouched — nothing here adds, removes, or
reorders a side-effect.

## Outcome catalogue

Pick **exactly one**. Never emit two.

The `S-*` and `M-*` blocks are what the **run-level** step-6 report chooses
from. The `M-SUBTASK-*` blocks are for **per-PR** emissions only (the 3d
verdict comment and its 3e reuse) — step 6 never selects them.

### Single-step track

- **S-APPROVED** — single-step PR approved, awaiting manual merge (final update — no re-run needed). Title: `Single-step PR approved — merge manually`. Next step:
  ```
  Single-step PR #<n>: ✅ reviewed and approved. Merging is manual — merge it yourself on GitHub when ready: <PR URL>.
  GitHub-for-Jira will auto-transition the issue to <STATUS_DONE> on merge. No re-run needed — this is the final update.
  ```
- **S-CHANGES-REQUESTED** — single-step PR rejected. Title: `Single-step PR changes requested — see findings`. (The `file:line` findings live in the report's `### What I reviewed` section.) Next step:
  ```
  Fix the findings above, push, then re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree).
  ```
- **S-MERGED** — single-step PR already merged (detected by the step-1 phase check). Title: `Single-step PR merged — complete`. Next step:
  ```
  Single-step PR #<n>: ✅ merged into <BASE_BRANCH> (Jira auto-transitioned by GitHub-for-Jira). No re-run needed.
  ```

### Multistep track (run-level)

- **M-ALL-APPROVED** — all sub-task PRs approved, some still open. Title: `All sub-task PRs approved — merge manually and re-run`. Next step:
  ```
  All sub-task PRs approved. Merge them manually into <PARENT-BRANCH>, then re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree) to pick up the parent PR.
  ```
- **M-SOME-BLOCKED** — some approved, some rejected. Title: `Some PRs approved, some blocked — see below`. The approved-vs-blocked split is already visible in `### Pull Request Summary` (✅ vs. ❌ per PR, with URLs) and the per-PR `file:line` findings in `### What I reviewed` — no separate breakdown section. Next step:
  ```
  Fix the findings above in each blocked branch, push, then re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree).
  ```
- **M-PARENT-READY** — all sub-tasks merged, parent PR reviewed/approved, awaiting manual merge into base. Title: `All sub-tasks merged — parent PR ready`. Next step:
  ```
  Parent PR #<n>: ✅ reviewed and approved. Merging is manual — merge it yourself on GitHub when ready: <PR URL>.
  GitHub-for-Jira will auto-transition all related issues to <STATUS_DONE> on merge. No re-run is needed after merge — this report is the final update, and no further action or skill call is expected on the issue.
  ```
- **M-PARENT-CHANGES-REQUESTED** — all sub-tasks merged, parent PR rejected on the 5b integration review. Title: `Parent PR changes requested — see findings`. (The integration `file:line` findings live in the report's `### What I reviewed` section — never dropped.) Next step:
  ```
  Fix the integration findings above on <PARENT-BRANCH>, push, then re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree) to re-review the parent PR.
  ```
- **M-FULLY-COMPLETE** — parent PR merged into base (detected by the step-1 phase check or step 5a). Title: `Fully complete — parent PR merged`. Next step:
  ```
  Parent PR #<n>: ✅ merged into <BASE_BRANCH> (Jira auto-transitioned by GitHub-for-Jira). No re-run needed.
  ```

### Per-sub-task-PR (3d/3e emissions only)

A sub-task PR is not single-step — it merges into `<PARENT-BRANCH>` rather
than `<BASE_BRANCH>`, and a reviewer re-run *is* required afterwards to
pick up the parent PR — so the `S-*` wording ("merge into `<BASE_BRANCH>`",
"final update, no re-run needed") would be wrong on it.

- **M-SUBTASK-APPROVED** — a sub-task PR approved. Title: `Sub-task PR approved — awaiting merge into parent`. Next step:
  ```
  Sub-task PR #<n>: ✅ reviewed and approved. It merges into <PARENT-BRANCH>, not <BASE_BRANCH> — merging is manual. Once every sub-task PR is approved and merged into <PARENT-BRANCH>, re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree) to pick up the parent PR. A re-run IS required — this is not the final update.
  ```
- **M-SUBTASK-CHANGES-REQUESTED** — a sub-task PR rejected. Title: `Sub-task PR changes requested — see findings`. (The `file:line` findings live in the report's `### What I reviewed` section.) Next step:
  ```
  Fix the findings above in the sub-task's branch and push; the executor re-run moves the sub-task back to <STATUS_IN_REVIEW>. Then re-run /jira-sdlc:jira-task-reviewer (bare, from the parent's worktree).
  ```
