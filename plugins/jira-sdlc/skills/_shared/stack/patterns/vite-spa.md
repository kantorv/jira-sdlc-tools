<!-- Adapted from ControlFreak (controlfreak@7af306f: plugins/controlfreak/skills/space-init/instances/patterns/vite-spa.md). Owned here. -->

# Pattern: a frontend SPA (Vite)

A single-page app that owns no state: no database, no queue, no uploads.
It talks to APIs it doesn't own. A running copy needs **its own port and its
own `node_modules`**, and maybe a copy of an ignored env file. Everything
else is shared.

**Start from the example**: [`../examples/vite-spa/`](../examples/vite-spa/)
is a complete, tested stack (`stack`, `stack.d/resources.conf`, `stack.d/lib.sh`,
`stack.d/README.md`). Copy it to the repo root and change what this repo needs.
`stack.d/lib.sh` is generic (named steps, `read_conf`, start and stop by PID file,
waiting for HTTP); keep it as it is unless the repo needs more.

## Shared or isolated

| Asset | Decision | Why |
| -- | -- | -- |
| port | isolated | two processes can't bind one port |
| `node_modules` | isolated | per checkout, and a branch may change the lockfile |
| the APIs it calls | shared | read-mostly, not branch-specific |
| browser storage | isolated in practice | each port is its own origin |

## What to look for in the repo

- **The dev command**: `package.json` `scripts.dev`. If it's plain `vite`,
  `yarn dev --host 127.0.0.1 --port N --strictPort` passes the flags
  through. If it wraps Vite (`vite --port 5173`, a script), find how the
  port is set: a flag after it wins over an earlier one, or the config
  reads an env variable (`process.env.DEV_PORT`), which `launch` can set
  (`launch web "$HERE" env DEV_PORT="$WEB_PORT" yarn dev`).
- **`--host 127.0.0.1`**: say the address. `localhost` may bind `::1` only,
  and the URL the human opens must match.
- **`--strictPort`**: a taken port must fail, not move to the next one
  (the instance would answer on a port nobody knows).
- **The package manager**: `yarn.lock` → Yarn (classic: `--frozen-lockfile`;
  Berry: `--immutable`), `package-lock.json` → `npm ci`, `pnpm-lock.yaml` →
  `pnpm install --frozen-lockfile`. Change the install line and the
  integrity marker (`.yarn-integrity`, `.package-lock.json`,
  `.modules.yaml`) together.
- **Ignored files the app reads**: `.env.local`, `*.local.json`. List each
  in `COPY_ONCE`, mark secrets in `stack.d/README.md`. A per-instance value inside
  one (a port, a URL) gets rewritten after the copy: see
  [`spa-api.md`](spa-api.md).
- **Other servers the dev setup starts**: Storybook, a mock server, an
  API proxy in `vite.config.*`. Each one that binds a port gets the next of
  the instance's ports (or isn't started in an instance: say so in the README).

## Sharp edges

- **Playwright and other test runners start their own dev server** on the
  configured port, or reuse whatever already answers there (`reuseExistingServer`). In an
  issue worktree the executor runs those checks beside a running instance: give the
  runner's port its own slot in the instance's block (read from the env file), or two
  checkouts test each other's builds.
- **Kill by PID file, never by name.** `pkill -f vite` kills every
  instance's server and the main checkout's.
- **Auth redirect URIs**: if the app signs in through an OIDC provider
  locally, each instance's `http://127.0.0.1:<port>` must be a registered
  redirect URI, or sign-in fails everywhere but the main checkout. Say so
  in `stack.d/README.md` if it can't be automated.
- **`node_modules` from the main checkout** is a copy (`cp -a`), not a
  hard link: tools write caches into it (`node_modules/.vite`).
