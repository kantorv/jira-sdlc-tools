# This app's stack (example: a Vite SPA)

The example of the [stack contract](../../../contract.md), version 1:
a single-page app whose only service is the Vite dev server. A real stack's README also names
when `jst-stack` wrote it and the human's answers. For Postgres in Docker and an instance
network, see [`compose-services.md`](../../../patterns/compose-services.md).

| File | What it holds |
| -- | -- |
| `../stack` | the verbs, each a list of named steps; the main checkout and instance N side by side |
| `resources.conf` | the host resources: the name prefix, the instance range, the port block, the main checkout's port |
| `lib.sh` | generic helpers: `step`, `read_conf`, services by PID file, ports, HTTP waits |

## Services

| Service | Runs | Main checkout | Instance N | Ready when |
| -- | -- | -- | -- | -- |
| web | `yarn dev --host 127.0.0.1 --port <port> --strictPort` | `MAIN_WEB_PORT` (5173) | `PORT_BASE + (N - INSTANCE_MIN) × PORTS_PER_INSTANCE` | `GET /` → 200 |

## What an instance shares and what it gets

| Asset | Shared or isolated | Why | How |
| -- | -- | -- | -- |
| the port | isolated | two processes can't bind one port | the first of the instance's ports |
| `node_modules` | isolated | per checkout; a branch can change the lockfile | copied from the main checkout when `yarn.lock` is the same, else `yarn install --frozen-lockfile` |
| `.env.local` (git-ignored, a secret) | copied | the app reads it | copied once, `0600`, never printed |
| the APIs the app calls | shared | it only reads them | unchanged config |
| browser storage | isolated in practice | each port is its own origin | nothing to do |

No seed data; no shared service has to run first. The main checkout's PID files and logs are in
`.stack/` (git-ignored); an instance's are in its home (`CF_INSTANCE_HOME`, else
`~/.local/state/vitespa/iN`), and `teardown` removes all of it but the logs.

## Host prerequisites

The step "Check the host" (in `bootstrap` and `start`) says what's missing: Node and Yarn
through fnm (`NODE_BIN` overrides the path), `curl`, `ss` (iproute2) and `setsid`
(util-linux).
