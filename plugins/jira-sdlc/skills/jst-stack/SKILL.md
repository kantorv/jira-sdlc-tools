---
name: jst-stack
description: Build a project's `./stack` from its confirmed `.jst/STACK.md` — the stack contract's tool that runs the app in the main checkout and as instance N in every issue worktree — plus `stack.d/` and the `.jst/bootstrap.sh` / `teardown.sh` hooks the executor runs, then try it end to end with the trial (bootstrap, start, its URLs, restart, teardown, a leak check) in a throwaway checkout. For a project that already has a stack, changes only what the document lists. Lands everything as a PR on `chore/jst-stack` with the trial's report. Run it from the project root after the `jst-survey` PR is merged.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, AskUserQuestion
---

You are building **the user's project's stack**: the tool that runs the app in the main
checkout every day and as **instance N** in every issue worktree, so each issue gets a fully
working copy of the app beside the others. You build it from one input, the confirmed
`.jst/STACK.md`, and prove it with the trial before anyone merges it.

**Conventions** (as in `jst-survey`): run from the project root (with member repos, the
workspace root); `S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"` (unset → `../_shared/scripts/posix/`
from this skill's folder); `<TOKEN>`s come from statuscheck's rows; **never open
`.jst/jira-sdlc-tools.local.env` or any ignored env or secrets file** (their paths are facts,
their contents are not). The stack contract is bash: on Windows, stop with
`STACK NOT WRITTEN: Windows is not supported yet (use WSL)`.

**The last line of your final message is the marker**: `STACK WRITTEN <PR url>`,
`STACK SKIPPED <PR url>` (a `toolchain` project: hook only), or `STACK NOT WRITTEN: <reason>`.

References, in `../_shared/stack/`, read when step 4 says so: `writing-guide.md` (what to
write, from which example), `contract.md` (the contract), `readme-spec.md` (`stack.d/README.md`),
`host.md` (host checks), `patterns/*.md` (one per run pattern), `examples/vite-spa/` (a
complete small stack).

## 1 · Healthcheck

```bash
STATUSCHECK_RERUN='rerun /jira-sdlc:jst-stack' bash "$S/statuscheck.sh" --role assigner
```

As `jst-survey`'s step 1: `jst_dir`, `git_repo`, `base_branch`, `worktrees_dir`, `gh_auth`,
`gh_repo_access` must pass (stop and relay the remedy otherwise; a missing worktrees folder →
ask, don't create it); carry `repo_strategy` and the members forward; every other row doesn't
concern this skill.

## 2 · The gate: a confirmed document

```bash
git fetch origin <DEFAULT_BASE_BRANCH>
git show origin/<DEFAULT_BASE_BRANCH>:.jst/STACK.md > /tmp/jst-stack-doc.md || echo "no document"
bash "$S/gh.sh" pr list -R <owner>/<repo> --head chore/jst-stack --state open --json number,url   # from the main checkout
```

- **No document on the base** → stop: the stack is built from a confirmed survey. If a
  `chore/jst-survey` PR is open, it's waiting to be merged; otherwise run
  `/jira-sdlc:jst-survey`. Marker: `STACK NOT WRITTEN: no confirmed .jst/STACK.md`.
- **An unchecked `- [ ]` under *Before jst-stack* or *Open questions*** → list them and stop
  (`STACK NOT WRITTEN: <n> items before jst-stack`). They are the user's to settle, in the
  document, through a PR.
- **An open `chore/jst-stack` PR** → you're revising it: work on that branch; ask what to
  change unless the user said so.

The worktree `W=<WORKTREES_DIR>/worktree-jst-stack`, by `jst-survey`'s step 2 rules with
`chore/jst-stack` (clean or stop; reuse; `-B` from the base, or from the open PR's branch).

## 3 · Read

In `W`: `.jst/STACK.md` (the whole of it: its decisions are your spec, its *Changes to the
existing stack* your worklist when a stack exists), then any existing `./stack`, `stack.d/`,
`.jst/bootstrap.sh` and `teardown.sh`. With member repos, read members in the main checkout.

## 4 · Plan, and ask

Read `writing-guide.md`, `contract.md` and the pattern page for the document's run pattern.
Then settle:

|  |  |
| -- | -- |
| **What you'll write** | `writing-guide.md` → *What the repo already has*: a new stack, a rewrite of one without the marker, or only the document's change rows for one with it. A `toolchain` project: only the hook |
| **Where** | the root, by the contract. Changes inside a member go on `chore/jst-stack` in that member too (step 6) |
| **The values** | an existing `resources.conf` keeps its values. A new one: `bash "$S/stack-resources.sh" propose --prefix <lower-case PROJECT-KEY> --ports-per-instance <ports per instance> [--subnet]`, with every other project's `resources.conf` as `--other` (below) |

Other projects' values: `$JST_STACK_CONFS` when set (the web app sets it); otherwise find them,
paths only: `find ~ -maxdepth 5 -path '*/stack.d/resources.conf' -not -path '*/node_modules/*' 2>/dev/null`.

Ask only what the document leaves open for the stack and the repo can't tell, in **one**
`AskUserQuestion` (at most four, recommendation first). Always include: *run the trial now?*
— it starts instance N (containers, ports) in a throwaway checkout and removes it; recommend
yes. No answer can come (headless, refused) → take the recommendations, mark them *assumed*
in the report and the PR.

## 5 · Write

By `writing-guide.md`: `./stack` (marker on line 2), `stack.d/resources.conf`,
`stack.d/lib.sh`, `stack.d/README.md` (every section of `readme-spec.md`), anything else the
stack needs, and the two hooks. Start from the closest example; for an existing stack, change
exactly the document's change rows and nothing else.

Rules that bite (the guide says why): names and ports only from `resources.conf` and N; never
the main checkout's services or data; kill by PID file, never by name; find the main checkout
with `git worktree list --porcelain`; honor `CF_INSTANCE_HOME` and `CF_MAIN_CHECKOUT`; never
print a secret.

Then the checks that need nothing running — you never run `./stack`, the app, Docker or an
install yourself; the trial does:

```bash
cd "$W" && bash -n stack && for f in stack.d/*.sh .jst/*.sh; do [ -f "$f" ] && bash -n "$f"; done
command -v shellcheck >/dev/null && shellcheck -x stack stack.d/*.sh .jst/*.sh
chmod +x stack .jst/bootstrap.sh .jst/teardown.sh
bash "$S/stack-resources.sh" check stack.d/resources.conf --other …   # the same others as step 4
```

Fix what they report before going on.

## 6 · Commit

Commit in `W` (only the stack's files: `stack`, `stack.d/`, `.jst/bootstrap.sh`,
`.jst/teardown.sh`, and the app change the guide allows) with
`jst-stack: <new stack | changes from .jst/STACK.md> (<pattern>)`.

**A change inside a member**: put that member in `W` as a worktree of its own repo, on
`chore/jst-stack` from the commit the workspace records, commit there, then record it in the
workspace:

```bash
sha=$(git -C "$W" ls-tree HEAD -- <member> | awk '{print $3}')
rmdir "$W/<member>" 2>/dev/null; git -C <main>/<member> worktree add -B chore/jst-stack "$W/<member>" "$sha"
# … edit and commit in "$W/<member>" …
git -C "$W" add <member> && git -C "$W" commit -m "jst-stack: <member> at its chore/jst-stack"
```

Never `git submodule update` in `W`.

## 7 · The trial

From the **main checkout** (it shares `W`'s commits), unless the user said not to:

```bash
bash "$S/stack-trial.sh" --ref "$(git -C "$W" rev-parse HEAD)"
```

It prints a table (step | result | detail), the logs' folder, and `TRIAL PASSED` or
`TRIAL FAILED: <step>`. On a failure, read that step's `logs/<step>.err` (stderr, with the
stack's `::step-failed::` marker) and `.out`, fix the cause in `W`, commit, and run the trial
again: **at most two fix rounds**, then stop and report what still fails — a stack that fails
its trial is not opened as a ready PR. `refused` (exit 2) means it never started: no marker,
a bad `resources.conf`, no free instance; fix that first.

A `toolchain` project has no trial: instead, run its hook once in a scratch worktree
(`git worktree add --detach /tmp/jst-hook-try HEAD`, `JST_INSTANCE=1 bash .jst/bootstrap.sh`,
then remove it) and report the outcome.

## 8 · Push and open the PR

Push `chore/jst-stack` (each changed member first, then the workspace). From the main
checkout, unless the PR is already open (one per changed member, then the workspace's):

```bash
bash "$S/gh.sh" pr create -R <owner>/<repo> --base <DEFAULT_BASE_BRANCH> --head chore/jst-stack \
  --title "jst-stack: the project's stack" --body-file /tmp/jst-stack-pr.md
```

A failed trial → open it as a draft (`--draft`). The body: what was written or changed (one
line per file or change row), the values, the trial's table and its last line, assumed
answers, and "Merging this PR gives every new issue worktree its own instance: the executor
runs `.jst/bootstrap.sh` in step 1." A pre-push hook that fails: show its output and stop,
no `--no-verify`.

## 9 · Report

Briefly: what you wrote or changed and why, the values, the trial's outcome (its table), what
the human runs differently now in the main checkout (if anything), assumed answers, the
PR(s). Then the next step: review and merge; from then on each new issue worktree starts its
instance (`./stack status --instance N` to see it, `.jst/teardown.sh` before removing a
worktree). `W` can go once the PR is merged.

Last line: the marker.
