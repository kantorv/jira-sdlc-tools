---
slug: /parallel-instances/react
sidebar_position: 3
sidebar_label: React / Vite SPA
---

# Worked example — a React / Vite SPA

A stateless Vite + React single-page app. It owns no external state — no
database, no queue, no upload tree — and reads its backend URL out of a
config file at runtime, talking to a shared, read-mostly API.

So there is almost nothing to provision per worktree. **Only two things
are per-instance: the ports it binds, and its `node_modules`.**
Everything else is shared, and that is fine. This is
[the simple case](RUNNING-MULTIPLE-COPIES.md) from the overview, worked
through — including the one place it stops being simple.

## The allocation scheme

Everything derives from a single **instance index `N`** — one number per
worktree, no port bookkeeping:

| thing | value for index `N` | `N=0` | `N=1` | `N=2` |
| -- | -- | -- | -- | -- |
| Vite dev server | `5173+N` | `5173` | `5174` | `5175` |
| Storybook | `6006+N` | `6006` | `6007` | `6008` |

**Index 0 is the main checkout.** It keeps 5173 and 6006 unchanged, so
every existing habit and every doc that says `localhost:5173` keeps
working. Worktrees take 1, 2, 3, …

In this project the index is just a number you pass on the command line —
there is no script and no generated config, which for two moving parts is
a defensible amount of tooling. To have the executor do it for you
instead, derive `N` from the issue key in `.jst/bootstrap.sh`, per
[the hook contract](RUNNING-MULTIPLE-COPIES.md):

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "${JST_WORKTREE_DIR:-$(git rev-parse --show-toplevel)}"

# the fallback has to yield the *key*, not the branch — see below
ISSUE_KEY="${JST_ISSUE_KEY:-$(git branch --show-current | grep -oE '[A-Z]+-[0-9]+' || true)}"
: "${ISSUE_KEY:?no issue key in JST_ISSUE_KEY or the branch name; pass JST_ISSUE_KEY=PROJ-402}"
N=$(( ${ISSUE_KEY##*-} % 100 + 1 ))       # never 0 — that's the main checkout

[ -d node_modules ] || yarn install --silent
printf 'DEV_PORT=%s\nSTORYBOOK_PORT=%s\n' "$(( 5173 + N ))" "$(( 6006 + N ))" > .env.local
echo "bootstrap: instance $N — 'yarn dev --port $(( 5173 + N ))'"
```

That is the whole hook. Resist padding it out: it earns its place by
doing what someone would otherwise work out by hand, not by covering
every step in a bigger example.

The one line worth reading twice is the fallback. `JST_ISSUE_KEY` is set
when the executor invokes the hook, and the `:-` branch is what keeps the
script runnable by hand — so it has to produce the *key*, not the branch.
Handing `${..##*-}` a raw `feature/PROJ-402-some-slug` yields `slug`,
which under this script's own `set -u` aborts with `slug: unbound variable`; the `grep -oE` pulls `PROJ-402` back out, and the `:?`
line turns a branch with no key in it into a message instead of a shell
error. The same rule applies to whichever derivation you pick — the
fallback must be *equivalent* to the variable it stands in for, or the
same worktree lands on a different index depending on who started it.

## What's shared, what isn't

| asset | decision | why |
| -- | -- | -- |
| backend API | **shared** | read-mostly, and nothing the SPA does to it is destructive or branch-specific |
| host ports | **isolated** (always) | two processes cannot bind one port |
| `node_modules` | **isolated** (unavoidable) | git worktrees don't share it, and two branches can disagree on the lockfile |
| the source checkout | **isolated** (that's the point) | each worktree is its own branch |
| browser `localStorage` / `sessionStorage` | **shared per origin** — so isolated in practice | `localhost:5174` is a different origin from `localhost:5173`, and storage is scoped per origin |

## Bringing a worktree up

A fresh worktree has no `node_modules`, so nothing runs until you
install:

```bash
cd /home/you/src/myapp-worktrees/worktree-PROJ-402
yarn install            # per worktree; nothing to share
yarn dev --port 5174    # 5173+N, N=1
```

That's the whole procedure. With the main checkout's `yarn dev` still on
5173, you now have two instances up.

For Storybook in parallel, override the pinned port the same way — a
`storybook` script that hardcodes `-p 6006` takes an override after it:

```bash
yarn storybook -p 6007  # 6006+N
```

## Playwright — the one sharp edge

This is the part that catches people, and it catches them *after* the
setup above looks like it worked.

A `playwright.config.ts` typically starts **its own** dev server
(`webServer`, with `reuseExistingServer: false`) and points `baseURL` at
it. Left on the default, a test run in any worktree tries to bind 5173 —
which the main checkout's dev server is already holding — and the run
dies waiting for a server that never comes up. Two worktrees running
tests at the same time collide the same way.

Have both values read one environment variable, then scope the run to
your index:

```bash
DEV_PORT=5174 yarn playwright test        # 5173+N, N=1
```

Playwright then starts its own Vite on 5174 and tests against it. Unset —
main checkout, CI — it stays on 5173 exactly as before.

Two caveats worth knowing:

- Playwright starts and stops that dev server itself. **Don't leave your
  own `yarn dev` running on the same port** you hand to `DEV_PORT` — it
  will fail to bind. Either stop yours for the test run, or give the test
  run a port of its own (e.g. `DEV_PORT=5184`).
- Pass `--strictPort` to Vite, so a taken port fails immediately and
  loudly instead of Vite sliding to the next free one and Playwright
  timing out against an empty URL.

## Clearing a stuck port

The kill-everything incantation that projects tend to keep in their
`CLAUDE.md`:

```bash
ps aux | grep -E 'yarn|vite' | grep -v grep | awk '{print $2}' | xargs -r kill -9
```

**Don't use that once more than one instance is up.** It matches every
worktree's dev server and kills all of them, plus any unrelated `yarn`
process. Kill by port instead, which touches only the one you name:

```bash
fuser -k 5174/tcp                 # or: kill -9 $(lsof -t -i:5174)
```

This generalizes past this stack: any parallel-instance setup makes
process-name matching wrong, because the thing that used to identify
"the dev server" now identifies all of them.

## Notes

- If the app authenticates against an OIDC provider locally, each
  instance's `http://localhost:5173+N` has to be a registered redirect
  URI in the client, or login fails on every instance but index 0. An app
  with auth switched off locally doesn't have this problem — until
  someone switches it on.
- Nothing here is generated or parsed. If you add a service that binds a
  port, give it a `port+N` row in the table above.
