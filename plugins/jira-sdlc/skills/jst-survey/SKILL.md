---
name: jst-survey
description: Survey a project's architecture and write `.jst/STACK.md` — what the project is (repo layout and run pattern), its components, which resources an issue worktree shares with the main checkout and which it gets its own copy of, a Mermaid diagram, and the open decisions — so every issue's worktree can later run its own working instance of the app. Reads the repo the way a new team member would, asks at most four questions, and opens the document as a PR to the base branch on `chore/jst-survey`; merging it is the confirmation. Never writes in the main checkout and never opens a secret file. Run it from the project root after `jst-install`; `/jira-sdlc:jst-stack` builds the stack from the merged document.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, AskUserQuestion
---

You are surveying **the user's project** so its stack can be built: one document,
`.jst/STACK.md`, that says what the project is, what runs, and — for each resource — what
an issue's worktree shares with the main checkout and what it gets its own copy of. The
goal behind it: every issue gets a worktree with a fully working instance of the app, side
by side with the others, without one branch's changes breaking another copy.

The document is the **only** thing `jst-stack` reads. A fact the stack needs and the
document lacks becomes a guess later, so the document's job is to be complete and
plainly right — describe what **is**, don't design what isn't there.

**Conventions** (as in `jst-install`):

- Run from the **project root**: the repo the user builds features in (with member repos,
  the workspace root). If `git remote get-url origin` names `jira-sdlc-tools`, you're in
  the toolkit's own clone — stop and ask.
- **`CLAUDE_PLUGIN_ROOT`** is this plugin's root. Unset (a non-Claude client) → the scripts
  are at `../_shared/scripts/posix/` relative to this skill's folder. Below,
  `S="${CLAUDE_PLUGIN_ROOT}/skills/_shared/scripts/posix"`.
- **Script dispatch**: pick POSIX (`$S/X.sh`) or Windows (`…/win/X.ps1`) from your own
  runtime before the first call. The blocks below are POSIX.
- **`<TOKEN>`s** (`<DEFAULT_BASE_BRANCH>`, `<WORKTREES_DIR>`, …) come from statuscheck's
  rows; `../_shared/project-config.md` describes each.
- **Never open `.jst/jira-sdlc-tools.local.env`**, nor any other ignored env or secrets
  file: one `cat` puts live tokens into the transcript. Their *paths* are survey facts;
  their contents are not.
- **The last line of your final message is the marker** — `STACK DOC WRITTEN <PR url>`, or
  `STACK DOC NOT WRITTEN: <reason>` when you stop early — so a caller (the jira-sdlc web
  app runs this skill headless) can read the outcome without parsing prose.

Two reference files hold the substance; read both before step 3:

- `../_shared/stack/survey-method.md` — how to read the repo, the project type, the two
  places, the shared/own-copy test and its usual answers, what to ask.
- `../_shared/stack/stack-doc-template.md` — the document's sections and the diagram rules.

## 1 · Healthcheck

```bash
STATUSCHECK_RERUN='rerun /jira-sdlc:jst-survey' \
  bash "$S/statuscheck.sh" --role assigner
```

The survey needs git, GitHub and the worktrees folder — not Jira. Read these rows:

| row | needed because | on FAIL / WARN |
| -- | -- | -- |
| `jst_dir`, `git_repo` | the document goes in `.jst/`, through git | stop, relay the remedy |
| `base_branch` | the PR's base: `<DEFAULT_BASE_BRANCH>` | stop, relay the remedy |
| `worktrees_dir` | the survey works in `<WORKTREES_DIR>/worktree-jst-survey`, never in the main checkout | WARN (missing) → stop and ask; don't create it |
| `gh_auth`, `gh_repo_access` | the PR; the repo slug `<owner>/<repo>` | stop, relay the remedy |
| `repo_strategy`, `member_repo[…]` | the repo layout: `single` or `submodules`, and the members | carry forward |

Every other row (Jira, an issue key, the current PR, `working_tree`'s uncommitted files in
the main checkout) doesn't concern this skill, which reads the main checkout and writes only
in its own worktree: say so and carry on. A non-zero exit from those rows is expected.

## 2 · Where this survey stands, and its worktree

```bash
git fetch origin <DEFAULT_BASE_BRANCH>
git cat-file -e origin/<DEFAULT_BASE_BRANCH>:.jst/STACK.md && echo "document: on base" || echo "document: none"
bash "$S/gh.sh" pr list -R <owner>/<repo> --head chore/jst-survey --state open --json number,url
```

Run `gh.sh` from the **main checkout** (it reads the PAT from the main checkout's
`.jst/`; a worktree has none). Then:

| state | means | do |
| -- | -- | -- |
| an open PR on `chore/jst-survey` | a survey is waiting for review | **revise it**: work on that branch; the PR updates when you push. Ask the user what to change, unless they said so already |
| no open PR, document on base | the project was surveyed before | **re-survey**: start from the base's document, keep the human's decisions unless the repo now contradicts them, add a line under *Changes* |
| neither | first survey | write it from the template |

**The survey describes the base branch as the remote has it**, since that is what every issue
worktree is cut from. Check that the main checkout doesn't hold base-branch work the remote
lacks:

```bash
git rev-list --left-right --count origin/<DEFAULT_BASE_BRANCH>...<DEFAULT_BASE_BRANCH>   # behind  ahead
git log --stat --oneline origin/<DEFAULT_BASE_BRANCH>..<DEFAULT_BASE_BRANCH>            # when ahead > 0
```

Behind is fine. Ahead only on files a survey doesn't read (docs, notes, `.gitignore`) → carry
on, and list them under *Notes*. **Ahead, touching what a survey reads** (`./stack`, `stack.d/`, `.jst/`,
compose files, settings, manifests): ask, recommending the first option —

1. *Land them first (merge with the remote's base if it moved too, then push), then re-run the survey* (the document then describes what
   issue worktrees really get). Stop with `STACK DOC NOT WRITTEN: <N> local commits on <base> to land first`.
2. *Survey them anyway*: describe the local work, name the local base's sha in the header
   ("local, <N> ahead of origin"), and put "land the local commits on `<base>`" under
   *Before jst-stack*.

With member repos, `git submodule status` in the main checkout: a `+` marks a member
checked out away from the commit the workspace records. Describe the recorded commit
(`git -C <member> show <sha>:<file>`), and say in the report which member was elsewhere.

The worktree, at `W=<WORKTREES_DIR>/worktree-jst-survey`:

- `W` exists → it must be clean (`git -C "$W" status --porcelain` empty), or stop and ask:
  it may hold someone's work. Clean: revising an open PR → `git -C "$W" checkout -B chore/jst-survey origin/chore/jst-survey`
  (after `git fetch origin chore/jst-survey`); otherwise it's left from an earlier, merged
  survey → `git -C "$W" checkout -B chore/jst-survey origin/<DEFAULT_BASE_BRANCH>`.
- Revising an open PR → `git fetch origin chore/jst-survey && git worktree add -B chore/jst-survey "$W" origin/chore/jst-survey`.
- Otherwise → `git worktree add -B chore/jst-survey "$W" origin/<DEFAULT_BASE_BRANCH>`
  (`-B` resets a stale local branch left by an earlier, merged survey).

With member repos, the worktree holds only the workspace: don't `git submodule update`
there. Read the members in the main checkout.

## 3 · Read the repo

Follow `survey-method.md` → *Read the repo as a new team member would*. Read tracked files
in `W` (it is exactly the base branch); read the members, and list the ignored paths, in the
main checkout:

```bash
git ls-files --others --ignored --exclude-standard --directory   # paths only — never open them
```

Settle the project type (layout from step 1's `repo_strategy` row; the run pattern from
what you read), the components and how each is known to be ready, each resource's value in
both places, and the host needs. An existing `./stack`, a stack inside a member, or a
`.jst/bootstrap.sh`: follow `survey-method.md` → *An existing stack or hook*. Don't choose
how instance N is derived; the plugin does (same file, *The two places*).

## 4 · Ask what the repo can't tell

Follow `survey-method.md` → *Ask only what the repo can't tell*: at most four questions in
**one** `AskUserQuestion` call, each with the evidence and your recommendation as the first
option. Typical: an instance's database (empty + migrated is the default; a copy brings the
main DB's queued jobs with it), which shared services the main checkout keeps running, where
an instance's secret comes from, whether a part of the repo is run at all. Nothing to ask →
skip this step and say so.

No answer can come (the question is refused, or this is a headless run with nobody to
ask) → take your recommended option for each. It becomes a decision like any answer, marked
*(assumed)* where it lands, and listed in the report and the PR body, so the PR's reviewer
sees it.

Each answer becomes a decision in its table. What's left goes where `survey-method.md` →
*Ask only what the repo can't tell* says: an action under *Before jst-stack*, a decision
under *Open questions*, an observation under *Notes*. `jst-stack` refuses to start while
the first two hold an unchecked item, so leave one only when it truly is the user's.

## 5 · Write `.jst/STACK.md`

In `W`, from `stack-doc-template.md`, keeping every section ("none" where it applies). The
header names the base branch and its short sha (`git -C "$W" rev-parse --short HEAD`).
Values the repo gave you are facts; values you decided carry their reason in the *Why*
column. No secret values anywhere — names of env files and variables only.

Check the diagram against the template's rules before committing: one subgraph per place,
databases as `[(…)]`, labels quoted when they hold punctuation, and **no `;`** in any label
(Mermaid ends the statement there and the whole diagram fails to render).

## 6 · Commit, push, open the PR

Commit **only** `.jst/STACK.md`:

```bash
git -C "$W" add .jst/STACK.md
git -C "$W" commit -m "jst-survey: .jst/STACK.md (<layout>, <pattern>)"
git -C "$W" push -u origin chore/jst-survey
```

A pre-commit or pre-push hook that fails: show its output and stop — don't `--no-verify`.
Then, from the main checkout, unless the PR is already open:

```bash
bash "$S/gh.sh" pr create -R <owner>/<repo> --base <DEFAULT_BASE_BRANCH> --head chore/jst-survey \
  --title "jst-survey: the stack document" --body-file /tmp/jst-survey-pr.md
```

The body: the project type, the components in one line each, the resource decisions that
matter most (database, ports, shared services), the changes to an existing stack, any
assumed answers, what's under *Before jst-stack* and *Open questions*, and "Merging this PR
confirms the document; then run `/jira-sdlc:jst-stack`."

## 7 · Report

To the user, briefly: the project type, the components, the decisions you made and why, the
answers you used (and which were assumed), the changes to an existing stack, what must
happen before `jst-stack` and what's still open, the PR. Then the next step: review the document in the
PR (edit it there if anything is wrong), merge it, then run `/jira-sdlc:jst-stack`. The
worktree `W` can go once the PR is merged (`git worktree remove "$W"`).

Last line: `STACK DOC WRITTEN <PR url>`.
