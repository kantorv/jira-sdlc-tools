<!-- Adapted from ControlFreak (controlfreak@7af306f: plugins/controlfreak/skills/space-init/instances/patterns/python-toolchain.md). Owned here. -->

# Pattern: a library, a CLI or a repo of scripts

Nothing to run: no server, no port, no state. "A running copy" means a **toolchain**: the
issue worktree needs the tools its checks use, and nothing listens. So there is no
`./stack`; `jst-stack` writes only the hook (`STACK SKIPPED`), and the executor runs it in
every new worktree.

## The hook instead

| Asset | Decision | Why |
| -- | -- | -- |
| the venv | isolated, made per worktree | a venv's scripts hard-code absolute paths: a copy keeps running the original's interpreter |
| the package cache (uv, pip) | shared | keyed by version, so a second install is a local copy |

`.jst/bootstrap.sh` makes the venv from the lock file, from the local cache, create-if-missing
(`uv venv -q venv && uv pip sync -q --python venv/bin/python requirements.txt`; `uv.lock` →
`uv sync --frozen`; Poetry → `poetry install --no-root --sync`), and refuses to run in the
main checkout. `.jst/teardown.sh` removes it. The checks then use `venv/bin/…` by path.

## When an instance still makes sense

A CLI with a long-running mode (a TUI, a local web dashboard, a bot that listens on a port)
is really one of the other patterns: take [`vite-spa.md`](vite-spa.md)'s shape and replace
the dev server with the command, its port from the block.
