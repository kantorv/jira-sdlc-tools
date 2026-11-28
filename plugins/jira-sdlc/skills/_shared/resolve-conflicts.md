# Resolve mode: the executor resolves a paused merge conflict

`jira-task-executor` loads this file only when its notes' first line is exactly
`mode=resolve-conflicts`. Every other run keeps step 2's rule: never resolve a
merge conflict on its own.

A merge conflict pauses the issue: `repos.sh gate` reads `phase=conflict`
(the branch conflicts with its base in a repo whose merge is still ahead), and
nothing reviews, lands or merges it until it is resolved and the resolution
is reviewed. This run is one way out. It merges the base, resolves the files
the gate named using both sides' intent, adds tests for any overlap, runs the
gates, and pushes **one merge commit per repo**. The reviewer's *resolution
review* checks it next. The run is asked for by a human, or started by a
standing grant (the web app's). Claude Code's own permission asks inside it
stay the human's either way.

Discovery, the credential block and step 1 (provision, bootstrap, the issue
fetch) run as usual. Step 3's status transition does not: the issue keeps its
status. Then follow R1 to R8 below in place of steps 2 to 12. `$S` is the
scripts directory, as in the skill. Everything below is POSIX. On Windows, use
the `win/` twins, with the same arguments and output.

**Stop and ask** (AskUserQuestion), and end with the not-resolved marker if
the answer doesn't settle it, on anything outside this mode's scope:

- a conflicted file the gate didn't name;
- a sensitive file (below) without the `sensitive=yes` line;
- a gate that fails and can't be fixed within the resolution;
- a conflict whose two intents you can't both read.

A guess at a resolution is worse than a pause, because the next step merges
it.

## R1. Read the pause

```bash
S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"
bash "$S/repos.sh" gate --branch "$(git branch --show-current)"
bash "$S/repos.sh" conflicts --branch "$(git branch --show-current)"
```

- `phase=` anything but `conflict` → nothing to resolve. End with
  `CONFLICT NOT RESOLVED: the gate reads <phase>, not conflict`.
- The `conflicts` rows **against the base** (`against` = `origin/<base>`)
  with `result=conflict` are the work: per repo, its `files`, then
  `sensitive` and `recipe`. Rows against another issue's branch are warnings
  only: leave them.
- **Sensitive** files (`.jst/`, `stack`, `stack.d/`, `.github/workflows/`,
  migrations; the `sensitive` column is the plugin's reading, so don't keep
  your own list) are a human's to resolve. Resolve one only when the notes
  hold the line `sensitive=yes`, which means a human chose the agent for it.
  Otherwise end with
  `CONFLICT NOT RESOLVED: sensitive path <repo>:<file> needs a human`.
- **Recipe** files (`gitlink:<path>`, `migration-number:<path>`) are
  mechanical. R4 says how, and the report says a recipe was used.

## R2. Read both intents

- **This side**: the issue's summary and description (step 1b), and this
  branch's own changes to each conflicted file:
  `git -C <repo> diff $(git -C <repo> merge-base HEAD origin/<base>) HEAD -- <files>`.
- **The other side**: the issue whose landing moved the base. Its commits are
  `git -C <repo> log --format='%H %s' <merge-base>..origin/<base>`. A landing
  commit names its key (`<KEY>: land …`, or a merge of
  `feature/<KEY>-…`). Fetch that issue with
  `jira.sh --role executor issue view <OTHER-KEY> --fields 'summary,description'`,
  and read its diff of the same files:
  `git -C <repo> diff <merge-base> origin/<base> -- <files>`.

Several issues landed since the merge base → read each one that touched a
conflicted file. One whose intent you can't find → stop and ask.

## R3. Merge the base

- **Members** (each with a base `conflict` row): `bash "$S/repos.sh" sync`.
  It merges `origin/<base>` into each member on the issue branch and stops at
  the first conflict (`conflict=<repo>`, `files=`), leaving that merge in
  progress for you. Resolve it (R4), commit (R6), then run `sync` again until
  it reports no conflict.
- **The root** (a `.` row): `git fetch origin`, then
  `git merge --no-ff --no-commit origin/<base>`.

Before resolving, compare git's conflicted files
(`git -C <repo> diff --name-only --diff-filter=U`) with the gate's. Any file
the gate didn't name → `git -C <repo> merge --abort` and stop: the base moved
again since the pause, so the pause and this run disagree. Refresh in the app
reads it again.

## R4. Resolve each hunk

For every conflicted hunk, keep **both intents**: what this issue's change is
for, and what the other issue's change is for. Usually that means combining
them, not choosing one. Choose one side only when the other side's change is
already contained in it, and say so. Write down per hunk what you kept from
each side, for R7's report.

The recipes, applied first and named in the report:

- **`gitlink:<path>`**: a member pointer both sides moved, where one commit
  contains the other. Take the containing commit
  (`git -C <repo> update-index --cacheinfo 160000,<sha>,<path>`, and
  `git -C <repo>/<path> checkout --detach <sha>`), as `repos.sh land`'s
  gitlink step does.
- **`migration-number:<path>`**: both sides added a numbered migration at the
  same path. Renumber this branch's migration onto the base's latest leaf:
  rename it to the next free number, point its `dependencies` at that leaf,
  and update any later migration of this branch that depends on it. If its
  number has already been applied somewhere shared (another instance's
  database, a deployed one), add a merge migration instead (the framework's
  own: Django's `makemigrations --merge`). Then check the merged tree for two
  leaves with the same number in one app: a clean merge can leave that too.

## R5. Test the overlap, run the gates

- Where both sides changed the same behaviour (not just neighbouring lines),
  add a test that exercises both intents on the merged code, so a later
  change can't drop one silently. Example: one side added a marker line and
  the other rewrote the file it sits in, so the test checks that the marker
  survives the rewrite.
- Run the project's gates on the merge result, as step 7 finds them: every
  repo that has a conflict, its full suite, plus lint and build where the
  project runs them. A failure caused by the merge is fixed within the
  conflicted files and the new tests. Anything wider means `merge --abort`,
  then stop and ask.

## R6. One merge commit per repo

Stage only the resolved files and the new tests, then commit the merge with a
message the resolution review recognises:

```bash
git -C <repo> commit -F - <<'EOF'
<KEY> merge <base>: resolve <n> conflicted file(s)

<one line per hunk: file, what was kept from each side>

Conflict-Resolved: <file> <file> …
Conflict-Recipe: <recipe>:<path> …        (only when a recipe was used)
Resolved-By: jira-task-executor (resolve mode)
EOF
```

The `Conflict-Resolved:` trailer is what `repos.sh resolutions` reads as
`by=agent`. Then push every repo: `bash "$S/repos.sh" push` (members first,
the root last). Never stage a member's folder in the root by hand. The
gitlink recipe's pointer is the one exception, and only in the root's own
merge.

## R7. Check the pause lifted, then report

- `repos.sh gate` again. It should read something other than `conflict`
  (normally `review`). Still `conflict` → end with
  `CONFLICT NOT RESOLVED: the gate still reads conflict: <reason>`.

- Post one comment per PR whose repo you resolved
  (`gh.sh pr comment <pr> -R <slug> --body-file …`): the merge commit and the
  per-hunk table. The resolution review reads it.

- Post the run report as the issue's Jira comment (step 12's mechanics), and
  say it in chat. It covers:

  - the conflict as the gate named it;
  - each hunk, with what it kept from each side;
  - the recipes used;
  - the tests added and the gates' results;
  - each repo's merge commit;
  - what happens next: the resolution review.

  Don't move the issue's status, and open no PR.

## R8. The marker: always the last line

The web app reads the run's outcome from its last line, so it must be exactly
one of these, alone on the line:

```
CONFLICT RESOLVED <repo>@<sha> [<repo>@<sha> …]
CONFLICT NOT RESOLVED: <reason>
```

`<repo>` is `.` for the root, else the member's path. `<sha>` is that repo's
pushed merge commit. Every stop above ends with the not-resolved marker and
its reason, after `git merge --abort` in any repo still mid-merge, so the
worktree is left as it was found.
