# Example `.jst/PARALLEL-INSTANCES.md`

> **This is an example, not a template to fill in.** Copy it to
> `.jst/PARALLEL-INSTANCES.md` in your own project and rewrite it for your
> stack — nothing here is parsed, and there are no required headings or
> tokens. It's modelled on a real Django + docker-compose project, because
> that's the case where per-worktree provisioning actually bites; a
> stateless frontend needs about six lines instead (see the bottom).
>
> Delete this blockquote when you adapt it. Everything below the line is
> written as if it were the real file — `myapp` is the placeholder for your
> project's name.
>
> Why this file exists at all, and what reads it, is in
> [`skills/_shared/project-config.md`](../../skills/_shared/project-config.md#jstparallel-instancesmd--optional-and-free-form);
> the share-vs-isolate reasoning behind the decisions below is in
> [`docs/RUNNING-MULTIPLE-COPIES.md`](../RUNNING-MULTIPLE-COPIES.md).

---

# Parallel local stacks, one per worktree

Run the full local stack from a git worktree, with several instances up at
the same time.

Everything an instance needs is provisioned per instance: a docker network,
host ports, the application database (restored from a dump), the uploaded
media tree, and the worktree's own `.env.local`. Nothing is shared with
another worktree except read-only source dependencies.

The steps below are numbered 1–7 and map one-to-one onto the functions in
`scripts/init-instance.sh`. Run the whole thing, or any single step:

```bash
./scripts/init-instance.sh -n 1 --db-dump appdb.sql   # steps 1-6, end to end
./scripts/init-instance.sh -n 1 3                     # re-render the config only
./scripts/init-instance.sh -n 1 down                  # step 7, teardown
```

## The allocation scheme

Everything derives from a single **instance index `N`**. One number per
instance, no manual port bookkeeping, collisions impossible by construction.

| thing | value for index `N` | `N=1` | `N=2` |
|---|---|---|---|
| compose project | `myapp-iN` | `myapp-i1` | `myapp-i2` |
| docker network | `myapp-net-iN` | `myapp-net-i1` | `myapp-net-i2` |
| subnet | `10.30.(5+N).0/24` | `10.30.6.0/24` | `10.30.7.0/24` |
| database host port | `55432+N` | `55433` | `55434` |
| app dev server | `8000+N` | `8001` | `8002` |
| database data dir | `.instances/N/pgdata/` | in that worktree | in that worktree |
| media / uploads | `.instances/N/uploads/` | in that worktree | in that worktree |

**Index 0 is the main checkout's own stack** — the one you had before
worktrees entered the picture. It keeps working unchanged and this script
refuses `-n 0`, so provisioning an instance can never disturb it. It's a
convenient source for the database dump step 5 wants.

### What's shared and what isn't

| asset | decision | why |
|---|---|---|
| application database | **isolated** | a migration on one branch reshapes the schema under a worktree still running older code |
| uploaded media | **isolated** | one instance writing a changed layout breaks another's reads |
| cache | **isolated** (falls out of the compose project) | cheap to duplicate, and two app versions can write incompatible values to one key |
| host ports | **isolated** (always) | two processes can't bind one port |
| third-party sandbox account | **shared** | rate-limited, read-mostly, and nothing we run mutates it destructively |
| the frontend checkout | **shared** by default | several instances serving one read-only checkout is fine — pass `--frontend <path>` to point at your own when doing frontend work in parallel |

## Prerequisites

- Docker with compose v2, plus `python3`, `curl` and `jq` on the host.
- A database dump — step 5 requires `--db-dump <file>`; that step says how
  to produce one.
- Dependencies installed in the worktree (each worktree has its own).

```bash
git worktree add ../myapp-worktrees/worktree-PROJ-402 -b feature/PROJ-402-some-slug
cd ../myapp-worktrees/worktree-PROJ-402
./scripts/init-instance.sh -n 1 --db-dump appdb.sql
```

## Step 1 — Resolve instance parameters

Derives every value in the table above from `N` and writes
`.instances/N/instance.env` (gitignored). Every later step reads that file,
so any single step can be re-run on its own. The main checkout is discovered
from `git worktree list`.

**Verify:** `cat .instances/1/instance.env`

## Step 2 — Create the per-instance docker network

```bash
docker network create --driver bridge --subnet 10.30.(5+N).0/24 myapp-net-iN
```

Idempotent: an existing network with the expected subnet is accepted; one
with a *different* subnet is a hard error rather than a silent mismatch.

**Verify:**
```bash
docker network inspect myapp-net-i1 --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

## Step 3 — Render the per-instance configuration

Renders `docker-compose.instance.yml` and the app's `.env.local` from
`scripts/templates/` with an explicit variable list, so nothing else in a
template is touched — compose's own `$$VAR` escapes have to survive
rendering intact.

The keys that change per instance:

| key | value |
|---|---|
| `DB_HOST` | `localhost` |
| `DB_PORT` | `55432+N` |
| `MEDIA_ROOT` | `.instances/N/uploads/` |
| `DEV_SERVER_PORT` | `8000+N` |

Secrets are **not** re-derived — they're copied from the main checkout's
`.env.local`, which stays the single source of truth for them.

**Verify:**
```bash
docker compose -f .instances/1/docker-compose.instance.yml config >/dev/null && echo "compose ok"
```

## Step 4 — Bring the stack up

```bash
docker compose -f .instances/N/docker-compose.instance.yml up -d --remove-orphans
```

Then polls every service that declares a healthcheck until it reports
healthy (5 minute budget).

**Verify:** `docker compose -f .instances/1/docker-compose.instance.yml ps`

## Step 5 — Clone the application database

Restores the database from a dump file into this instance's own fresh
server. `--db-dump <file>` is **required** — there's no live-clone fallback,
so this step needs no other stack running. Produce a dump once from any
running stack:

```bash
docker exec myapp-i0-db-1 pg_dump -U myapp -d myapp --no-owner --no-privileges > appdb.sql
./scripts/init-instance.sh -n 1 --db-dump appdb.sql 5
```

The dump is reusable across as many instances as you like. The target schema
is dropped and recreated first, so the step is repeatable rather than
appending into a database that already holds a previous clone.

**Verify:** `psql -h localhost -p 55433 -U myapp myapp -c '\dt' | head`

## Step 6 — Verify and report

Smoke checks (the database accepts connections, the app answers on its
port), then the instance summary. Start the app from this worktree:

```bash
./manage.py runserver 0.0.0.0:8001     # 8000+N
```

## Step 7 — Teardown

```bash
./scripts/init-instance.sh -n 1 down
```

Removes, for this instance only: containers, the docker network, and
`.instances/N/` (data dir, uploads, rendered config). Other instances and
the main checkout's index-0 stack are untouched. The data directory is
created root-owned by the database container, so this step falls back to
`sudo rm -rf` on that one path after a plain `rm` fails. Pass
`KEEP_UPLOADS=1` to keep the media copy for a later re-provision.

## Running two instances at once

```bash
cd ../myapp-worktrees/worktree-PROJ-402 && ./scripts/init-instance.sh -n 1 --db-dump appdb.sql
cd ../myapp-worktrees/worktree-PROJ-403 && ./scripts/init-instance.sh -n 2 --db-dump appdb.sql
```

With the main checkout's stack still up, that's three complete stacks with
no overlap on any port, subnet, container name, or host data directory:

| | index 0 | index 1 | index 2 |
|---|---|---|---|
| app | `:8000` | `:8001` | `:8002` |
| database | `:55432` | `:55433` | `:55434` |
| subnet | `10.30.5.0/24` | `10.30.6.0/24` | `10.30.7.0/24` |

## Troubleshooting

**`network ... already exists with subnet X, expected Y`** — an earlier
instance used that name with a different subnet. `docker network rm
myapp-net-iN`, or pick another index.

**Port already in use** — another instance has the same index, or the
index-0 stack is on the port you derived. `docker ps --format '{{.Names}}
{{.Ports}}'` shows who holds it.

**App starts but the data looks like another branch's** — `.env.local`
wasn't re-rendered after switching index. Re-run step 3, then step 4.

**Database container restarts in a loop** — a data directory left behind by
a different major version of the image. Remove `.instances/N/pgdata/` and
re-run steps 4 and 5.

## Related files

| file | role |
|---|---|
| `scripts/init-instance.sh` | the steps above, 1–7 |
| `scripts/templates/` | the templates step 3 renders |
| `.instances/` | per-instance state; gitignored in full |
| `docker-compose.yml` | the main checkout's index-0 stack, unchanged |

---

## If your project is stateless, this file is much shorter

A frontend or a stateless service has no external state to duplicate — only
a port to move — so the whole file can be:

> Each worktree runs its own dev server. Install dependencies in the
> worktree (`npm install` — `node_modules` is per-worktree), then start it
> on a free port: `npm run dev -- --port 5175`. The main checkout uses
> 5174; take 5175, 5176, … per worktree. Nothing else is shared.

Write the shorter version rather than padding it out to look like the one
above. The file earns its place by saying what someone would otherwise have
to work out — not by covering every heading in this example.
