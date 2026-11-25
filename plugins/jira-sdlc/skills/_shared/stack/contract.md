<!-- Adapted from ControlFreak's stack contract (controlfreak@7af306f:
plugins/controlfreak/skills/space-init/instances/stack-contract.md). The contract itself is
shared with ControlFreak, unchanged: same marker, verbs, exit codes, keys and variables, so one
project's ./stack serves both tools. Owned here. -->

# The stack contract, version 1

What a caller needs from a project's own `./stack`, and nothing more. The callers are the
jira-sdlc executor (an issue worktree's instance, through `.jst/bootstrap.sh`), the trial
(`stack-trial.sh`), the jira-sdlc web app, and ControlFreak. The project owns the tool: it
runs the stack in the main checkout every day, and a caller uses the same tool for an
instance. Everything else a stack does (`logs`, `restart api`, `update`, project-only verbs)
is the project's own.

## Files

```text
./stack                    the tool: bash, executable, the verbs below
stack.d/resources.conf     the stack's host resources (below); read by ./stack and by callers
stack.d/README.md          what the stack decided and why (readme-spec.md)
stack.d/…                  anything else the tool needs (helpers, compose files)
```

Line 2 of `./stack` is the marker, exactly:

```bash
# controlfreak-stack-contract: 1
```

(The name is historical: the contract started in ControlFreak.) A `./stack` without it is
read for knowledge only.

## The verbs a caller runs

| Verb | Does | Exit |
| -- | -- | -- |
| `./stack start --instance N` | prepares the checkout if needed (as `bootstrap`), starts instance N and **waits until every service answers**; the **last stdout line** is `{"urls": {"<label>": "<url>", …}}` | 0 up; 1 a step failed |
| `./stack stop --instance N` | stops instance N's services; data and files stay | 0; 1 |
| `./stack teardown --instance N` | removes everything instance N made (containers, volumes, networks, files), except its logs; **refuses (exit 3) while a service still runs**, touching nothing | 0; 1; 3 |
| `./stack status --instance N` | reports instance N | 0 only when every service answers |
| `./stack bootstrap --instance N` | prepares the checkout (env file, dependencies) without starting anything | 0; 1 |

Without `--instance`, the same verbs act on the main checkout (`teardown` refuses there).
Every verb is **idempotent**: `start` on a running instance leaves it running, `stop` and
`teardown` on a stopped or absent one succeed. A bad `--instance` (not an integer in the
stack's range, or `007`) or a bad environment exits **2 before touching anything**.

## Named steps

Each verb is a list of named steps. Before a step, stderr gets `::step::<name>`; if it fails,
`::step-failed::<name> (exit <code>)`, and the verb ends with that code. Callers read the
markers to say which step failed. Progress goes to stderr; stdout carries only what a caller
reads (the URLs line, `status`'s report). The example's `step` helper is in
`examples/vite-spa/stack.d/lib.sh`.

## `stack.d/resources.conf`

Plain `KEY=value` lines and `#` comments: no quotes, spaces, `$`, backquotes or backslashes in
a value. The tool refuses any other line, so it and every caller read the same values.

| Key | Meaning |
| -- | -- |
| `NAME_PREFIX` | every name an instance makes: `<prefix>-i<N>` (containers, networks, compose projects) |
| `INSTANCE_MIN`, `INSTANCE_MAX` | the instance numbers the stack accepts; the plugin hashes an issue key into this range |
| `SUBNET` | optional: a private `/16`; instance N gets `<a.b>.N.0/24` |
| `PORT_BASE`, `PORT_COUNT` | optional: the host port block the stack uses |
| `PORTS_PER_INSTANCE` | with a port block: instance N uses `PORT_BASE + (N - INSTANCE_MIN) × PORTS_PER_INSTANCE` onward |
| `SHARED_PORTS` | optional: the main checkout's ports, comma-separated, of the services every instance needs running (a broker, the database a seed copies); the trial refuses to start while nothing listens on one |

The project's own keys (the main checkout's ports, anything else the stack reads) sit beside
them; callers ignore those.

## The environment

A caller runs the verbs from the checkout under test. The tool reads:

| Variable | When unset |
| -- | -- |
| `CF_INSTANCE_HOME`: instance N's private directory (env file, PID files, logs); it exists | `~/.local/state/<NAME_PREFIX>/i<N>`, created `0700` |
| `CF_MAIN_CHECKOUT`: the repo's main checkout (shared dependencies, local settings, ignored files to copy) | the repository's main worktree |

The jira-sdlc executor sets neither: the defaults are the point, so the stack runs the same
from a terminal, the executor, and any caller. The names keep their `CF_` prefix because they
are the contract's.

**Finding the main worktree** from a checkout: the git common dir's parent in a plain repo,
but inside a submodule the common dir is `<workspace>/.git/modules/<member>`, whose parent is
not a checkout (and `git worktree list` names that gitdir too). There, the checkout is the
gitdir's `core.worktree`, relative to the gitdir:

```bash
main_worktree() {
  local common wt
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  wt=$(git config --file "$common/config" core.worktree 2>/dev/null || true)
  if [ -n "$wt" ]; then (cd "$common" && cd "$wt" && pwd); else dirname "$common"; fi
}
```

**The stack's own switches come from the environment**: a choice an instance may or may not
want (`WITH_FACEKIT=1`, `TTS_DEVICE=cuda:0`) is a variable the stack reads with a default
(`${WITH_FACEKIT:-0}`), never a separate verb or a file edit; `status` says which way it
went. Names are upper case and never `CF_*`.

## Rules

- Never touch the main checkout's own services or data; copy what an instance needs.
- Never print a secret; generate an instance's secrets once and keep them until `teardown`.
- Names, ports and addresses only from `stack.d/resources.conf` and the instance number.
- Never `git submodule deinit` or change git config in a checkout.
