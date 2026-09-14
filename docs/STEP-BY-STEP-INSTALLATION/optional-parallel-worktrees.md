---
slug: /step-by-step-installation/optional-parallel-worktrees
sidebar_position: 5
sidebar_label: "Optional: parallel worktrees"
---

# Optional: parallel worktrees

**Only if you'll run more than one worktree's app at a time.** Most projects
never need this, but the assigner gives each issue its own worktree, which
isolates the *source tree* and nothing else: a database, a cache, an uploads
tree or a fixed port is shared between every worktree by default.

Two instances against one migration-driven database can reshape the schema
under each other, silently.

The answer, once you've made it, goes in `.jst/bootstrap.sh`
(`bootstrap.ps1` on Windows) — the optional hook `jira-task-executor` runs in
its step 1, once per worktree, fail-soft. `.jst/teardown.sh` is the by-hand
counterpart you run before `git worktree remove`; no skill invokes it.
Statuscheck's `bootstrap` row reports whether you have one and never blocks
either way.

[Parallel instances](../parallel-instances/RUNNING-MULTIPLE-COPIES.md) is the
whole story: the share-vs-isolate decision framework, the `JST_*` environment
contract, and three worked examples:
[Python toolchain](../parallel-instances/python.md),
[React / Vite SPA](../parallel-instances/react.md), and
[multi-service docker-compose stack](../parallel-instances/docker-compose.md).
