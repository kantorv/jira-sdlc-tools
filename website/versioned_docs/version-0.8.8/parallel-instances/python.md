---
slug: /parallel-instances/python
sidebar_position: 2
sidebar_label: Python toolchain
---

# Worked example — a per-worktree Python toolchain

The smallest useful hook there is, and the one this repository runs on
itself. The project owns **no external state at all**: no database, no
queue, no uploads, no server that binds a port. Nothing in
[the share-vs-isolate table](RUNNING-MULTIPLE-COPIES.md) applies, because
there is nothing to share.

So why have a hook? Because a freshly created worktree is a source tree
with no *tools*. This repo's checks run out of a virtualenv —
`cedit md canonicalize` for Markdown, `actionlint` for workflows — and a
venv cannot be shared between worktrees anyway: its scripts hardcode
absolute paths, so a `venv/` created in the main checkout activates the
main checkout's copy no matter which worktree you're standing in. One
venv per worktree is forced, and the hook is what stops that from being a
thing each person remembers to do by hand.

**"Parallel instances" here means parallel toolchains, not parallel
servers.** If your project is a library, a CLI, or a repo of scripts,
this is the shape you want.

## What's shared, what isn't

| asset | decision | why |
| -- | -- | -- |
| `venv/` | **isolated** (unavoidable) | venv scripts hardcode absolute paths; a shared one would always activate the main checkout |
| pip's HTTP cache | **shared** | it's a cache keyed by package version, so a second worktree's install is mostly a copy from disk |
| the source checkout | **isolated** (that's the point) | each worktree is its own branch |
| ports, databases, storage | — | none exist |

There is no instance index, because nothing is numbered. That is the
whole reason this example is short.

## `.jst/bootstrap.sh`

```bash
#!/usr/bin/env bash
# bootstrap.sh — provision this worktree's Python environment.
#
# Runs once per worktree: if venv/ exists, it exits quietly.
# To re-bootstrap: rm -rf venv && .jst/bootstrap.sh
#
# The venv is only active inside this script; activate it in your own shell:
#   source venv/bin/activate

set -euo pipefail

WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Refuse if this is the main checkout (not a worktree).
# mapfile, not a pipe into awk: `awk '{print; exit}'` closes the pipe early and
# SIGPIPEs git, which `set -o pipefail` then turns into a failed bootstrap.
mapfile -t worktree_list < <(git -C "$WORKTREE" worktree list --porcelain | awk '/^worktree /{print $2}')
MAIN_CHECKOUT="${worktree_list[0]:-}"
[ -n "$MAIN_CHECKOUT" ] && [ "$WORKTREE" != "$MAIN_CHECKOUT" ] \
    || die "this is the main checkout ($WORKTREE), not a worktree. Bootstrap runs only in worktrees."

# Already bootstrapped? This is the whole idempotency story.
[ -d "$WORKTREE/venv" ] && exit 0

log "python environment: $WORKTREE/venv"
python3 -m venv "$WORKTREE/venv"
# activate scripts touch unset variables ($PS1), which trips `set -u`
set +u; . "$WORKTREE/venv/bin/activate"; set -u
pip install cedit

# actionlint isn't a PyPI package — it's a Go binary, fetched via its own
# install script straight into venv/bin so `source venv/bin/activate` puts it
# on PATH next to cedit.
log "installing actionlint into $WORKTREE/venv/bin"
bash <(curl -fsSL https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash) \
     latest "$WORKTREE/venv/bin"

log "bootstrap complete — activate with: source $WORKTREE/venv/bin/activate"
```

Four things in there are worth copying into any hook, whatever the stack:

- **It ignores every `JST_*` variable.** The executor exports all five,
  and this script needs none of them — it derives the worktree from its
  own location, which also makes it runnable by hand. A hook that ignores
  variables it has no use for is not missing anything.
- **It refuses to run in the main checkout.** The main checkout is the
  first entry `git worktree list --porcelain` prints, so comparing against
  entry zero is a two-line guard. Here it only prevents a stray `venv/`; in the
  [docker-compose example](docker-compose.md) the same guard is what stops
  an instance from overwriting the originals it clones from.
- **The early exit is the idempotency.** No flags, no state file: the
  artifact's existence is the check. A re-run after a rejected review
  costs one `[ -d ]` test.
- **It says what to do next.** The venv is active inside the script and
  nowhere else, so the last line hands over the `source` command rather
  than leaving the caller to guess why `cedit` isn't on `PATH`.

## `.jst/teardown.sh`

```bash
#!/usr/bin/env bash
# teardown.sh — remove the venv/ directory created by bootstrap.sh.

set -euo pipefail

WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

mapfile -t worktree_list < <(git -C "$WORKTREE" worktree list --porcelain | awk '/^worktree /{print $2}')
MAIN_CHECKOUT="${worktree_list[0]:-}"
[ -n "$MAIN_CHECKOUT" ] && [ "$WORKTREE" != "$MAIN_CHECKOUT" ] \
    || die "this is the main checkout ($WORKTREE), not a worktree. Teardown runs only in worktrees."

if [ -d "$WORKTREE/venv" ]; then
    log "removing $WORKTREE/venv"
    rm -rf "$WORKTREE/venv"
    log "teardown complete"
else
    log "no venv found, nothing to do"
fi
```

Nothing calls this — no skill has a teardown hook — so run it yourself
before `git worktree remove`. At this size it's barely more than
`rm -rf venv`, and that's the point: it exists so that *every* project's
teardown is one command with the same name, whether it removes a
directory or tears down six containers.

## Running it

```bash
cd /home/you/src/myproject-worktrees/worktree-PROJ-402
.jst/bootstrap.sh                 # or just let the executor's step 1 do it
source venv/bin/activate
cedit md canonicalize --check docs/SOME-FILE.md
```

Two worktrees, two venvs, no coordination between them. The cost of a
second instance is one `python3 -m venv` and a mostly-cached
`pip install`.
