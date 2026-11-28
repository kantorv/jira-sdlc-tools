<!-- Adapted from ControlFreak's space-init survey method (controlfreak@7af306f:
plugins/controlfreak/skills/space-init/survey/method.md): two places instead of three,
plus the project type. Owned here; not kept in sync. -->

# The survey's method

How `jst-survey` decides what goes into `.jst/STACK.md`. The document is what a human
confirms before any stack is written: `jst-stack` builds `./stack` from it and from
nothing else, so a fact the stack needs and the document lacks becomes a guess later.
Describe what **is**; don't design what isn't there.

## Read the repo as a new team member would

In this order, and stop reading a part once it's clear:

1. The README, `docs/`, `CLAUDE.md` / `AGENTS.md`: what the app is, how it's started,
   what it needs.
2. Manifests and their scripts: `package.json`, `pyproject.toml`, `requirements*.txt`,
   `Cargo.toml`, `go.mod`, `Makefile`, `justfile`.
3. Compose files and Dockerfiles: the services, their ports, volumes, networks and
   health checks.
4. Settings read at startup: `settings*.py`, `.env.example`, `config/`, `vite.config.*`:
   hosts, ports, URLs, which environment variables matter.
5. CI files (`.github/workflows/`): which checks run, which services they start for them
   (a check that needs Postgres in CI needs it in a worktree too).
6. Any existing stack or provisioning script: `./stack` and `stack.d/`, `.jst/bootstrap.sh`
   and `teardown.sh`, `bin/dev`, `scripts/*`, an `instance.conf`. Their ports, names and
   quirks are facts to record. See *An existing stack or hook* below.
7. The git-ignored paths (`git ls-files --others --ignored --exclude-standard --directory`):
   env files, local config, `node_modules`, large data. **Paths only: never open them.**
   An ignored env file is where secrets live; its name and location are what an instance
   needs to know (it gets copied in), its contents are not.

With member repos (the `repo_strategy` row reads `submodules`), read each member the same
way: a member is a component, or holds several.

## The project type: two separate answers

**Repo layout** decides how the jira-sdlc skills branch and land work. Take it from
statuscheck, not from `.gitmodules`: members are opt-in (`JST_MEMBERS`), and a submodule
with an outside URL may be a member or a vendored library.

| Layout | When | Note in the document |
| -- | -- | -- |
| `single` | `repo_strategy` reads `single` (a monorepo is `single` too) | the apps or packages, if more than one |
| `submodules` | `repo_strategy` reads `submodules` | the members, and what each holds |
| `ignored-members` | top-level folders that are git repos but neither tracked nor submodules | not supported by the skills: recommend converting them to submodules (Open questions) |

**Run pattern** decides the shape of the stack. Pick the closest; say why in one line; a
project that mixes two names the main one and the other's part.

| Pattern | Looks like | An instance is |
| -- | -- | -- |
| `toolchain` | a library, CLI or scripts: no long-running services | a venv or `node_modules` per worktree, nothing listening |
| `vite-spa` | one front end with a dev server, no backend of its own (or a remote one) | one dev server on its own port |
| `spa-api` | a front end and an API, often a database | the API, the front end (proxying to its own API), its own database |
| `compose-services` | several services, most in Docker Compose | its own compose project, network and volumes |
| `submodule-workspace` | any of the above spread across member repos | the above, with members on the issue branch |
| `multi-repo-workers` | an API plus host worker processes, a broker, a scarce resource (a GPU) | its own API, DB and workers; the broker shared with its topics named per instance; the scarce resource taken one at a time |

## An existing stack or hook

- **A `./stack` whose line 2 is `# controlfreak-stack-contract: 1`** is the ground truth
  for an instance: the document describes what it does. What you'd do differently goes
  under *Changes to the existing stack* once decided (asked, or plainly a bug), never under
  Open questions: `jst-stack` changes that stack rather than rebuilding it.
- **A stack inside a member** (with member repos): the contract puts `./stack` at the
  project root, so `jst-stack` adds a root `./stack` that delegates to the member's. Record
  where it lives and what the member's stack needs from outside (its main checkout path,
  the sibling members).
- **A worktree hook** (`.jst/bootstrap.sh`, run by the executor in every issue worktree):
  `jst-stack` turns it into a thin wrapper, `./stack start --instance <N>`. Record
  everything the hook does today (dependencies, copied files, ports, a database seed), so
  nothing it does is lost in the move. When the hook and the stack disagree (two port
  formulas, two writers of one env file), that's a row under *Changes to the existing stack*.
- **A second kind of instance** (another tool's `--instance N` on its own port block):
  record it and keep it apart; the document's instance N is the issue worktree's.
- **The tables describe the decided state**, what an instance gets once `jst-stack` has
  run; today's value, where it differs, is in *Changes to the existing stack*.
- **Existing practice outranks the usual answers below.** When the repo already chose
  differently (a worktree's database copied from main, not empty), that is the human's
  earlier choice: record it, and ask only about what it lacks (clearing the copied jobs).

## The two places

Every resource is decided for each place a copy of the code runs:

| Place | What it is | Who uses it |
| -- | -- | -- |
| **Main checkout** | the human's checkout of the base branch; `./stack` with no `--instance` | the human, every day |
| **Issue worktree (instance N)** | `<WORKTREES_DIR>/worktree-<KEY>`: the executor writes code *and* runs instance N here | the executor while it works, then the human testing the issue |

**N is not the survey's to decide.** The plugin assigns it (`instance.sh assign`: the
key's hash into the stack's `INSTANCE_MIN..MAX` range when free, else the next free N,
claimed), and everything after reads that claim back. Record what the stack needs from
it: how many instances may run at once, and how many ports each takes. An existing hook
with its own formula (`issue number mod 100`) is a row under *Changes to the existing
stack*.

The executor uses the worktree in two states: before its instance starts (it writes code,
runs the checks that need nothing) and with it running.

For each resource and place, one of:

| Value | Means |
| -- | -- |
| **shared** | every copy uses the main checkout's (a broker, a GPU service, a third-party sandbox) |
| **own copy** | each copy gets its own (a database, ports, files a job rewrites) |
| **copied in** | copied from the main checkout when the worktree is set up (`node_modules`, a venv, an ignored env file with per-instance values rewritten) |
| **absent** | not there, and not needed |

The test for shared or own copy: **can one copy's changes break another copy that still
runs old code?** If yes, own copy. A branch's migration reshapes a shared schema; two
versions consume each other's jobs from a shared queue. Share what a copy can only read,
or what can't be duplicated.

| Resource | Usually, in instance N |
| -- | -- |
| Relational database with migrations | own copy, **empty + migrated** (plus the project's seed or fixtures command, if it has one); a copy of the main one only when the human chooses it, and then the main DB's queued jobs must be cleared |
| Cache | own copy, or shared with keys namespaced per instance |
| File storage (uploads, `media/`) | copied in if jobs rewrite it, shared if read-only |
| Message queue / broker | the broker shared, its topics, queues or consumer groups named per instance |
| Ports | own copy, always: derived from N, never "the next free one" |
| Dependencies (`node_modules`, venv) | copied in, or installed (hard links keep it cheap) |
| Env files, local config | copied in from the main checkout, per-instance values rewritten |
| Third-party sandbox accounts | shared |
| GPUs, large model files | shared, one job at a time; files hard-linked |
| Services the main checkout keeps running | shared, checked before start |
| A sibling repo's local service (another project's API on this machine) | shared, never started or stopped by this stack; say whether a copy may write to it |

## Ask only what the repo can't tell

At most four questions, in one `AskUserQuestion` call, each a decision with
consequences, offered with the evidence and your recommendation first. Good ones:

- an instance's database: empty + migrated (the default), or a copy of the main one?
- which shared services the human keeps running in the main checkout;
- where a secret an instance needs comes from;
- whether a part of the repo is run at all (a dead service, a demo).

Don't ask what a file says, and don't ask the human to read a file aloud. Keep each
question's evidence to a line or two: the file and the fact.

Four places for what isn't settled; `jst-stack` refuses to start while *Before jst-stack*
or *Open questions* holds an unchecked item:

| It's | Goes under |
| -- | -- |
| a decision made (asked, or a plain bug in an existing stack) | the table it belongs to, and *Changes to the existing stack* when it changes one |
| an action someone must take first (push local commits, start a service once) | *Before jst-stack* |
| a decision still the user's | *Open questions*, with the options and your recommendation |
| an observation that blocks nothing (stale docs, dead config) | *Notes* |

## Write it plainly

Short sentences, the facts and the reason for each decision. A reader who has never seen
the repo should be able to start it, and know what each copy gets, from this document
alone.
