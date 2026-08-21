# AGENTS.md

This repo is a private Claude Code plugin **marketplace** that ships one
plugin, `jira-sdlc` — three coupled skills (`jira-task-assigner`,
`jira-task-executor`, `jira-task-reviewer`) that plan a feature into Jira
issues + git worktrees, implement each piece in parallel, and then
review the set, plus `jst-install`, which sets a project up for them and
is not part of that lifecycle. Full explanation, architecture diagram, and
usage walkthrough live in [README.md](plugins/jira-sdlc/README.md) — this file
is deliberately shorter and only covers what's easy to get wrong.

## The one rule that matters most

Every project-specific value (Jira project key, worktrees path, test
commands, workflow status names) is a `<TOKEN>`
resolved from `.jst/jira-sdlc-tools.env` in the project root
(see `plugins/jira-sdlc/skills/_shared/project-config.md` for a description of
each variable) — never a literal.
**Never hardcode a real project's value into a skill file.** If you're
about to type an actual Jira key, a real path, or a specific framework
name into a `SKILL.md` body, it belongs in `.jst/jira-sdlc-tools.env`'s example
table instead, referenced through a token. This repo's entire value is
being reusable across projects; a hardcoded literal quietly breaks that
for the next person who installs it.

## Editing a skill — keep it small but effective

The three `SKILL.md` files under `plugins/jira-sdlc/skills/` are prompts
an LLM re-reads on every run, so every line costs context and adds a
place to misread. The guidelines below are working hypotheses — each
helps in a specific way and has a known failure mode; the full
reasoning, caveats, and how we plan to test them live in
[docs/skill-development-considerations.md](docs/skill-development-considerations.md).

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
- **Stay under ~5,000 words per SKILL.md — hard ceiling 6,500.** Run
  `bash scripts/check-skill-size.sh` rather than counting by hand. Over
  budget, the fix is progressive disclosure, not deletion: detail not
  needed on every run moves to `skills/_shared/*.md`, loaded only when
  the skill says to. Counted in **words, not the ~500 *lines* this rule
  used to say**, because line count isn't stable under reformatting and
  so kept failing the wrong files — JST-230's rewrap took
  `jira-task-reviewer` 415 → 714 lines while its word count moved by
  *five*, and the long lines it replaced had hidden a real overage for
  years. ~5,000 words is roughly the old ~500 lines at this repo's wrap
  width. `jira-task-reviewer` is a recorded exception at ~6,100 — it is
  the only skill carrying two tracks plus a phase machine, and no
  realistic trim clears the target — so it reports `WARN (accepted)`.
  An exception is a number, not a pass: exceed it and the plain WARN
  comes back, and if the file shrinks the script tells you to ratchet the
  allowance down. Add one only when the alternative is a warning nobody
  can act on, since a permanent warning teaches people to ignore the
  checker — and say why here, not just in `accepted_budget()`.

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
  `skills/` lives at the plugin root, as a sibling of `.claude-plugin/`,
  never nested inside it.
- **`docs/` is at the *repo* root, not inside the plugin** (JST-287), because
  it is the source of a Docusaurus site whose versioning snapshots the docs
  root and nothing else. The consequence bites in one specific place: a
  marketplace install copies only `plugins/jira-sdlc/` into Claude Code's
  cache, so **an installed user has no `docs/` at all**. Anything inside the
  plugin that names a doc is therefore a dangling pointer if you write it as a
  path — see *The published docs URL scheme* below for which form to use where.
- `skills/_shared/` must stay **inside** `skills/` (which is inside the
  plugin root). A marketplace install only copies the plugin's own root
  directory into its cache — anything reached by a relative path that
  climbs above the plugin root (e.g. splitting this into three separate
  plugins that each reach for an external `_shared/` across a `../`
  boundary) silently stops resolving after install. Don't move it up a
  level.
- Each `SKILL.md`'s `name:` frontmatter should match its folder name.
- `skills/_shared/templates/jira-sdlc-tools.local.env.example` is a **copy** of
  the repo-root `.jst/jira-sdlc-tools.local.env.example`, and the two must stay
  identical — `jst-install` copies the plugin-side one into a new project, and
  a path climbing to the repo root wouldn't survive either install mode. Edit
  one, `diff` the other. (`.jst/…` is also this repo's own live config
  template, which is why the duplication exists rather than a move.)

## The published docs URL scheme

`docs/**` is published to
`https://kantorv.github.io/jira-sdlc-tools/docs/<slug>`, and
`scripts/docs-url-map.json` is the single source of truth for every slug. Two
things about it are load-bearing:

- **Slugs are flat and decoupled from the directory tree.** `docs/github/GH-PAT-SESSION-LOGIN.md`
  is `/gh-pat-session-login`, not `/github/gh-pat-session-login`; the run
  reports keep their UUID filenames but publish as `/examples/executor-run-report`.
  The cost is one `slug:` line per page. The payoff is that the sidebar grouping
  stays an editorial decision you can revise later without breaking a URL — and
  some of these URLs ship *inside the plugin*, into caches nobody can correct
  retroactively. **Never change a slug that has shipped.**
- **`site_docs_base` in that file is a contract with `website/docusaurus.config.js`**
  (`url` + `baseUrl` + the docs plugin's `routeBasePath`). Change one of the
  three and every baked-in URL 404s, silently.
- **A page that moves, splits or merges leaves its slug behind in `redirects`.**
  Docusaurus takes one slug per page, so when a shipped URL's page stops
  existing under that name, the slug moves from `pages` to the `redirects` list
  with the `to` slug that now serves it —
  `@docusaurus/plugin-client-redirects` emits the redirect, and
  `docusaurus.config.js` builds its list by *reading* this file so the two
  cannot drift. That is what makes "never change a shipped slug" survivable
  when the page behind it genuinely has to move (JST-296 did this to
  `/step-by-step`). Two consequences worth knowing before you rely on it: the
  build's broken-link checker does **not** count a redirect as a route, so an
  in-site link to a redirected slug still fails the build — point site-internal
  links at the live slug and leave the redirect for the URLs already in the
  wild; and only `current` is redirected, since each versioned snapshot still
  carries the page under its own `/docs/<X.Y.Z>/…` route.

Which form a reference takes depends on who reads it, not on where it lives:

| where the reference is | form | why |
| -- | -- | -- |
| between two files under `docs/` | relative (`../SDLC.md`) | works on the site *and* when read on GitHub, and survives `docs:version` |
| a published doc → anything outside `docs/` | absolute `github.com/.../blob/main/…` | there is no site route; Docusaurus emits it unchanged and warns nobody |
| `README.md`, `INTEGRATIONS.md` | absolute | rendered by GitHub against its own domain, and fed to the site from outside the docs root |
| anything under `plugins/jira-sdlc/` a user reads without a checkout — the plugin README, `SKILL.md` bodies, script *header* comments, strings printed to a terminal, the `.env.example` templates | published site URL | after a marketplace install the path simply isn't there |
| code comments read while *editing* a script in a checkout | repo-relative (`docs/SDLC.md`) | the reader has the repo in front of them; a URL is noise |
| any asset a published doc references relatively | must live under `docs/` | `docs:version` snapshots the docs root and nothing else, so a path reaching outside it means something different inside the snapshot |

The root README's three GIFs (8.4 MB) are the deliberate exception to that last
row: they stay in the repo-root `assets/` and the README names them by absolute
`raw.githubusercontent.com` URL, because README is not under the docs root and
copying 8.4 MB into every future version snapshot is a permanent cost for
nothing. `docs/assets/` (the four phase diagrams plus one PNG, ~500 KB) does
move with the docs and is referenced relatively.

Files under `docs/` whose name starts with `_` are **not published** —
Docusaurus treats them as partials, so `docs/integrations/_TEMPLATE.md` is a
contributor template and links to it are absolute like any other unpublished
file. `scripts/docs-url-map.json` lists them under `unpublished`.

`scripts/repair-doc-links.py` applies all of the above mechanically and is
idempotent; run it after moving or renaming a doc rather than hand-editing
links, then verify with `scripts/check-doc-links.sh` (below).

## If you rename a skill or the plugin

Renames aren't self-contained here — grep for the old name before
assuming you're done:

- Renaming the **plugin** (`name` in
  `plugins/jira-sdlc/.claude-plugin/plugin.json`, which is also the
  skill namespace in `/jira-sdlc:...`) → rename the directory under
  `plugins/`, update that entry's `name` and `source` in
  `.claude-plugin/marketplace.json`, *and* update every hardcoded
  self-referential slash-command mention. **Enumerate those with
  `grep -rn '/jira-sdlc:' . --exclude-dir=.git --exclude-dir=website --exclude-dir=node_modules`
  rather than working from the list below** — they move between files as the
  skills are refactored, and a hand-maintained list is exactly what goes
  stale (this one did: the reviewer's re-run wording left its SKILL.md steps
  for the shared template in JST-293). That grep reaches ~124 occurrences
  across the plugin, `docs/`, the root prose and the
  `.github/workflows/demo-*.yml` runners — all of which break on a rename.
  It excludes `website/`, whose `versioned_docs/` are published snapshots of
  older releases: those name the plugin as it *was* and must keep doing so.
  It does **not** exclude `docs/examples/reports/`, so four of those hits are
  transcripts of runs that really happened under the old name — leave them
  alone for the same reason, and don't read them as work the rename missed.
  Inside the plugin itself, at the time of
  writing, they are: `jira-task-assigner` (its
  step 1 Discovery & healthcheck `STATUSCHECK_RERUN` override, and step 8),
  `jira-task-executor` (step 11), `jira-task-reviewer` (its Discovery &
  healthcheck `STATUSCHECK_RERUN` override — and *only* that),
  `skills/_shared/templates/review-report.md` (six, in the outcome
  catalogue's `Next step` blocks, which is where the reviewer's re-run
  instructions actually live), `jst-install` (its `STATUSCHECK_RERUN`
  overrides in the *Verification* section and step 4a, the remedy-default
  note, the three hand-off commands in 4c, and the retroactive-assignment
  example), and the healthcheck script's rerun remedies in **both** ports —
  `skills/_shared/scripts/posix/statuscheck.sh` *and*
  `skills/_shared/scripts/win/statuscheck.ps1`.
- Renaming a **skill** → `jira-task-assigner` step 8 currently refers to
  `jira-task-executor` by name; check the other two skills and the
  README for any new cross-references before assuming a rename is
  isolated to one file.

## Validating a change

There's no build or test suite — this repo is prompt files for an LLM
agent plus two JSON manifests (one per `.claude-plugin/` directory).
Instead:

```bash
# canonical structural validation — checks marketplace.json schema,
# source path traversal, and each plugin's plugin.json in one pass
claude plugin validate .

# skill size budget — words, not lines (see "Stay under ~5,000 words" above);
# exits non-zero only over the hard ceiling
bash scripts/check-skill-size.sh

# manifests are well-formed JSON (fallback if the claude CLI is unavailable)
python3 -m json.tool .claude-plugin/marketplace.json > /dev/null
python3 -m json.tool plugins/jira-sdlc/.claude-plugin/plugin.json > /dev/null

# markdown canonicalization — exit 1 if any tracked .md is non-canonical
cedit md canonicalize --check <file>.md  # .md files only

# workflows/other .yml files — exit 1 on lint failure
actionlint path/to/<file>.yml         # .yml files only

# every doc reference still resolves — the four link categories, checked
# against this checkout, no network (see "Touched a doc reference?" below)
bash scripts/check-doc-links.sh
```

### Touched a mermaid diagram? Render it — don't eyeball it

The lifecycle diagrams (`docs/TASK-LIFECYCLE-PHASE-*.md`,
plus the plugin README) are the one thing here a machine can actually check,
and they fail in a way that is **invisible in review**: a broken block still
looks like a perfectly reasonable diagram in the diff, and only turns into an
error box once GitHub renders it. So parse it with a real parser:

````bash
bash scripts/check-mermaid.sh                      # every ```mermaid block in the repo
bash scripts/check-mermaid.sh path/to/changed.md   # or just the file you touched
````

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

The six skill-invoked scripts (`statuscheck`, `ensure_local_env`,
`get_assignee_email`, `check_assignee`, `jira`, `pr_base`) ship **twice**: the
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
for s in statuscheck ensure_local_env get_assignee_email check_assignee jira pr_base; do
  diff <(bash "plugins/jira-sdlc/skills/_shared/scripts/posix/$s.sh") \
       <(pwsh -NoProfile -File "plugins/jira-sdlc/skills/_shared/scripts/win/$s.ps1") \
    && echo "✓ $s identical"
done   # add the args each one needs: --role <role> to statuscheck; --role <role>
       # plus an issue key to check_assignee; --role <role> and a subcommand
       # (e.g. whoami) to jira; --role <role> plus --parent-key <KEY> to
       # pr_base. All four now REQUIRE --role — auth is role-scoped, with no
       # default credential.
```

`pr_base` is the one whose *result* depends on where you run it — it resolves
from four sources in order, and a worktree with `parentbranch` set stops at the
first, so a single diff exercises one branch out of five. Drive the rest from a
throwaway worktree with no `parentbranch` (`git worktree add … -b probe/<KEY>-x`,
then run `ensure_local_env` in it or the Jira-comment source can't be reached),
varying `--parent-key` and the issue key to reach `jira-comment`,
`branch-search`, `env-default` and `unresolved`. Compare stdout, stderr **and**
exit code (0 / 1 / 2) on each — the exit code is half this script's contract.
Cover `--branch <name>` too (both the spaced and `--branch=` forms): it swaps
the branch every source keys on, so a port that ignored it would still look
right on every other case.

**Two rows of `statuscheck`'s diff are Linux-under-pwsh noise, not drift** —
knowing this up front saves chasing a port bug that isn't there:
`$env:TEMP` is unset on Linux, so export `TEMP=/tmp` before the diff, and
`gh_auth` still FAILs on the PowerShell side afterwards (`gh auth login --with-token` doesn't complete down that path) while the bash side reads OK.
Filter `gh_auth` out and compare the rest; confirm that one row on Windows.
Filtering the *row* isn't quite enough — a FAIL also prints a "Remedies for
FAIL rows" footer under the table, so drop that block too or the diff shows
three phantom lines. `gh_repo_access` skips itself when `gh_auth` failed, so it
inherits the same noise and needs the same filter:

```bash
filt() { grep -vE '^\| (gh_auth|gh_repo_access)' | sed '/^Remedies for FAIL rows/,$d'; }
```

**Or drop the filter entirely and exercise the real path** (JST-251): the only
thing missing on Linux is `cmd`, which `statuscheck.ps1` shells out to for the
stdin redirect. A three-line `cmd` stand-in on `PATH` — `[ "$1" = "/c" ] && shift; exec bash -c "$*"` — makes the pwsh login succeed, and both ports then
print byte-identical tables with nothing filtered. Pair it with a fake `gh` on
`PATH` to drive the branches a live run can't reach (`gh_repo_access`'s 404 and
non-404 errors, a missing/non-GitHub `origin`).

Residual Windows-only surface Linux+pwsh can't reproduce (small, and out of the
diff's reach): real backslash paths / drive letters and CRLF — confirm those on
a real Windows 11 box, but the port logic and
dispatch are verified here.

### Touched a Markdown file? Canonicalize it — the gate checks

This repo gates Markdown on change via the **markdown-canonicalize.yml**
workflow (added by JST-281 under `.github/workflows/`). It runs
`cedit md canonicalize --check` on every changed `**/*.md` and fails the job
if any file is non-canonical. Stateless only: `cedit md canonicalize`
operates on the file content alone, with no `.cedit/` snapshot/sync/state.

Before pushing Markdown changes, canonicalize locally:

```bash
cedit md canonicalize -i <file>         # rewrite in place
cedit md canonicalize --check <file>    # CI-equivalent gate (exit 1 = not canonical)
```

The workflow filename is `markdown-canonicalize.yml` — if it changes, update
this reference.

### Touched a doc reference? `check-doc-links.sh` is the only thing that sees it

Links are the one thing here with no test coverage and the worst failure mode:
they break silently and stay broken. The Docusaurus build catches exactly one
of the four categories in *The published docs URL scheme* above — relative
`.md` links between published docs — and is structurally blind to the other
three. An absolute `blob/main/` URL to a file you just moved is still absolute,
still parses, and now 404s.

```bash
bash scripts/check-doc-links.sh   # exit 1 naming every file:line that broke
```

It asserts each reference against **this checkout** rather than the network, so
it passes on a branch before the paths exist on `main`, and it needs no
credentials. `.github/workflows/` and `website/` are excluded — those are owned
elsewhere.

Moving or renaming a doc? Don't hand-edit the links. Add or change the entry in
`scripts/docs-url-map.json`, then:

```bash
python3 scripts/repair-doc-links.py           # rewrite every category, idempotent
python3 scripts/repair-doc-links.py --check   # exit 1 if anything is stale
bash scripts/check-doc-links.sh
```

⚠️ **The trap that bites here:** a relative link is written against the
directory the file was in *when someone typed it*. Move the file and every
`../../…` in it silently means something else — usually a path that walks off
the top of the repo, but sometimes a same-named file at the new depth
(`../README.md` meant the *plugin* README, and resolved to the root one). The
repair script handles this by resolving against the origin path; if you do it
by hand, resolve from where the link was written, not from where the file now
sits.

### Touched a `.github/workflows/*.yml` file? Lint it with actionlint

YAML that parses fine can still fail GitHub's own schema/expression check —
e.g. a `${{ }}` with nothing inside it, even sitting inside a shell comment
inside a `run:` block, fails the whole workflow with a cryptic "An expression
was expected" pointing at an unrelated line. `actionlint` catches this and
other expression/shell/schema mistakes before you push:

```bash
actionlint .github/workflows/<file>.yml   # one file
actionlint                                 # every workflow in the repo
```

`.jst/bootstrap.sh` installs `actionlint` into `venv/bin` (it's a Go binary,
not a PyPI package, so it's fetched via its own install script rather than
`pip install`) — it's on `PATH` once you `source venv/bin/activate`.

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
policy is [docs/SDLC.md](docs/SDLC.md), and
[docs/CI.md](docs/CI.md) is the workflow-by-workflow CI
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
