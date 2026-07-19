> **Note on this document:** this describes how GitHub authentication is
> split between a human developer and the `jira-sdlc` skills (assigner /
> executor / reviewer) when they operate on the **same repo, on the same
> machine, under the same OS user account**. It exists because `git` and
> `gh` each keep exactly one piece of persistent, machine-wide config, and
> naively logging the skills in "the normal way" overwrites the human's
> own setup. If your project already isolates the two identities some
> other way (a dedicated CI user, a container, a second OS account), the
> problem this document solves doesn't apply to you — skip it.
>
> **Audience:** human developers on a machine that also runs
> `jira-task-executor` / `jira-task-assigner` / `jira-task-reviewer`, and
> the skills themselves (or whoever implements their GitHub-auth-related
> steps).

# GitHub auth strategy: separating the human and the agent

## 1. The setup this document is about

One machine, one checkout of the repo (a main checkout plus several
`git worktree` directories cut from it), and two credential identities
that both need to reach GitHub:

- **The human** — has their own GitHub account, an SSH key registered
  against it, and (optionally) their own `gh` CLI login. Pushes and
  commits under their own name.
- **The agent** — the `jira-sdlc` skills, authenticating as a single
  fine-grained **Personal Access Token (PAT)**, deliberately scoped to
  just this one repository with the minimum permissions the skills
  actually use (`Contents: Read and write`, `Metadata: Read-only`
  (required), `Pull requests: Read and write` — no `Account`
  permissions, no access to any other repo). The token lives in
  `<GITHUB_PAT_TOKEN>`, read from `jira-sdlc-tools.local.env`
  (machine-specific, gitignored — same treatment as `<JIRA_TOKEN>` and
  friends; see `../../skills/_shared/project-config.md`).

There is **no OS-level separation** here — both identities run as the
same user, in the same `$HOME`, often against the same `.git` directory
(worktrees share one `.git`). That's precisely why this needs a written
convention instead of "just works by default."

## 2. Why this doesn't work automatically

`git` and `gh` each have exactly **one** place they persist auth state,
and neither place is scoped to "this one script" or "this one identity"
— it's scoped to the whole repo or the whole machine:

| Tool | Where persistent config lives | Blast radius if the agent writes there |
|---|---|---|
| `git` | `.git/config` inside the repo (`remote.*`, `credential.helper`, `branch.*.remote`) | **Every worktree** of this repo shares one `.git` directory, so a config change here is visible to the human's interactive shell too — not just the worktree the agent happens to be running in. |
| `gh` | `~/.config/gh/hosts.yml` (or wherever `$GH_CONFIG_DIR` points) | Not even repo-scoped — it's keyed on your whole `$HOME`. Running `gh auth login` as the agent silently replaces whatever the human had logged in as, machine-wide, for every repo. |

So the naive approaches — `git remote set-url origin https://...`, or
`gh auth login --with-token` at the start of a skill run — both look
locally reasonable and both have a side effect well outside the worktree
they ran in: they overwrite the one credential the human relies on for
everything else they do on this machine.

## 3. The rule this repo follows

**Exactly one identity is allowed to live in persistent config: the
human's. The agent never writes persistent auth state — every git/gh
call it makes supplies the PAT fresh, for that one command, and leaves
no trace afterward.**

Concretely:

- `origin` stays whatever the human already has it as (typically SSH).
  Nothing the skills do ever runs `git remote set-url` on it, and
  nothing the skills do ever becomes the *default* remote for a branch
  (`branch.<name>.remote` is never pointed at anything agent-related) —
  so a bare `git push` / `git pull` typed by the human behaves exactly
  as it did before this document existed.
- The skills never run `gh auth login`, `gh auth logout`, or anything
  else that touches `~/.config/gh/hosts.yml`. If the human uses `gh`
  themselves, that login is untouched no matter how many times a skill
  runs.
- Every git or gh network call a skill makes carries the PAT **inline,
  for that call only** — as an environment variable or a `-c` flag on
  the single command — never as something written to a file that
  outlives the command.

This mirrors, and does *not* replace, the pattern already used for Jira
auth (`jira_acli_login.sh`): there, the three roles genuinely need
separate identities recorded in Jira's own history (comment authorship,
self-review detection), so a real login swap makes sense and `acli`'s
credential store is treated as disposable/swappable. GitHub is
different — there's only one shared agent identity, not three, and the
thing being protected is the human's *own* long-lived session, not a
role boundary — so here the answer is "touch nothing persistent" rather
than "swap and swap back."

## 4. How each operation authenticates

### `gh` calls (`gh pr create`, `gh pr list`, `gh pr view`, `gh pr diff`, `gh pr review`)

Prefix the PAT as `GH_TOKEN` on the single command. `gh` honors an
inline `GH_TOKEN` ahead of any stored login, and never reads or writes
`~/.config/gh/hosts.yml` when it's set:

```bash
GH_TOKEN="<GITHUB_PAT_TOKEN>" gh pr create --base "$PR_BASE" --title "..." --body-file "..."
GH_TOKEN="<GITHUB_PAT_TOKEN>" gh pr list --head "$BRANCH" --base "$PR_BASE" --json number,state,url
```

Nothing about `gh`'s stored login is read or changed by these calls. As
far as persistent state is concerned, the agent's use of `gh` is
invisible — it never "logs in."

### `git push` / `git fetch` / `git pull` from a skill

Two options, both keep `origin` and the human's credential helper
completely out of it. Pick one and use it consistently (this is the
contract the shared script from the auth work should implement):

**A — explicit HTTPS URL, no named remote at all.** Simplest, adds
nothing to `.git/config`:

```bash
git -c credential.helper='!f() { echo username=x-access-token; echo "password=$GITHUB_PAT_TOKEN"; }; f' \
  push "https://github.com/<OWNER>/<REPO>.git" "HEAD:refs/heads/$BRANCH"
```

**B — a second, explicitly-named remote**, added once, used only when
named explicitly:

```bash
git remote add agent "https://github.com/<OWNER>/<REPO>.git"   # one-time, inert until used by name
git -c credential.helper='!f() { echo username=x-access-token; echo "password=$GITHUB_PAT_TOKEN"; }; f' \
  push agent "$BRANCH"
```

Either way, the important properties are the same:

- The token is exported as an environment variable (`GITHUB_PAT_TOKEN`,
  read from `jira-sdlc-tools.local.env`) and only referenced by the
  inline credential helper — **never typed into the URL itself**
  (`https://x-access-token:<token>@github.com/...`), because a token
  embedded in the URL shows up in `git remote -v`, shell history, and
  process listings (`ps`). The `-c credential.helper=...` form keeps it
  in the environment, which is not visible the same way.
- `-c credential.helper=...` on the command line only applies to that
  one invocation — it is never written to `.git/config`, so it can't
  leak into the human's own `git push` later.
- `origin` (option A) or the *default* remote for the branch (option B)
  is never touched, so the human's SSH-based workflow is unaffected
  either way.

## 5. What must never happen

- The agent must never run `git remote set-url origin ...` — that
  changes what *every* worktree and the human's interactive shell
  resolve `origin` to.
- The agent must never run `gh auth login` / `gh auth logout` — that
  overwrites the human's `gh` session machine-wide, not just for the
  current script.
- The token must never be embedded literally in a URL passed as a
  command argument (visible in `ps`, shell history, `git remote -v`) —
  always pass it through the environment and a credential helper, as
  in §4.
- The token must never be committed, printed into a Jira comment, a PR
  body, or logged anywhere durable. It lives in exactly one place:
  `<GITHUB_PAT_TOKEN>` in `jira-sdlc-tools.local.env` (gitignored,
  machine-specific — see `../../skills/_shared/project-config.md`,
  which should gain a row for this token as part of wiring this up).

## 6. Quick reference

| Operation | Who runs it | Auth used | Anything written to disk? |
|---|---|---|---|
| `git push` / `git pull` typed by a developer | Human | SSH key | No (unchanged from before this doc) |
| `gh` used interactively by a developer, if at all | Human | Human's own `gh auth login` | Only if the human explicitly logs in themselves |
| `git push` / `git fetch` run by a skill script | Agent | `<GITHUB_PAT_TOKEN>`, via inline credential helper (§4) | No |
| `gh pr create` / `list` / `view` / `diff` / `review` run by a skill script | Agent | `<GITHUB_PAT_TOKEN>`, via `GH_TOKEN=` prefix (§4) | No |

If you ever see `origin` pointing at an HTTPS URL, or `gh auth status`
reporting a different account than the one you logged in as, something
violated §5 — that's a bug in the skill's scripts, not an expected side
effect of running them.
