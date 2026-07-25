# Codex CLI Integration (Agent Skills spec)

Uses the **Agent Skills** adaptation (agentskills.io), not the native Claude
skills spec. Codex discovers skills from a `.codex/skills/` tree at the
repository root — a hand-copied mirror of `plugins/jira-sdlc/skills/` plus
a per-skill `agents/openai.yml` that reproduces `disable-model-invocation:
true`. The tree is gitignored and maintained by manual copy; nothing
automates it.

> **Verified from a real Codex CLI run** (July 2026, `workspace-write`
> sandbox). Everything below is first-hand unless marked **Unverified**.

## Prerequisites

- Jira auth configured — per-request Basic auth from `.jst/jira-sdlc-tools.local.env`, no login step (see [jira-api-reference.md](../../skills/_shared/jira-api-reference.md) §9)
- `gh` (GitHub CLI) authenticated
- `.jst/jira-sdlc-tools.env` and `.jst/jira-sdlc-tools.local.env` in your **project** root — see [project-config.md](../../skills/_shared/project-config.md)
- `.codex/config.toml` at the repo root with network access enabled (see
  **Sandboxing** in the caveats section below — without it, every `jira.sh`
  call fails when it shells out to `curl`)

## Install / Wire-up Steps

### 1. Create the `.codex/skills/` tree

Copy the plugin's skill source into Codex's discovery path. The source is
`plugins/jira-sdlc/skills/` (the directory that ships the three `SKILL.md`
files plus `_shared/`); the target is `.codex/skills/` at the repository
root:

```bash
# from the repository root
mkdir -p .codex/skills
cp -a plugins/jira-sdlc/skills/* .codex/skills/
```

`cp -a` preserves the executable bit on the shared scripts (see **chmod**
below). If you use a plain `cp -r` or a file manager, the `.sh` scripts
under `.codex/skills/_shared/scripts/` can land non-executable and the
skills will fail at their first `bash …/statuscheck.sh` call.

### 2. Add `agents/openai.yml` to each skill

This file is **not** part of the Claude plugin source — it is the Codex
adaptation that reproduces `disable-model-invocation: true`. Create one in
each of the three skill directories:

```bash
for skill in jira-task-assigner jira-task-executor jira-task-reviewer; do
  mkdir -p ".codex/skills/$skill/agents"
  cat > ".codex/skills/$skill/agents/openai.yml" <<'EOF'
policy:
  allow_implicit_invocation: false
EOF
done
```

### 3. Make the shared scripts executable

```bash
chmod +x .codex/skills/_shared/scripts/*.sh .codex/skills/_shared/scripts/*.py
```

`cp -a` preserves the mode, but a sync from a tarball, a Windows checkout,
or a non-preserving copy can strip the bit — run this after every copy to
be safe. **This was checked during the verification run** — the scripts in
`.codex/skills/_shared/scripts/` were `-rwxrwxr-x`.

### 4. Add `.codex/config.toml`

Codex's Jira workflow shells out to `jira.sh`, which in turn calls `curl` —
both need outbound HTTPS to the Atlassian site. In the default
`workspace-write` sandbox, network is blocked unless you opt in:

```toml
# .codex/config.toml
sandbox_mode = "workspace-write"

[sandbox_workspace_write]
network_access = true
```

> **⚠️ Needs re-verification under the REST client.** The gap verified here
> was specific to the old Atlassian CLI's `jira auth login` step — a step
> that no longer exists:
> `jira.sh`/`jira.ps1` authenticate per-request from
> `.jst/jira-sdlc-tools.local.env`, with nothing to log into first. Whether a
> bare `jira.sh` network call (e.g. `statuscheck.sh`'s own `jira whoami`)
> succeeds in a session that just picked up this config, or still needs a
> fresh session, has not been re-tested against the REST client. Until it
> is, treat Codex's **escalated execution**
> (`sandbox_permissions: "require_escalated"`) as the safe default for any
> `jira.sh`/`jira.ps1` or script call that reaches the network. See
> **Sandboxing** in the caveats.

### 5. Gitignore the tree

`.codex/` is **not committed**. A `.codex/.gitignore` with a single `*`
keeps the whole tree out of git (matching the `.agent/` pattern used for the
agentskills.io spec):

```bash
echo '*' > .codex/.gitignore
```

The tree is deliberately a local working copy, not a synced artifact. There
is no sync script (decided in the parent issue — docs-only, manual copy).

## Invoking the Three Skills

Codex triggers skills with the `$<skill-name>` syntax (the dollar sign, not
the `/` slash Claude Code uses). All three skills set
`allow_implicit_invocation: false` (via `agents/openai.yml`), so Codex
will **not** auto-load them from ambient context — you invoke them
explicitly:

- `$jira-task-assigner` — break down a task into Jira issues with branches + worktrees
- `$jira-task-executor` — implement an issue end-to-end from its worktree
- `$jira-task-reviewer` — review sub-task PRs from the parent issue's worktree

**Verified:** this very doc was written by a `$jira-task-executor` run —
Codex loaded the skill from `.codex/skills/jira-task-executor/SKILL.md` and
executed it step by step.

The skill bodies still contain `/jira-sdlc:…` cross-references (the Claude
Code slash-command form). Under Codex these are **instructions to the model
to re-run a skill**, not parseable triggers — read them as "invoke
`$<skill-name>`" (e.g. `$jira-task-executor`). They are not auto-rewritten
by the copy; the model interprets them.

## Platform-Specific Caveats

### Sandboxing / approval policy

This is the main reason Codex gets its own file (the sibling Antigravity
doc covers the rest of mechanism B without these rules).

The skills shell out to `gh`, `git`, `bash`, and `jira.sh` (which itself
calls `curl`). In Codex's default `workspace-write` sandbox:

- **Network (Jira):** blocked without `network_access = true`. Whether a
  bare `jira.sh` call succeeds inside the sandbox with just that setting is
  **unverified** against the REST client — the verification run predates
  the migration off the old Atlassian CLI, whose auth-login step used to
  fail here even with the config set. The reliable approach is
  **escalated execution**
  (`sandbox_permissions: "require_escalated"`) for any `jira.sh`/`jira.ps1`
  call or script that calls it. The skill's own preamble says: "if the
  sandbox blocks Jira, request scoped network-capable execution."
- **Git metadata (read-only FS):** git's worktree metadata (`.git/` in a
  linked worktree) lives outside the sandbox's writable root. Every git
  write operation — `git restore`, `git fetch`, `git merge`, `git add`,
  `git commit`, `git push` — fails with `fatal: … Read-only file system`.
  **Verified:** each of these needed escalated execution to proceed. This
  is not a Jira-specific allowlist; it is the sandbox's file-write boundary
  applied to the worktree's own `.git` directory.
- **Execution timeout:** Codex's Bash tool defaults to a short yield window.
  A `jira.sh`/`jira.ps1` call (or a `statuscheck.sh` run) that runs long
  will be reported as still running. Poll the session for output rather
  than treating the first chunk as a failure — and set a generous
  `yield_time_ms` / `timeout_ms` (the skill preamble recommends
  `timeout_ms: 300000`, i.e. 5 minutes). **Needs re-measurement:** the
  verification run timed the old Atlassian CLI's `jira auth login` and
  `jira workitem view` commands at ~20 s each, both appearing as running
  sessions that needed one or two polls — those figures were measured
  against that CLI and have not been re-timed against the equivalent
  `jira.sh` REST calls.
- **File-mode loss:** a plain copy (not `cp -a`) or a Windows checkout can
  strip the executable bit from `*.sh` / `*.py` under
  `.codex/skills/_shared/scripts/`. Run `chmod +x` after copying (step 3
  above). **Not directly observed failing** — the scripts were executable
  in the verification run — but the failure mode is real and silent.

### Drift — the copy is not synced

`.codex/skills/` is a **manual copy** of `plugins/jira-sdlc/skills/`. When
the plugin updates (a skill gains a step, a shared script changes), the
copied tree goes stale and the skills silently run the old version — there
is no sync script and no version pin. The recovery step is: re-run the copy
recipe from [Install](#install--wire-up-steps) above (steps 1–3), then
re-add the three `agents/openai.yml` files (step 2).

### `disable-model-invocation: true`

Reproduced via `agents/openai.yml` → `policy: allow_implicit_invocation:
false`. **Verified present** in all three skill dirs; its runtime effect
(longer context needed) was **not** directly tested. Mark as checked but
not confirmed until a second skill invocation shows the gating behaviour.

### What the `.codex/skills/` tree contains that the plugin source does not

`plugins/jira-sdlc/skills/` has the three `SKILL.md` files and `_shared/`
(reference `.md` files + scripts). `.codex/skills/` adds, per skill,
`agents/openai.yml`. One script — `statusboard.sh` — was present in the
`.codex/` tree but **not** in the tracked plugin source at verification
time; if you copy with `cp -a` and the plugin source doesn't have it yet,
the install still works (the skills only call `statuscheck.sh`).

### agentskills.io spec vs Codex runtime path

The parent issue describes the mechanism as "the `.agent/` manual copy"
(agentskills.io). In practice, Codex's discovery path is `.codex/skills/`,
not `.agent/skills/` — `.agent/` was the reference shape used during
investigation, but Codex does not pick it up. **Verified:** this run loaded
skills from `.codex/skills/`, and a Jira comment on this issue ("codex
need .codex folder, .agent seems not discoverable") records the same
finding. Use `.codex/skills/` as the target.
