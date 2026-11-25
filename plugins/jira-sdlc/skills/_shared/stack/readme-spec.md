<!-- Adapted from ControlFreak (controlfreak@7af306f: plugins/controlfreak/skills/space-init/instances/spec.md). Owned here. -->

# What the stack's README records

`jst-stack`'s decisions, written to `stack.d/README.md` and committed with the stack. It is
what the human reads before trying it, and what the next person reads before changing the
stack. Keep every section, write "none" where it applies; one line of *why* per decision.
The example's ([`examples/vite-spa/stack.d/README.md`](examples/vite-spa/stack.d/README.md))
is a short, complete one.

```markdown
# This app's stack

Pattern: <vite-spa | spa-api | compose-services | python-toolchain | …>, plus <what this repo adds>.
Written by jst-stack on <date> from `.jst/STACK.md` at <short sha>; the human's answers: <what they answered>.

| File | What it holds |
|---|---|
| `../stack` | the verbs, each a list of named steps |
| `resources.conf` | the host resources (the contract's keys and the project's own) |
| `lib.sh` | the helpers |

## Services

| Service | Runs | Main checkout | Instance N | Ready when |
|---|---|---|---|---|
| web | `yarn dev --host 127.0.0.1 --port <port> --strictPort` | 5173 | the instance's first port | `GET /` → 200 |

## What an instance shares and what it gets

| Asset | Shared or isolated | Why | How |
|---|---|---|---|
| ports | isolated | two processes can't bind one port | from `PORT_BASE`, `PORTS_PER_INSTANCE` per instance |
| `node_modules` | isolated | per checkout; branches can change the lockfile | copied from the main checkout when the lockfile matches, else `yarn install --frozen-lockfile` |

## Seed data

<none | empty database + migrate | a copy of the main database (real data, confirmed by the human) | dump file `<path>` | fixtures `<command>`>

## Ignored files the app needs

| Path (in the main checkout) | Secret? | How the instance gets it | Per-instance keys rewritten |
|---|---|---|---|
| `.env.local` | yes | copied once, `0600` | `VITE_DEV_PORT` |

## Shared services that must already run

<none | the main checkout's <service>, checked at `<url or command>`, started with `<command>` in the main checkout>.
Their ports are `SHARED_PORTS` in `resources.conf`.

## Host prerequisites

Each row is a check in the step "Check the host".

| What | Check |
|---|---|
| Node 24 + Yarn (fnm) | `$NODE_BIN/node --version`, `$NODE_BIN/yarn --version` |

## Trial notes

<anything the trial can't do here, and why: a step skipped, a slow seed, a GPU it may not get>
```
