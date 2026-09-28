---
slug: /running-multiple-copies
sidebar_position: 1
sidebar_label: Overview
---

# Parallel instances — running multiple copies of the project across worktrees

This plugin's assigner creates a git worktree per Jira issue (and per
sub-task of a split), so several copies of the project can be checked out
side by side on the same machine — separate working directories on
separate branches, each with its own executor. That much the tooling does
for you. What it does **not** do is make those checkouts into separate
*running* instances of your app. This section is about the gap between "N
worktrees checked out" and "N app instances running at once", and how to
decide what to do about it.

It's guidance, not a feature: the plugin ships no scripts, docker-compose
files, or templates for any of this. The patterns below are things you
adapt to your own project's architecture. This page is the reasoning and
the setup mechanics; the three worked examples at the bottom are what
other projects actually landed on.

## Why this matters

A worktree is a separate working directory on a separate branch. That
isolates your *source tree* — editing files in `worktree-PROJ-402`
doesn't touch `worktree-PROJ-403`. It does **not** isolate anything the
running app reaches *outside* its source tree:

- a database
- a cache (Redis, Memcached)
- object / file storage (uploads, a local `media/` volume, an S3 bucket)
- a message queue or background-job broker
- a third-party sandbox account (a payment sandbox, an email sandbox)
- a fixed network port

Every one of those is shared by default the moment two worktrees run at
once, because nothing in the worktree mechanism scopes them per checkout.
Two copies of the app pointed at the same database, the same Redis
keyspace, or the same port will collide — and the failure mode ranges
from an obvious "port already in use" to a silent one where worktree A's
migration reshapes the schema out from under worktree B, which is still
running old code against it.

So each external asset is a **decision point**: for this worktree's
instance, is that asset *shared* with the other worktrees, or *isolated*
to this one?

## The simple case — stateless / frontend-only apps

If the app holds no external state of its own — a static site, a
frontend SPA, a stateless service that only calls APIs it doesn't own —
running a second copy is close to free. There's no shared-state problem
to solve, only a port to move:

```bash
cd /home/you/src/myapp-worktrees/worktree-PROJ-403
npm install          # each worktree has its own node_modules
npm run dev -- --port 5175   # first copy is on 5174, this one on 5175
```

The only thing two copies contend for is the dev-server port, so give
each worktree its own. Beyond that they're genuinely independent, and you
can stop here. [The React / Vite example](react.md) is this case, worked
through end to end — including the one place it stops being free
(Playwright starts a dev server of its own).

## The complex case — apps with external state

Once the app owns external state, "just change the port" isn't enough.
Walk each external asset the app touches and decide, per asset, between
two options:

- **Share it** across all worktrees — one database / cache / bucket that
  every worktree's instance connects to.
- **Isolate it** — this worktree's instance gets its own duplicated
  instance of the asset, standing on its own.

The right call depends on the asset kind *and* your project's
architecture — this is a framework for the decision, not a fixed answer.
The question to ask for each asset is: **can one worktree's changes to
this asset break another worktree that's still running old code?** If
yes, isolate it. If no, sharing is usually fine and saves the duplication
cost.

| Asset | Usually | Why |
| -- | -- | -- |
| Relational database (with migrations) | **Isolate** | A schema migration in one worktree changes the shape another worktree's still-running old code depends on. This is the canonical reason to duplicate. |
| Cache (Redis / Memcached) | Depends | Fine to share if keys are namespaced per app version; isolate if two versions would write incompatible values to the same key. |
| Object / file storage | Depends | Share for read-mostly assets; isolate when one worktree writes files another worktree's code would misread (changed layout, changed format). |
| Third-party sandbox account | **Share** | Usually expensive or rate-limited to duplicate, and read-mostly from your app's side — share unless a test mutates shared sandbox state destructively. |
| Message queue / job broker | **Isolate** | Two app versions consuming the same queue will process each other's jobs with the wrong code. |
| Fixed network port | **Isolate** (always) | Two processes can't bind the same port — give each worktree its own, as in the stateless case. |

"Isolate" costs something — you're standing up and tearing down a real
copy of the asset per worktree — so don't isolate reflexively. Isolate
what a divergent branch can corrupt; share what it can only read.

## Setting it up — the worktree hook

The decisions above are prose until something runs them. The optional
[`.jst/bootstrap.sh`](https://github.com/kantorv/jira-sdlc-tools/blob/main/plugins/jira-sdlc/skills/_shared/project-config.md#jstbootstrapsh--jstbootstrapps1--the-optional-worktree-hook)
(POSIX) / `.jst/bootstrap.ps1` (Windows) hook is where a project writes
them down in *runnable* form: it sits in your project's `.jst/` folder,
it's tracked, and `jira-task-executor` runs it in its **step 1** — once
per worktree, when someone is actually about to work there —
automatically, with no confirmation prompt.

An earlier version of this convention was a markdown file the assigner
relayed as prose. That failed in practice for a predictable reason: a
skill treats prose as a recommendation to pass along, not a procedure to
execute, so worktrees still came up unprovisioned. Hence a script.

Four properties of the contract are worth knowing before you write one.

**1. The environment contract.** The executor exports five variables
before invoking, and both ports use identical names:

| variable | value |
| -- | -- |
| `JST_ISSUE_KEY` | the issue key derived from the branch, e.g. `PROJ-402` |
| `JST_WORKTREE_DIR` | absolute path of *this* worktree's root (the script's working directory) |
| `JST_BRANCH` | the current branch, e.g. `feature/PROJ-402-some-slug` |
| `JST_PARENT_BRANCH` | the PR base from `git config branch.<branch>.parentbranch`; empty when unset |
| `JST_PROJECT_KEY` | `PROJECT_KEY` from `.jst/jira-sdlc-tools.env` |

They're environment variables rather than positional arguments so the set
can grow later without breaking scripts already written against it — a
script that ignores a variable it doesn't know about keeps working. Give
each one a fallback default so the script stays runnable by hand, which
is how you'll debug it — and make each fallback *equivalent* to the
variable it stands in for. `JST_ISSUE_KEY` is the one to watch:
`${JST_ISSUE_KEY:-$(git branch --show-current)}` looks reasonable and
isn't, because it substitutes `feature/PROJ-402-some-slug` for
`PROJ-402`, which either crashes the index arithmetic or silently hashes
to a different instance than the executor run of the same worktree. Pull
the key back out of the branch instead — both worked examples that need
an index do this.

**2. Fail-soft, always.** A non-zero exit is reported in the executor's
output and the run continues; you cannot block the executor from here, so
don't try. Exit non-zero to say "this worktree isn't runnable yet" — with
a message saying how to finish the job by hand — not "stop working".

**3. Idempotency is your script's job.** Re-invoking the executor in the
same worktree (a re-run after a rejected review, say) re-runs the hook.
Write every step as create-if-missing or reuse: an existing venv is
skipped, `docker compose up -d` reuses a running container, a seeded
database is not re-seeded. The two scripts in
[the Python example](python.md) open by exiting quietly when the worktree
is already provisioned, which is the cheapest form of this.

**4. Derive the instance index deterministically from the issue key.**
Anything per-instance — ports, subnets, container names, data
directories — should be a function of a single **instance index `N`**,
and `N` should come from `JST_ISSUE_KEY`, never from "the next free
slot". Two worktrees bootstrapping at once would race for a free slot,
and the same worktree would drift to a different index between runs.
Either parse the numeric part of the key or hash the whole key:

```bash
# parse: PROJ-402 -> 402 -> index 25
INSTANCE=$(( ${JST_ISSUE_KEY##*-} % 63 + 1 ))

# hash: works for any key shape, spreads adjacent issue numbers apart
INSTANCE=$(( $(printf '%s' "$JST_ISSUE_KEY" | cksum | cut -d' ' -f1) % 250 + 1 ))
```

**Index 0 is the main checkout**, in every example below. It keeps the
ports and names it already had, so existing habits and docs that say
`localhost:5173` go on working, and the worktrees take 1, 2, 3, … Both
schemes above are modular, so two keys can collide (`PROJ-226` and
`PROJ-289` both give 38 in the first one) — nothing detects that, and it
only bites when both are checked out at once. Widen the range or add a
collision check if your team runs enough parallel worktrees for it to be
real.

There's a full example pair to start from at
[`docs/examples/bootstrap.example.sh`](../examples/bootstrap.example.sh) /
[`bootstrap.example.ps1`](../examples/bootstrap.example.ps1), and
statuscheck's `bootstrap` row reports whether your project has a hook —
INFO either way, since most projects won't.

### Tearing it back down

`.jst/teardown.sh` is the counterpart convention: it undoes what
`bootstrap.sh` provisioned, so a worktree can be removed without leaving
a container, a docker network, or a few hundred megabytes of cloned media
behind. **No skill runs it** — there is no teardown hook in the executor,
because a worktree's lifetime is a human's decision — so run it by hand
before `git worktree remove`. Both example projects that provision real
state ship one, and both refuse to run in the main checkout for the same
reason bootstrap does: the main checkout holds the originals the
per-instance copies were made from.

## Worked examples

Three real projects, ordered by how much they have to provision. Each is
a distillation of that project's own hook scripts and instance notes, not
a template — read the one closest to your stack and take the shape, not
the values.

| example | what it provisions | the interesting part |
| -- | -- | -- |
| [Python toolchain](python.md) | a per-worktree `venv/` and nothing else | the case where "parallel instances" means parallel *toolchains* — no ports, no state, ~20 lines each way |
| [React / Vite SPA](react.md) | host ports and `node_modules` | stateless, so only `port+N` matters — until Playwright starts a dev server of its own on the port you're already using |
| [Multi-service docker-compose](docker-compose.md) | network, subnet, static IPs, certificate, auth realm, database, media tree | the full isolate-everything case, and what it costs (~457 MB of media per instance) |

The section is built to grow: a new stack gets a **new sibling page**
here, with its own stable slug, rather than another section bolted onto
an existing page. Add the page, add its entry to
[`scripts/docs-url-map.json`](https://github.com/kantorv/jira-sdlc-tools/blob/main/scripts/docs-url-map.json),
and add a row to the table above.
