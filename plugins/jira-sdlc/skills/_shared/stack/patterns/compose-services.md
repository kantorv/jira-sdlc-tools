<!-- Adapted from ControlFreak (controlfreak@7af306f: plugins/controlfreak/skills/space-init/instances/patterns/compose-services.md). Owned here. -->

# Pattern: services with state (Docker Compose)

An app that owns state: a database with migrations, a cache, a broker,
uploaded files, often an auth server. Usually a `docker-compose.yml` for
the infrastructure and the app's own processes on the host (or in
containers too). This is where isolation costs something, so decide per
asset ([`../survey-method.md`](../survey-method.md), "The two places").

The shape that works: its own network and Postgres per instance (a `stack.d/compose.instance.yml`
for the instance's containers), the app's processes on the host, a database created on first
start, migrations on every start, an admin user from the main checkout's env file.

## Addresses: a subnet or the port block

|  | A subnet per instance | Ports from the block |
| -- | -- | -- |
| How | a Docker network `<NAME_PREFIX>-net-i<N>` on `<a.b>.N.0/24` from `SUBNET`; host processes bind its gateway (`<a.b>.N.1`) on their usual ports; containers get fixed addresses | containers publish `127.0.0.1:<port>` from the instance's ports; host processes bind `127.0.0.1` |
| Good for | stacks where the address is baked into config (TLS, auth redirects, CORS) and the usual ports should stay | everything else; works on Docker Desktop too |
| Needs | Linux (the host reaches bridge networks); `SUBNET` in `resources.conf` | `PORT_BASE`, `PORT_COUNT`, `PORTS_PER_INSTANCE` in `resources.conf` |

With the subnet, the API keeps its usual port at `<a.b>.N.1`.

## Shared or isolated

| Asset | Usually | How |
| -- | -- | -- |
| the database | isolated | its own container and named volume, compose project `<NAME_PREFIX>-i<N>` |
| the database's contents | the human decides (the README records it) | empty + migrate, a dump of the main database, or fixtures (below) |
| a broker (Kafka, RabbitMQ) | the broker shared, the topics or queues isolated | names prefixed by `<NAME_PREFIX>-i<N>`; the main checkout runs the broker; `start` checks it |
| a cache (Redis) | isolated if cheap, else shared with a key prefix |  |
| uploaded or generated files | isolated: a copy (jobs rewrite them) | `cp -a` from the main checkout into the checkout or `CF_INSTANCE_HOME` |
| large read-only files (weights) | shared | hard links (`cp -al`, `ln`) from the main checkout |
| secrets (env files) | copied once from the main checkout | `0600`, per-instance keys rewritten, never printed |
| generated secrets (a database password) | per instance | made once on first up, kept in `CF_INSTANCE_HOME/env` (`0600`) |

## Compose, per instance

```bash
compose() {
  docker compose -p "$NAME" -f "$HERE/stack.d/compose.instance.yml" "$@"   # NAME=<NAME_PREFIX>-i<N>
}
compose up -d --wait --wait-timeout 60    # start: create or start; waits for healthchecks
compose stop                               # stop: keeps the volume
compose down -v --remove-orphans           # teardown: removes containers and volumes
```

The compose file takes the per-instance values by interpolation
(`${NAME}`, `${DB_PORT}`, `${INSTANCE_SUBNET}`), gives every service a
**healthcheck** (so `--wait` means ready), names nothing by hand
(`container_name:` would collide between instances), and keeps its
network `external` when `up` creates it on the subnet. A separate
`compose.instance.yml` beside the main one is usual: the main checkout's
stack keeps its ports and names.

## Seeding

- **Empty + migrate**: the database container starts empty;
  `manage.py migrate` / `alembic upgrade head` on every up (idempotent).
  Fixtures, if any, once (a marker file in `CF_INSTANCE_HOME`).

- **A copy of the main database** (real data; the human confirms): dump
  from the main checkout's container into a temporary file, check it's
  complete, restore in one transaction only into an empty database:

  ```bash
  dump=$(mktemp)    # 0600; removed below
  docker exec "$MAIN_DB" sh -c 'pg_dump --no-owner --no-privileges -U "$POSTGRES_USER" -d "$POSTGRES_DB"' >"$dump" \
    && tail -n 5 "$dump" | grep -q 'PostgreSQL database dump complete' \
    && compose exec -T db sh -c 'psql -q -v ON_ERROR_STOP=1 --single-transaction -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <"$dump"
  rm -f "$dump"
  ```

  "Empty" means: no migrations table yet. A failed restore leaves it
  empty, so the next up tries again.

- **A dump file** the human keeps: same restore, from the file the README
  names; no main database needed.

Migrations run after seeding, every up: the branch may carry new ones.

## Lessons that carry over

- **Check, then create**: an existing network with the expected subnet is
  fine; one with another subnet is a `NOT DONE`, not a silent mismatch.
- **Patch, don't template, big config** (an auth realm export): read the
  committed file and rewrite only the per-instance keys (redirect URIs,
  web origins), so the two never drift.
- **Wrap, don't replace, the app's config**: an instance config that
  imports the app's own and overrides two keys keeps every other change.
- **Pull images during the trial**, not on every up.
- **`teardown` refuses while a service runs** (exit 3) and removes only
  `<NAME_PREFIX>-i<N>`'s containers, volumes and networks, then the instance's files
  except `logs/`.
