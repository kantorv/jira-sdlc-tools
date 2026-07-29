# `.jst/PARALLEL-INSTANCES.md` — pointer

The full, adaptable example lives with the plugin, so a marketplace install
gets it too:

**[`plugins/jira-sdlc/docs/examples/PARALLEL-INSTANCES.example.md`](../plugins/jira-sdlc/docs/examples/PARALLEL-INSTANCES.example.md)**

Copy that to `.jst/PARALLEL-INSTANCES.md` in *your* project and rewrite it
for your stack. This stub is deliberately a pointer rather than a second
copy — two copies would drift.

**This repo has no `.jst/PARALLEL-INSTANCES.md` of its own, and that's
correct.** The file is optional, and it earns its place only when a fresh
worktree needs provisioning before the project will run. This repo is
prompt files and two JSON manifests; a worktree of it is runnable the
moment it exists.

What the file is for, and what reads it, is in
[`skills/_shared/project-config.md`](../plugins/jira-sdlc/skills/_shared/project-config.md#jstparallel-instancesmd--optional-and-free-form).
How to decide what each worktree's instance shares versus isolates is in
[`docs/RUNNING-MULTIPLE-COPIES.md`](../plugins/jira-sdlc/docs/RUNNING-MULTIPLE-COPIES.md).
