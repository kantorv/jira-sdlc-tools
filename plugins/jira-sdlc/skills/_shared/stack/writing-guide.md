<!-- Adapted from ControlFreak's stack-run guide and instances library (controlfreak@7af306f:
plugins/controlfreak/skills/space-init/stack.md, instances/README.md). Owned here. -->

# Writing a project's `./stack`

What `jst-stack` writes from a confirmed `.jst/STACK.md`. The stack is the project's own tool:
the human runs it in the main checkout every day, and the executor runs it as **instance N**
in every issue worktree, through `.jst/bootstrap.sh`. It follows the
[stack contract](contract.md), version 1.

## What you write

```text
./stack                    bash, executable, line 2: # controlfreak-stack-contract: 1
stack.d/resources.conf     the host resources, plain KEY=value (the contract's keys and the project's own)
stack.d/lib.sh             the helpers (take the example's: named steps, read_conf, PID files, waits)
stack.d/README.md          what you decided and why (readme-spec.md: every section)
stack.d/…                  anything else the stack needs (a compose file for an instance's services)
.jst/bootstrap.sh          the executor's hook: a thin wrapper (below)
.jst/teardown.sh           its counterpart: a thin wrapper (below)
```

Start from the closest example and adapt it; don't write one from nothing:

| `.jst/STACK.md`'s run pattern | Read | Start from |
| -- | -- | -- |
| `toolchain` | [`patterns/python-toolchain.md`](patterns/python-toolchain.md) | no `./stack`: only the hook (`STACK SKIPPED`) |
| `vite-spa` | [`patterns/vite-spa.md`](patterns/vite-spa.md) | [`examples/vite-spa/`](examples/vite-spa/) |
| `spa-api` | [`patterns/spa-api.md`](patterns/spa-api.md) | the example, plus a second service on the next port |
| `compose-services` | [`patterns/compose-services.md`](patterns/compose-services.md) | the example's `lib.sh`, plus a compose project per instance |
| `submodule-workspace`, `multi-repo-workers` | [`patterns/submodule-workspace.md`](patterns/submodule-workspace.md), and the pattern of each member's part | one root `./stack` looping over the members, or a thin root wrapper when one member is the whole app |

Most projects are a mix: take the closest page and add what the document says beyond it.

## What the repo already has

- **No `./stack`**: write one.
- **A `./stack` without the marker** (the project's own): read it for knowledge, then write the
  contract's stack. Keep the project's own verbs where they don't clash (`logs`, `restart`);
  never break what the human runs in the main checkout today, and say in the report what
  changed for them.
- **A `./stack` with the marker**: it is already this contract's. Change only what
  `.jst/STACK.md`'s *Changes to the existing stack* lists, one row at a time, and nothing else;
  the human uses it today.
- **A hand-written `.jst/bootstrap.sh`**: it becomes the wrapper. Everything it did that the
  document keeps moves into `./stack`'s `bootstrap`/`start` first, so nothing is lost.
- **A hard-coded port or URL in the app** an instance can't run with: the smallest change that
  reads it from the environment and keeps the default, in the same commit; say so in the README
  and the report.

## The verbs and the steps

- `start`, `stop`, `teardown`, `status`, `bootstrap`, each with `--instance N` (an instance) and
  without it (the main checkout; `teardown` refuses there). Every verb is idempotent.
- Each verb is a list of **named steps** (`step "<name>" <function>`), so a failure says where.
  The first step of `bootstrap` and `start` is **"Check the host"**: every prerequisite in
  [`host.md`](host.md) the stack needs, read-only, `NOT DONE: <what>: <recipe>` when one is
  missing.
- `start --instance N` waits until every service answers, then prints the **last stdout line**
  `{"urls": {"<label>": "<url>", …}}`. Progress goes to stderr only.
- `teardown --instance N` **refuses with exit 3** while a service of N runs, touching nothing;
  it removes everything N made except its logs.
- Exit codes: 0 done; 1 a step failed; 2 refused before touching anything; 3 teardown while
  running.

## The values

`stack.d/resources.conf` holds every name and port; `./stack` reads it with `read_conf`.
Propose new values with `stack-resources.sh propose`, which checks them against the host and
every other project's `resources.conf` it can find; keep an existing stack's values.

| Key | What |
| -- | -- |
| `NAME_PREFIX` | every name an instance makes: `<NAME_PREFIX>-i<N>` |
| `INSTANCE_MIN`, `INSTANCE_MAX` | the numbers the stack accepts; the plugin hashes issue keys into this range, so a wider range means fewer collisions |
| `PORT_BASE`, `PORT_COUNT`, `PORTS_PER_INSTANCE` | instance N's ports: `PORT_BASE + (N - INSTANCE_MIN) × PORTS_PER_INSTANCE` onward |
| `SUBNET` | a private `/16`: instance N gets `<a.b>.N.0/24` |
| `SHARED_PORTS` | the main checkout's ports of the services an instance can't start without (the README's *Shared services that must already run*), e.g. `29392,52790`; none → leave it out. The trial checks them before it starts anything |
| the project's own | the main checkout's ports, anything else the stack reads |

## The hook

The executor runs `.jst/bootstrap.sh` in every new issue worktree, fail-soft, with `JST_INSTANCE`
(N, already claimed by `instance.sh`) among its `JST_*` variables. Write it as:

```bash
#!/usr/bin/env bash
# .jst/bootstrap.sh: start this issue worktree's instance (written by jst-stack).
# The executor runs it with JST_INSTANCE set; by hand: JST_INSTANCE=<N> .jst/bootstrap.sh
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${JST_INSTANCE:-}" ]; then
  # An executor older than JST_INSTANCE: the plugin's formula (instance.sh number), unclaimed.
  : "${JST_ISSUE_KEY:?neither JST_INSTANCE nor JST_ISSUE_KEY is set}"
  min=$(sed -n 's/^INSTANCE_MIN=//p' stack.d/resources.conf); max=$(sed -n 's/^INSTANCE_MAX=//p' stack.d/resources.conf)
  JST_INSTANCE=$(( $(printf '%s' "$JST_ISSUE_KEY" | cksum | cut -d' ' -f1) % (max - min + 1) + min ))
fi
exec ./stack start --instance "$JST_INSTANCE"
```

`.jst/teardown.sh` is the same with `./stack stop --instance "$JST_INSTANCE"` then
`./stack teardown --instance "$JST_INSTANCE"`, run by hand before the worktree is removed. A
`toolchain` project's hook makes the venv instead (its pattern page). Keep both executable.

## Rules

- Never touch the main checkout's own services or data from an instance; copy what it needs.
- Never print a secret; generate an instance's secrets once and keep them until `teardown`.
- Kill by PID file (a process group), never by name: `pkill -f vite` kills every instance.
- Never `git submodule deinit` or change git config in a checkout.
- Optional parts are switches in the environment (the contract's *The environment*); name
  them in `stack.d/README.md`.
- Find the main checkout with the contract's `main_worktree` (the git common dir's parent,
  or its `core.worktree` inside a submodule), never `git worktree list`'s first entry alone.

## Checking it

Never run `./stack`, the app, Docker or an install while writing: the trial does that
(`stack-trial.sh`). Check what you can without running it: `bash -n stack`, `bash -n` every
script under `stack.d/` and `.jst/`, `shellcheck` if it exists, `chmod +x` on `./stack` and
the hooks, and `stack-resources.sh check`.
