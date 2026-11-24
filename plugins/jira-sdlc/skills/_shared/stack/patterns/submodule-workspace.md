<!-- Adapted from ControlFreak (controlfreak@7af306f: plugins/controlfreak/skills/space-init/instances/patterns/submodule-workspace.md). Owned here. -->

# Pattern: a workspace of submodules

A `submodules` project has one `./stack` in the workspace's root that starts every
member; the trial works in a whole-workspace checkout (each member at the commit the
workspace records, a worktree of the member's own repo). This page holds what carries over
from the first such workspace.

A **workspace** repo holds **member** repos as git submodules: a web app,
a server, a pipeline, a few GPU services. A running copy is every pattern
at once, per member: Node members need `node_modules`, Python members a
venv each, the server its database, and so on. The example this page is
drawn from has ten members, a Postgres seeded from the main database, a
shared Kafka broker with per-instance topics, a shared GPU service, and
4.5 GB of model files.

## What carries over

- **One list of the workspace's members in the root repo's `stack.d/`**: which are Node
  and which Python, each service with its member directory, command and its place among the
  instance's ports, the large files to link. The root's `./stack` loops over it; a new
  member is a line, not new code.
- **Prepare per member, create-if-missing**, with a marker written only
  after success (an interrupted install is redone, not taken as done).
- **Large read-only files by hard link** from the main checkout (`cp -al`
  for a directory, `ln` for a file), into a temporary name first, then
  `mv`: no download, no extra disk.
- **Files jobs rewrite are copied**, not linked (`cp -a` of `media/`).
- **Shared on purpose**: the broker, the GPU lock, model caches. Checked by
  `up`, started by the human in the main checkout.
- **Per-instance names inside shared services**: topics and consumer
  groups prefixed by the instance (`app.i<N>.…`); `down` deletes exactly
  those, through the app's own management command, before it removes the
  database.
- **Order in `down`**: the shared-service cleanup needs the instance's
  venv and env files, so it runs first; if it fails, stop and change
  nothing else.
- **Never `git submodule deinit` in a checkout**: submodule config lives in
  the main repository's `.git/config`, shared by every worktree.
- **Vendored submodules** nobody edits stay uninitialized in checkouts
  (`submodule.<path>.update=none`) unless the stack needs them.

## In issue worktrees and the trial's checkout

- **Every member is checked out**: in an issue worktree, the executor's `repos.sh provision`
  puts the members the issue touches on its branch and leaves the rest at the commit the
  workspace records; in the trial's checkout, every member is at its recorded commit. Each
  is a worktree of the human's own member repo. Vendored members stay empty: a stack that needs
  one checks it out itself (`git -C <member> …` is the stack's business;
  never `git submodule update` from a remote in an instance).
- **`CF_MAIN_CHECKOUT`** is the workspace's main checkout: link large
  read-only files and copy per-member state from there.
- **GPU services** a busy machine can't run twice are shared with the main
  checkout (checked by `start`, started by the human), never started per
  instance.

## When one member is the whole app

A workspace whose app lives in one member (the others are libraries, tooling, docs) keeps
that member's own `./stack`: the member is a repo people clone and run by itself, and its
stack changes with its code. The workspace root gets a thin `./stack` with the marker that
hands every verb and argument to the member's (`exec "$ROOT/<member>/stack" "$@"`), with its
own `stack.d/resources.conf` holding the member's values (a copy, kept in step by the
README's note, or a symlink to the member's). The root's `bootstrap` may also prepare the
other members' tooling (a venv a member's checks need). If the member's stack finds its main
checkout from git, check it works inside a submodule (the contract's *Finding the main
worktree*).
