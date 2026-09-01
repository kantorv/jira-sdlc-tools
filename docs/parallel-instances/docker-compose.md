---
slug: /parallel-instances/docker-compose
sidebar_position: 4
sidebar_label: Multi-service docker-compose
---

# Worked example — a multi-service docker-compose stack

The expensive end of [the share-vs-isolate decision](RUNNING-MULTIPLE-COPIES.md):
an app that owns a database with migrations, an auth server with its own
realm and its own database, a reverse proxy terminating TLS, an uploads
tree, and a frontend container — every one of which two worktrees would
otherwise fight over.

This page goes in two steps. The first is the minimum that makes a
migration-driven app safe to run twice. The second is what a project
looks like once it has isolated *everything*, and what that costs.

## Step one — isolate the database, nothing else

A Django app (or any migration-driven stack) is the textbook case for
**isolating the database per worktree**. The workflow is migration-driven
by design: a feature branch routinely carries a schema migration the base
branch hasn't got yet. If two worktrees share one Postgres database,
running `migrate` in the worktree that's ahead reshapes the schema under
the worktree that isn't — and the second app starts throwing errors
against columns that moved or tables that changed. So each worktree needs
its own database, seeded from a common baseline at worktree-creation (or
launch) time.

The pattern that keeps this self-contained: a **docker-compose file
scoped to each worktree**, standing up that worktree's own database
container under the worktree's own folder, so `docker compose` run from
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

Point that worktree's settings at its own database (host port above), run
`manage.py migrate` there, and this checkout has a database that only it
can reshape — a sibling worktree still on old code keeps its own schema
until *it* migrates.

The same shape generalizes: for any asset you decided to *isolate*, scope
its instance to the worktree (its own container, port, volume, or
namespace) and point that worktree's config at it; for anything you
decided to *share*, leave the config pointing at the one common instance.

For many projects that is the end of the story. Read on if the app also
carries an auth server, TLS, and a media tree that the frontend loads by
absolute URL — because at that point the port alone stops being enough.

## Step two — isolate the whole stack

Once the app is reached over HTTPS at a hostname, the hostname itself
becomes per-instance: it's baked into the auth realm's redirect URIs, the
CORS origins, the media URL and the dev server's allowed hosts. Moving a
port no longer moves the instance.

The scheme below gives each instance its own **docker network and
subnet**, which makes every container address static and predictable, and
turns the hostname into a function of the index too.

### The allocation scheme

Everything derives from a single **instance index `N`**. One number per
instance, no manual port bookkeeping, collisions impossible by
construction.

| thing | value for index `N` | `N=1` | `N=2` |
| -- | -- | -- | -- |
| compose project | `myapp-iN` | `myapp-i1` | `myapp-i2` |
| docker network | `myapp-net-iN` | `myapp-net-i1` | `myapp-net-i2` |
| subnet | `172.20.(5+N).0/24` | `172.20.6.0/24` | `172.20.7.0/24` |
| proxy IP | `172.20.(5+N).5` | `172.20.6.5` | `172.20.7.5` |
| auth server IP | `172.20.(5+N).10` | `172.20.6.10` | `172.20.7.10` |
| app database IP | `172.20.(5+N).20` | `172.20.6.20` | `172.20.7.20` |
| frontend IP | `172.20.(5+N).100` | `172.20.6.100` | `172.20.7.100` |
| domain | `172.20.(5+N).5.nip.io` | `172.20.6.5.nip.io` | `172.20.7.5.nip.io` |
| auth host port | `8282+N` | `8283` | `8284` |
| database host port | `52586+N` | `52587` | `52588` |
| app dev server | `8000+N` | `8001` | `8002` |
| Postgres data | `pgroot/instance-N/` | in that worktree | in that worktree |

**Index 0 is the existing main-checkout stack**, on its original network
and ports. It is not managed by the per-instance tooling at all and keeps
working unchanged — the provisioning script refuses `-n 0` outright. It's
also a convenient source for the database dump the clone step needs.

`nip.io` is what makes the domain fall out of the IP for free:
`demo.172.20.6.5.nip.io` resolves to `172.20.6.5` with no `/etc/hosts`
entry and no DNS setup, so a wildcard certificate for
`*.172.20.(5+N).5.nip.io` is all the TLS an instance needs.

### Why HTTPS is not published on a host port

The proxy publishes **no** host ports. Each instance has its own subnet
and the host routes to docker bridge networks directly, which is the
whole point of the nip.io + static IP setup: the host reaches port 443 on
`172.20.6.5` natively. That keeps the domain **port-free** everywhere it
appears — the auth server's hostname, the realm redirect URIs, the media
URL, the proxy's CORS origins and the dev server's allowed hosts would
otherwise all have to carry the port too.

The auth server (`8282+N`) and the application database (`52586+N`) *are*
published, because host-side tooling needs them: the admin CLI, `psql`,
and the app's dev server, which runs on the host and connects to
`localhost:52586+N`.

:::note
Docker bridge networks are reachable from the host on Linux. On Docker
Desktop (macOS / Windows) they are not, and that platform needs published
ports instead — which means giving up the port-free domain and carrying
`:port` through every URL above.
:::

### What provisioning one instance actually does

Ten steps, each independently re-runnable, driven by one script
(`run/init-instance.sh -n <N>`):

| # | step | note |
| -- | -- | -- |
| 1 | resolve every value above from `N`, write `run/.instance.env` | every later step reads that file, so any single step can be re-run alone |
| 2 | create the per-instance docker network | idempotent: an existing network with the *expected* subnet is accepted, a different one is a hard error rather than a silent mismatch |
| 3 | generate a wildcard `mkcert` certificate for the instance domain | needs `mkcert -install` run once on the machine |
| 4 | render the per-instance config from templates | compose's `$$VAR` escapes and nginx's `$host` / `$uri` must survive rendering, so pass an explicit variable list to `envsubst` |
| 5 | materialize the gitignored assets | env files copied from the main checkout, the app's local env file rewritten for this instance, the media tree copied, Postgres data directories created |
| 6 | bring the stack up and poll until every healthcheck reports healthy | pre-flight first: the frontend path exists and has `node_modules` |
| 7 | clone the application database from a dump file | `--db-dump <file>` required, no live-clone fallback |
| 8 | seed the auth server: confirm the realm imported, create the demo user | creating a user that already exists is reported, not an error |
| 9 | smoke-check and report | health endpoint, OIDC discovery document, frontend, database connection |
| 10 | teardown | containers, network, Postgres data, rendered config, certificate, media copy |

Three of those carry a lesson that generalizes past this stack:

**The auth realm is patched, not templated.** A realm export is hundreds
of keys of which two — the client's `redirectUris` and `webOrigins` —
are instance-specific. Reading the committed export and rewriting that
one client keeps the two from drifting apart, where a full template copy
would need re-syncing on every realm change. Register both
`https://demo.<domain>` and `https://<domain>`; without the second the
login round-trip fails with `invalid_redirect_uri`.

**The frontend config wraps, not replaces.** The generated
`vite.config.instance.ts` is bind-mounted over the frontend checkout and
*imports* that checkout's own config, overriding only `allowedHosts`. The
frontend repository is never modified, and its other config changes still
apply.

**The database dump is a file, not a live connection.** Requiring
`--db-dump <file>` rather than cloning from a running stack means step 7
doesn't need any other instance up, the file is reusable across as many
instances as you like, and the step is repeatable — the target schema is
dropped and recreated rather than appended to. Produce one once:

```bash
docker exec <index-0 db container> pg_dump -U dbuser -d appdb \
  --no-owner --no-privileges > appdb.sql
```

### What it costs

Per instance: the containers, a Postgres data directory, a certificate,
and a **full copy of the media tree** — around 457 MB in the project this
example is drawn from. That copy is the point rather than an oversight:
an instance sharing the tree would have its media mutated by every other
instance. `KEEP_UPLOADS=1` on teardown keeps it for a later
re-provision, which is the difference between a 30-second and a
five-minute re-bootstrap.

Isolation at this level is worth it when a branch can corrupt the asset.
It is not worth it for the third-party sandbox account, which stays
shared — see [the decision table](RUNNING-MULTIPLE-COPIES.md).

## Wiring it to the executor

`.jst/bootstrap.sh` is a thin front end over the provisioning script: it
does what a fresh worktree needs *before* `init-instance.sh` can run, then
hands over.

```bash
#!/usr/bin/env bash
set -euo pipefail
WORKTREE="${JST_WORKTREE_DIR:-$(git rev-parse --show-toplevel)}"
DUMP="$WORKTREE/.jst/appdb.sql"
SOURCE_DB="${SOURCE_DB:-myapp-i0-postgresdb-1}"      # the index-0 stack

# 0. never provision the main checkout — it holds the originals step 5 copies from
MAIN=$(git -C "$WORKTREE" worktree list --porcelain | awk '/^worktree /{print $2; exit}')
[ "$WORKTREE" != "$MAIN" ] || { echo "main checkout — bootstrap a worktree instead" >&2; exit 1; }

# 0b. already provisioned? exit quietly rather than re-dumping over a live instance
[ -d "$WORKTREE/backend/venv" ] && exit 0

# derive a stable index from the issue key — see the hook contract
KEY="${JST_ISSUE_KEY:-$(git -C "$WORKTREE" branch --show-current)}"
N=$(( $(printf '%s' "$KEY" | cksum | cut -d' ' -f1) % 250 + 1 ))

git -C "$WORKTREE" submodule update --init --recursive   # worktree add leaves them empty
python3 -m venv "$WORKTREE/backend/venv"
set +u; . "$WORKTREE/backend/venv/bin/activate"; set -u
pip install -r "$WORKTREE/backend/requirements.txt"
( cd "$WORKTREE/frontend" && [ -d node_modules ] || yarn install )

# dump to a temp file first: a failed pg_dump would otherwise leave a truncated
# appdb.sql behind, which step 7 would happily restore
docker exec "$SOURCE_DB" pg_dump -U dbuser -d appdb --no-owner --no-privileges > "$DUMP.tmp"
[ -s "$DUMP.tmp" ] || { rm -f "$DUMP.tmp"; echo "pg_dump produced an empty dump" >&2; exit 1; }
mv "$DUMP.tmp" "$DUMP"

exec "$WORKTREE/run/init-instance.sh" -n "$N" --db-dump "$DUMP"
```

The hash-derived index is the piece to copy. Two worktrees bootstrapped
back to back must land on different instances without the caller
coordinating by hand, and the same issue key must keep mapping to the
same instance across bootstrap/teardown cycles. A collision on the
derived index is caught downstream by step 2, which refuses to take over
a network another worktree already owns — a loud failure instead of two
instances quietly sharing a subnet.

`.jst/teardown.sh` is its mirror: run step 10 for this instance, then
remove what bootstrap added on top (the venv, `node_modules`, the dump
file). It leaves the app's local env file in place — that one is
gitignored, may have been hand-edited, and the next bootstrap rewrites it
anyway. **No skill runs teardown**; call it yourself before
`git worktree remove`.

## Running three at once

```bash
cd ~/src/myapp-worktrees/worktree-PROJ-402 && .jst/bootstrap.sh
cd ~/src/myapp-worktrees/worktree-PROJ-403 && .jst/bootstrap.sh
```

With the index-0 stack still up, that's three complete stacks with no
overlap on any port, IP, docker network, container name or host data
directory:

|  | index 0 | index 1 | index 2 |
| -- | -- | -- | -- |
| app | `https://demo.172.20.5.5.nip.io` | `https://demo.172.20.6.5.nip.io` | `https://demo.172.20.7.5.nip.io` |
| auth | `:8282` | `:8283` | `:8284` |
| database | `:52586` | `:52587` | `:52588` |
| dev server | `:8000` | `:8001` | `:8002` |

Instances may share one frontend checkout — several containers serving
the same files read-only is fine, and it's the right setup for
backend-only work. For *frontend* work on more than one instance at a
time, point each at its own frontend worktree: concurrent dev servers
otherwise contend over the same `node_modules/.vite` cache.

## Troubleshooting

**`network … already exists with subnet X, expected Y`** — an earlier
instance used that name with a different subnet. Remove the network, or
pick another index.

**`invalid_redirect_uri` at login** — the realm was imported before the
instance export was rendered. A realm only imports into a *fresh*
database directory, so tear down and re-provision, or delete the auth
server's data directory and restart it.

**Browser does not trust the certificate** — `mkcert -install` hasn't
been run on this machine, or the browser was open before it was. Re-run
the certificate step afterwards.

**The frontend container restarts in a loop** — `node_modules` is missing
in the frontend path. The provisioning step only warns about it; the
bootstrap hook above is what fixes it.

**Nothing at `https://demo.<domain>`** — check the host can route to the
instance subnet (`ping 172.20.6.5`). See the Docker Desktop note above.
