# AGENTS.md

This repo is a private Claude Code plugin **marketplace** that ships one
plugin, `jira-sdlc` — three coupled skills (`jira-task-assigner`,
`jira-task-executor`, `jira-task-reviewer`) that plan a feature into Jira
issues + git worktrees, implement each piece in parallel, and then
review the set. Full explanation, architecture diagram, and usage
walkthrough live in [README.md](plugins/jira-sdlc/README.md) — this file
is deliberately shorter and only covers what's easy to get wrong.

## The one rule that matters most

Every project-specific value (Jira project key, worktrees path, test
commands, workflow status names) is a `<TOKEN>`
resolved from `jira-sdlc-tools.env` in the project root
(see `plugins/jira-sdlc/skills/_shared/project-config.md` for a description of
each variable) — never a literal.
**Never hardcode a real project's value into a skill file.** If you're
about to type an actual Jira key, a real path, or a specific framework
name into a `SKILL.md` body, it belongs in `jira-sdlc-tools.env`'s example
table instead, referenced through a token. This repo's entire value is
being reusable across projects; a hardcoded literal quietly breaks that
for the next person who installs it.

## Editing a skill — keep it small but effective

The three `SKILL.md` files under `plugins/jira-sdlc/skills/` are prompts
an LLM re-reads on every run, so every line costs context and adds a
place to misread. The guidelines below are working hypotheses — each
helps in a specific way and has a known failure mode; the full
reasoning, caveats, and how we plan to test them live in
[docs/skill-development-considerations.md](plugins/jira-sdlc/docs/skill-development-considerations.md).

- **If it fits in one line, prefer one line.** The payoff is
  reliability, not tokens: instructions buried mid-file get skipped or
  half-applied. Caveat: over-terse is worse than over-long — cut
  redundancy and hedging, keep the "why" on load-bearing rules. If a
  rule won't compress, it's probably not crisp yet; fix the rule first.
- **If it can be scripted, consider scripting it.** Deterministic
  sequences belong in `skills/_shared/scripts/posix/`, with the SKILL.md
  reduced to "run X, act on its output" — a script collapses N model
  round trips into one bash call and runs identically every time,
  where prose re-derivation is slower and each run is a fresh chance
  to glitch. `statuscheck.sh` is the pattern to copy. Caveat: scripts
  fail differently, not less — a script bug is wrong 100% of the time
  and rots silently in a repo with no tests. Script the stable
  deterministic parts; leave judgment and error recovery to the model.
- **Pseudo-code over prose — for closed decision spaces.** When every
  case the model will meet is one of the enumerated branches, a
  decision table or numbered if/else misparses less than paragraphs.
  Caveat: when reality can land outside the listed branches, rigid
  structure makes the model force-fit the nearest branch instead of
  reasoning — there, a sentence of "prefer X because Y" generalizes
  better.
- **Explain why over stacking MUSTs.** ALL-CAPS ALWAYS/NEVER is a
  yellow flag; one clause of reasoning generalizes better than a bare
  imperative.
- **Stay under ~500 lines per SKILL.md.** Detail not needed on every
  run goes to `skills/_shared/*.md` reference files, loaded only when
  the skill says to — the progressive-disclosure layering these skills
  already use.

For any non-trivial skill change (new skill, restructure, description
rewrite), use the **skill-creator** skill
(https://claude.com/plugins/skill-creator; github copy of its guide:
[https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md](https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md)) instead of
freehanding — it covers drafting, eval loops, and when to bundle
scripts. One caveat: skip its description-optimization advice ("make
descriptions pushy" for auto-triggering) — all three skills set
`disable-model-invocation: true`, so descriptions here are
documentation for humans browsing `/plugin`, not trigger bait.

## Structural constraints — easy to break while "tidying up"

This repo is a **marketplace**, so there are *two* `.claude-plugin/`
directories — one at the marketplace root, one inside the plugin — and
each holds a single manifest. Don't merge them into one.

- **Marketplace root** (this repo's root) ships
  `.claude-plugin/marketplace.json`. Its plugin entry's `source` is a
  path relative to the marketplace root (here `"./plugins/jira-sdlc"`),
  *not* relative to `.claude-plugin/` itself — Claude Code resolves it
  against the directory that contains `.claude-plugin/`.
- **Plugin root** (`plugins/jira-sdlc/`) ships
  `.claude-plugin/plugin.json`, and that's the only file allowed in it.
  `skills/` and `docs/` live at the plugin root, as siblings of
  `.claude-plugin/`, never nested inside it.
- `skills/_shared/` must stay **inside** `skills/` (which is inside the
  plugin root). A marketplace install only copies the plugin's own root
  directory into its cache — anything reached by a relative path that
  climbs above the plugin root (e.g. splitting this into three separate
  plugins that each reach for an external `_shared/` across a `../`
  boundary) silently stops resolving after install. Don't move it up a
  level.
- Each `SKILL.md`'s `name:` frontmatter should match its folder name.

## If you rename a skill or the plugin

Renames aren't self-contained here — grep for the old name before
assuming you're done:
- Renaming the **plugin** (`name` in
  `plugins/jira-sdlc/.claude-plugin/plugin.json`, which is also the
  skill namespace in `/jira-sdlc:...`) → rename the directory under
  `plugins/`, update that entry's `name` and `source` in
  `.claude-plugin/marketplace.json`, *and* update the self-referential
  slash-command mentions hardcoded inside
  `jira-task-assigner` (its step 1 Discovery & healthcheck
  `STATUSCHECK_RERUN` override, and step 8), `jira-task-executor`
  (step 11 and its Discovery & healthcheck section), `jira-task-reviewer`
  (its own Discovery & healthcheck section's `STATUSCHECK_RERUN`
  override, plus steps 4a/4b/4c and 6), and the healthcheck script's
  rerun remedies (`skills/_shared/scripts/posix/statuscheck.sh`), which
  currently read `/jira-sdlc:...`.
- Renaming a **skill** → `jira-task-assigner` step 8 currently refers to
  `jira-task-executor` by name; check the other two skills and the
  README for any new cross-references before assuming a rename is
  isolated to one file.

## Validating a change

There's no build, and no test suite for the skills themselves — this repo
is mostly prompt files for an LLM agent plus two JSON manifests (one per
`.claude-plugin/` directory). The one exception is the conversation-debugger's
executable scripts, which do have golden-file harnesses (see below).
Instead:

```bash
# canonical structural validation — checks marketplace.json schema,
# source path traversal, and each plugin's plugin.json in one pass
claude plugin validate .

# manifests are well-formed JSON (fallback if the claude CLI is unavailable)
python3 -m json.tool .claude-plugin/marketplace.json > /dev/null
python3 -m json.tool plugins/jira-sdlc/.claude-plugin/plugin.json > /dev/null
```

### Touched a conversation-debugger script? Run its golden harness

The `conversation-debugger` scripts are real programs, not prompts, so they
get real tests: `plugins/jira-sdlc/skills/conversation-debugger/scripts/tests/`
holds a golden-file harness per refactored script, each replaying captured
fixtures through stub siblings and byte-diffing the normalized JSON against a
committed golden.

```bash
cd plugins/jira-sdlc/skills/conversation-debugger/scripts
bash tests/run_collect_feature_golden.sh        # every engine: sh shim, py core, ps1 port
bash tests/run_collect_feature_golden.sh py     # or one engine
```

The `ps1` engine needs `pwsh` (7 on Linux is enough) and skips with a loud note
otherwise — a green run that skipped it has **not** verified the Windows port.
`--update` re-captures the goldens; use it only when an output change is
intended, so the golden diff in that commit documents the change.
`skills/conversation-debugger/scripts/tests/README.md` explains the staging
model and how to add a scenario or a harness for another script.

### Touched a mermaid diagram? Render it — don't eyeball it

The lifecycle diagrams (`plugins/jira-sdlc/docs/TASK-LIFECYCLE-PHASE-*.md`,
plus the plugin README) are the one thing here a machine can actually check,
and they fail in a way that is **invisible in review**: a broken block still
looks like a perfectly reasonable diagram in the diff, and only turns into an
error box once GitHub renders it. So parse it with a real parser:

```bash
bash scripts/check-mermaid.sh                      # every ```mermaid block in the repo
bash scripts/check-mermaid.sh path/to/changed.md   # or just the file you touched
```

It parses each block with the real mermaid parser (`npx @mermaid-js/mermaid-cli`
— needs Node, and network on first run), exits non-zero, and names the offending
file and block.

**No Node / offline?** It falls back automatically — or force it with
`--lint`:

```bash
bash scripts/check-mermaid.sh --lint               # pure bash/grep, no deps, ~0.2s
```

Lint mode catches the three things that actually break these diagrams (the
semicolon below, an `alt`/`loop`/`opt`/`par` with no matching `end`, and a
missing `sequenceDiagram`/`flowchart` line) — but it **cannot prove a diagram is
valid**, only that it has no *known* trap. So when you lint, also look at the
thing: paste the block into <https://mermaid.live>, or open the file on GitHub,
which renders it. The script says so on every run rather than letting a green
line imply more than it means.

⚠️ **The trap that bites: `;` is a statement separator in mermaid.** A
semicolon anywhere in message text silently truncates the line and breaks the
whole diagram — and the parser's complaint points at the token *after* the
semicolon, so the error message actively misdirects you. Write `—` or `·`
instead:

```
A->>B: resolve the email (executor identity; none configured → stop)   # BREAKS
A->>B: resolve the email (executor identity — none configured → stop)  # fine
```

Everything else you might suspect is **fine** inside message text — angle-bracket
tokens (`<KEY>`), em-dashes, `→`, colons, commas, `#`, backticks, pipes, braces,
unmatched parens, and participants used without being declared (mermaid
auto-creates those). All confirmed against the parser. Don't rewrite them chasing
an error; the semicolon is the one that bites, and the checker will point at it.

### Touched a `_shared/scripts/posix/*.sh`? Its `win/*.ps1` twin must stay in sync

The five skill-invoked scripts (`statuscheck`, `ensure_local_env`,
`jira_acli_login`, `get_assignee_email`, `check_assignee`) ship **twice**: the
bash original in `_shared/scripts/posix/` (the POSIX path) and a PowerShell 5.1+ port in
`_shared/scripts/win/` (the Windows path). They're a contract pair — same
arguments, same markdown-table / stdout, same exit codes and stderr — so the
skills need only one dispatch rule (`bash …/X.sh` on POSIX,
`pwsh`/`powershell …/win/X.ps1` on Windows). Each skill picks the branch up
front from its own runtime, *before* the first script runs — statuscheck is
itself one of the dispatched scripts, so it can't be what decides how to run
it. Edit one port and
you must edit the other, or Windows silently drifts. `statuscheck`'s `platform`
row then *confirms* the OS and the Windows runtime/ports, and honors
`STATUSCHECK_FORCE_OS` so the Windows branch is testable on Linux. Re-verify parity after any change — pwsh 7 runs on Linux, so
diff each port against its bash twin with the OS forced:

```bash
export STATUSCHECK_FORCE_OS=windows
for s in statuscheck ensure_local_env jira_acli_login get_assignee_email check_assignee; do
  diff <(bash "plugins/jira-sdlc/skills/_shared/scripts/posix/$s.sh") \
       <(pwsh -NoProfile -File "plugins/jira-sdlc/skills/_shared/scripts/win/$s.ps1") \
    && echo "✓ $s identical"
done   # pass a role arg to jira_acli_login; an issue-key arg to check_assignee
```

Residual Windows-only surface Linux+pwsh can't reproduce (small, and out of the
diff's reach): real backslash paths / drive letters, CRLF, and acli's config
location — confirm those on a real Windows 11 box, but the port logic and
dispatch are verified here.

Beyond that, "testing" a skill means tracing through which assignment
scenario (single-step vs. multistep, parent vs. sub-task), which review
dimension, or which track or re-run scenario your change touches (see README → Core
concepts), and re-reading that skill's logic end to end for the scenario
you changed. These files *are* the behavior, not a description of it —
there's no separate implementation to run against them.

## Releasing (tagging + GitHub Releases)

There's no deploy pipeline — for a plugin marketplace, a *release* is just a
SemVer git tag plus the GitHub Release that the marketplace install command
consumes. The version lives only in git tags (no `package.json`/`VERSION` file
to bump), which is what makes the workflow generic enough to lift into any
repo, not just the JS app these skills came from. The branching and release
policy is [docs/SDLC.md](plugins/jira-sdlc/docs/SDLC.md), and
[docs/CI.md](plugins/jira-sdlc/docs/CI.md) is the workflow-by-workflow CI
reference — including the tagging mechanics and the continuous `lab`
pre-release channel (`update_lab.yml`), which this section doesn't cover. Two
workflows automate the stable release:

- **`cut-release.yml`** — manual `workflow_dispatch`. Takes a bump level
  (`patch` / `minor` / `major`, default `minor`), computes the next SemVer
  from the latest `v*` tag + that level, cuts `release/sprint-<X.Y.Z>` from
  `development`, and opens a **draft** PR into `main`. The version lives in
  the branch name from here on. SDLC Phase 2.
- **`release.yml`** — on a PR merge into `main` whose head is `release/*` or
  `hotfix/*`. In order: resolves the version (from the `release/*` branch
  name, or a patch on the latest tag for `hotfix/*`) → tags `vX.Y.Z` on the
  merge commit → publishes the GitHub Release → back-merges `main` into
  `development` (opens a sync PR instead if it conflicts, never
  force-pushing) → deletes the `release/*`/`hotfix/*` branch. SDLC Phase 4 + §4.

Order of operations, the short version:
1. Run `cut-release` → `release/sprint-<X.Y.Z>` and a draft PR appear
   (version computed from latest `v*` tag + chosen bump level, default `minor`,
   baked into the branch name).
2. QA on that branch; fix PRs land back into `release/sprint-<X.Y.Z>` (SDLC Phase 3).
3. Mark the draft PR ready and merge it into `main`.
4. `release.yml` tags, releases, syncs back to `development`, and deletes the
   branch automatically.

Bump resolution (SDLC §5): `release/*` takes its version from the branch name
(`release/sprint-<X.Y.Z>` — malformed names fail the release; rename or
re-cut to change the version), and `hotfix/*` is always a **patch** on the
latest `v*` tag. No PR label is read for versioning. Tags are pure SemVer, no
sprint suffix. The first release (no `v*` tag exists) is `v0.1.0`. A
`hotfix/*` merge runs the same tag→release→sync-back→cleanup steps with a
patch bump.

Auth: the default `GITHUB_TOKEN` suffices while `main`/`development` are
unprotected (the workflows push tags, delete branches, create releases, and
push the back-merge with it). If you enable branch protection on `main`, or
want the back-merge commit to re-trigger the `validator` workflow, define a
`RELEASE_PAT` secret and swap the `GH_TOKEN`/remote in `release.yml`'s
back-merge step.
