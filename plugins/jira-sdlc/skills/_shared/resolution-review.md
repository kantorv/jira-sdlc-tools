# The resolution review: a conflict-resolving merge, reviewed against both sides

`jira-task-reviewer` loads this file from step 3a. A PR's latest verdict from
this identity is `APPROVED —`, but `repos.sh since` reads
`verdict=resolution-review`: every commit pushed since is a merge that resolved
a conflict or a clean merge of the base. Anything else pushed since (a plain
commit, a rebase, a clean merge with edits of its own) is 3a's full re-review,
never this one. The executor's resolve mode made such a merge (`by=agent`, a
`Conflict-Resolved:` trailer), or a human did (`by=hand`).

The earlier approval covers the code the reviewer saw, and the merge is code it
never saw. Rather than review the whole diff again, this review checks **what the
merge itself did**: each resolved hunk, against both sides' intent. Its verdict
then counts as the review after the merge commit. It is a fresh run. A run whose
notes start `mode=resolution-review` was asked for it by the web app, after a
merge-conflict pause, and its notes quote the conflict.

The same PR, the same verdict contract (`APPROVED — ` / `CHANGES REQUESTED — `,
the canonical report, 3d's mechanics). Only what is read and judged differs.

## 1. What to review

The `resolution` rows of 3a's `since`, each with its `repos.sh resolutions`
row for this PR's repo: a merge, the files it resolved, and `by`. More than one
→ review each, oldest first. A row in state `error` is unknown, never
"no merge": stop and say which repo.

For each merge `<M>` in `<repo>`:

```bash
git -C <repo> show --remerge-diff <M>          # the resolution: how M differs from git's own conflicted merge
git -C <repo> show --format=%B -s <M>          # the message: per-hunk notes, trailers
git -C <repo> diff <M>^1 <M> -- <files>        # what the merge brought onto this branch, per resolved file
git -C <repo> log --format='%H %s' <M>^1..<M>^2   # the other side's commits: its issue keys
```

`--remerge-diff` (git ≥ 2.36) shows git's conflict markers against the
committed result. It is exactly what a human or the resolver decided, and the
part no earlier review saw. Read the other side's issue (its key from the
landing commit, `jira.sh --role reviewer issue view <OTHER-KEY> --fields 'summary,description'`)
and this issue's description, so each hunk can be judged against both intents.
For the agent's merges, its PR comment and its Jira run report list each hunk
and what it kept. Check them against the diff, not instead of it.

## 2. The criteria

All must pass to approve:

1. **Both intents kept**, hunk by hunk: this issue's change still does what
   its issue says, and so does the other issue's. Dropping one side is a
   finding unless the other side contains it, and the merge's notes say so.
2. **Only the conflict**: the merge changes nothing beyond the conflicted
   files, the tests for their overlap and a recipe's own files (a migration
   renumbered, a gitlink moved). Anything else is scope creep inside a merge,
   which no review would see: a finding.
3. **The overlap is tested**: where both sides changed the same behaviour, a
   test exercises both on the merged code (resolve mode's R5). A purely
   textual conflict (neighbouring lines) needs none. Say which it was.
4. **The gates pass on the merge**: run the affected repo's suite as 3c's
   test dimension does, under its rules (never source a project's secrets).
   Report what couldn't be run.
5. **Recipes applied correctly**: a gitlink keeps the commit that contains
   both sides. A migration renumbered onto the base's leaf has its
   dependencies updated, and no two leaves share a number.
6. **Sensitive paths** (`.jst/`, `stack`, `stack.d/`, `.github/workflows/`,
   migrations): resolved in a `by=hand` merge, or by the agent only when a
   human chose it. The pause's card says which. A sensitive file the agent
   resolved under a grant alone is a finding.

## 3. The verdict

Post it as 3d does: the GitHub comment, the Jira transition on CHANGES
REQUESTED, and the canonical report. Its first line names the resolution, for
example `APPROVED — the resolution of <repo>'s merge <M7> keeps both sides` or
`CHANGES REQUESTED — <repo>'s merge <M7> drops <OTHER-KEY>'s <what>`. The
report's *What I reviewed* section lists each merge, its files, and per
hunk what it kept from each side, so a reader sees what was approved without
the diff.

An APPROVED verdict here is the review after the merge commit. The flow
resumes from it: in the web app, a landing paused on the conflict carries on,
and Merge comes back. CHANGES REQUESTED keeps the issue paused with the
findings as its reason. The fix is an executor run, then this review again.
