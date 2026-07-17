# Lab channel

You're reading this on the [`lab`](https://github.com/kantorv/jira-sdlc-tools/tree/lab)
branch — the channel this file describes.

[`README.md`](README.md) describes the **main** channel: the repo's
default branch, and what every install command on that page gives you —
the three core skills, reviewed, released, and tagged.

The **lab** channel is the same plugin, sourced from the `lab` branch
instead. It's kept synced with the default branch, so it's never
*behind* main — it's main plus work that hasn't landed in `development`
yet: more advanced scripts, wider permissions and rights, and two extra
skills.

## The two lab-only skills

- **`jira-task-helper`** — the utility knife for the around-the-task
  plumbing the core three deliberately leave out: a cross-worktree
  `status` dashboard, `cleanup` of worktrees whose work is already
  merged, `dump_changes` to fold stray base-branch edits into a proper
  issue + branch + worktree + PR, `sync_conversations` to attach a run's
  transcripts to its Jira issue, and `setup` to bootstrap a machine.
- **`conversation-debugger`** — post-mortems a recorded run of one of
  the three core skills against its own prose, verdicting each
  instruction as followed / diverged / skipped / not-reached.

## Installing the lab channel

Same two routes as the main channel — you just point them at the `lab`
branch.

### Remote — from the marketplace

Suffix the repo with `@lab`:

```
/plugin marketplace add kantorv/jira-sdlc-tools@lab
/plugin install jira-sdlc@jira-sdlc-tools
```

To switch back to the main channel, re-add the repo without the suffix:

```
/plugin marketplace add kantorv/jira-sdlc-tools
```

### Local — clone the `lab` branch

```bash
git clone -b lab https://github.com/kantorv/jira-sdlc-tools.git jira-sdlc-tools-lab
claude --plugin-dir ./jira-sdlc-tools-lab/plugins/jira-sdlc
```

Already have a clone you'd rather reuse? `git switch lab` in it and
re-run the same `--plugin-dir` command.

## Configuration

Identical to the main channel — the same two env files, unchanged. See
[README.md → Either way](README.md#either-way).

**One lab-only setup step — `sync_conversations`' transcript-folder paths.**
The `jira-task-helper` `sync_conversations` builtin attaches an issue's Claude
Code transcripts (`.jsonl` under `~/.claude/projects`) to its Jira issue. It reads
two values from `jira-sdlc-tools.local.env`, set once per machine:

- `CONVERSATIONS_MAINREPO_PATH` — the main checkout's transcript folder, used as-is
- `CONVERSATIONS_WORKTREES_PREFIX` — the prefix shared by every worktree's
  transcript folder; the script appends `worktree-<KEY>` to it per issue

Setting a fixed prefix — rather than letting the tool compute paths — is what
scopes the builtin to your own main checkout + worktrees tree, and nothing else
under `~/.claude/projects`. Both are described in
[project-config.md](plugins/jira-sdlc/skills/_shared/project-config.md); the
builtin exits 1 if either is missing or the issue's resolved
`<prefix>worktree-<KEY>` folder doesn't exist. Only needed if you use
`sync_conversations`.

## Before you switch

The extras are the reason to think about it first: they aren't
release-gated, and they reach wider than the core three do — into your
whole workspace rather than a single issue's worktree, with the scripts
and permissions to match. Run lab where you're comfortable with that.
