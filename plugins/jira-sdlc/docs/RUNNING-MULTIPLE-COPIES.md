# Running multiple copies of the project across worktrees

This plugin's assigner creates a git worktree per Jira issue (and per
sub-task of a split), so several copies of the project can be checked out
side by side on the same machine — separate working directories on
separate branches, each with its own executor. That much the tooling does
for you. What it does **not** do is make those checkouts into separate
*running* instances of your app. This doc is about the gap between "N
worktrees checked out" and "N app instances running at once", and how to
decide what to do about it.

It's guidance, not a feature: the plugin ships no scripts, docker-compose
files, or templates for any of this. The patterns below are things you
adapt to your own project's architecture.

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
cd ../myapp-worktrees/worktree-PROJ-403
npm install          # each worktree has its own node_modules
npm run dev -- --port 5175   # first copy is on 5174, this one on 5175
```

The only thing two copies contend for is the dev-server port, so give
each worktree its own. Beyond that they're genuinely independent, and you
can stop here.

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
|---|---|---|
| Relational database (with migrations) | **Isolate** | A schema migration in one worktree changes the shape another worktree's still-running old code depends on. This is the canonical reason to duplicate. |
| Cache (Redis / Memcached) | Depends | Fine to share if keys are namespaced per app version; isolate if two versions would write incompatible values to the same key. |
| Object / file storage | Depends | Share for read-mostly assets; isolate when one worktree writes files another worktree's code would misread (changed layout, changed format). |
| Third-party sandbox account | **Share** | Usually expensive or rate-limited to duplicate, and read-mostly from your app's side — share unless a test mutates shared sandbox state destructively. |
| Message queue / job broker | **Isolate** | Two app versions consuming the same queue will process each other's jobs with the wrong code. |
| Fixed network port | **Isolate** (always) | Two processes can't bind the same port — give each worktree its own, as in the stateless case. |

"Isolate" costs something — you're standing up and tearing down a real
copy of the asset per worktree — so don't isolate reflexively. Isolate
what a divergent branch can corrupt; share what it can only read.

## Worked example — Django

A Django app is the textbook case for **isolating the database per
worktree**. Django's whole workflow is migration-driven: a feature branch
routinely carries a schema migration the base branch hasn't got yet. If
two worktrees share one Postgres database, running `migrate` in the
worktree that's ahead reshapes the schema under the worktree that isn't —
and the second app starts throwing errors against columns that moved or
tables that changed. So each worktree needs its own database, seeded from
a common baseline at worktree-creation (or launch) time.

The pattern that keeps this self-contained: a **docker-compose file
scoped to each worktree**, standing up that worktree's own database
container under the worktree's own folder, so `docker-compose` run from
inside the worktree picks up *its* database rather than a shared one.

```yaml
# docker-compose.worktree.yml — lives in each worktree, one isolated DB per checkout.
# Illustrative only; adapt names, ports, and the seed step to your project.
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: myapp
      POSTGRES_PASSWORD: dev
    # Bind to a per-worktree host port so two worktrees' databases don't
    # collide — e.g. 55432 here, 55433 in the next worktree.
    ports:
      - "55432:5432"
    # A named volume keyed to the worktree keeps this DB's data separate
    # from every other worktree's DB on the same machine.
    volumes:
      - myapp_db_PROJ-402:/var/lib/postgresql/data

volumes:
  myapp_db_PROJ-402:
```

Two moving parts make it isolated rather than shared:

1. **A per-worktree host port** (`55432`, `55433`, …) so the databases of
   two simultaneously-running worktrees don't fight over one port.
2. **A per-worktree named volume** (or a fresh clone of a baseline dump at
   launch) so each worktree's data lives on its own, and a migration in
   one never touches another's.

Point that worktree's Django settings at its own database (host port
above), run `manage.py migrate` there, and this checkout has a database
that only it can reshape — a sibling worktree still on old code keeps its
own schema until *it* migrates.

The same shape generalizes: for any asset you decided to *isolate*, scope
its instance to the worktree (its own container, port, volume, or
namespace) and point that worktree's config at it; for anything you
decided to *share*, leave the config pointing at the one common instance.
