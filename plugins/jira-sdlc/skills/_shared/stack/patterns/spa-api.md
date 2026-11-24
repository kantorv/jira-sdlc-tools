<!-- Adapted from ControlFreak (controlfreak@7af306f: plugins/controlfreak/skills/space-init/instances/patterns/spa-api.md). Owned here. -->

# Pattern: a frontend with its own API (no database)

A frontend plus a server the repo also owns: an API, a helper service, an
engine wrapper, run side by side in development (`yarn api:start`,
`uvicorn`, `node server.js`). No database or broker of its own; if it has
one, read [`compose-services.md`](compose-services.md) too.

The difference from a plain SPA: **the frontend must call its own
instance's API**, not the main checkout's. Otherwise QA tests the new
frontend against the old server.

Start from [`../examples/vite-spa/`](../examples/vite-spa/) and add the
second service.

## Shared or isolated

| Asset | Decision | Why |
| -- | -- | -- |
| ports (frontend and API) | isolated | the instance's first two ports |
| the API process | isolated | it runs the branch's own code |
| the frontend's API URL | isolated | it points at this instance's API |
| local tools the API runs (an engine binary, a model) | shared | read-only; the path comes from an ignored config copied from the main checkout |
| `node_modules` / the API's venv | isolated | per checkout |

## The changes to the example

`./stack`, where the ports are computed (`PORTS_PER_INSTANCE` in `resources.conf` is at
least 2), and its copies:

```bash
FIRST=$((PORT_BASE + (INSTANCE - INSTANCE_MIN) * PORTS_PER_INSTANCE))
WEB_PORT=$FIRST
API_PORT=$((FIRST + 1))
COPY_ONCE=(.env.local server/engine-api/engines.local.json)
```

…and two more steps in `start`, after the copies and before the frontend starts:

```bash
# per-instance keys in the copied env file: rewrite those lines, keep the rest
set_env() {  # set_env <file> KEY=VALUE...
  local file=$1 keys tmp; shift
  keys=$(printf '%s\n' "$@" | cut -d= -f1 | paste -sd'|')
  tmp=$(mktemp "$file.XXXXXX")
  { grep -vE "^($keys)=" "$file" 2>/dev/null || true; printf '%s\n' "$@"; } >"$tmp"
  chmod 600 "$tmp" && mv "$tmp" "$file"
}
point_web_at_api() { set_env "$HERE/.env.local" "VITE_API_BASE_URL=http://127.0.0.1:$API_PORT"; }
start_api() { launch api "$HERE" env PORT="$API_PORT" yarn api:start; }
wait_api() { wait_http api "http://127.0.0.1:$API_PORT/health" 200; }

step "Point the frontend at its API" point_web_at_api
step "Start the API" start_api
step "Wait for the API" wait_api
```

…and the `urls` line names both (`"web app"` and `"API"`). `stop` stops `web` then
`api`; `teardown` refuses while either runs.

## What to look for in the repo

- **How the API takes its port**: a flag, `PORT`, a config file. If it's
  hard-coded, the instance can't run in parallel: say so to the human and
  propose the smallest change (read it from the environment, keep the
  default), as part of the setup branch.
- **How the frontend finds the API**: a `VITE_*` variable, a proxy in
  `vite.config.*` (then the proxy target must read the port from the
  environment), or a runtime config file. Rewrite exactly that, per
  instance.
- **CORS and allowed hosts**: an API that allows only
  `http://localhost:5173` refuses the instance's origin. Make the origin a
  per-instance value too.
- **A health endpoint** to wait for; without one, wait for any HTTP answer
  on a known path and say so in `stack.d/README.md`.
- **Ignored config with machine paths** (engine binaries, model folders):
  copy it once from the main checkout; the paths stay valid on the same
  machine.
