---
name: conversation-debugger
description: Post-mortem a recorded run of one of the jira-sdlc skills. Give it a skill name (jira-task-assigner | jira-task-executor | jira-task-reviewer) and the path to a conversation .jsonl; it replays the transcript against the skill's prose, verdicts every instruction as followed / diverged / skipped / not-reached, mines the run for ad-hoc helper scripts worth keeping, and files a report plus a copy of the transcript under conversations/<issue-key>/.
disable-model-invocation: true
allowed-tools: Bash, Read, Grep, Glob, Write
---

You are debugging a **skill**, not the code it touched. The question is
never "was JST-nnn implemented well" — it is "did the agent do what
`SKILL.md` told it to, and where the two differ, which one is wrong: the
run, or the prose?" Both answers are findings: a run that ignored an
instruction is a compliance bug; an instruction every run has to work
around is a skill-text bug.

**Arguments** — `$ARGUMENTS` is `<skill-name> <conversation-path>`:

- `<skill-name>` — resolves to the prose file to analyze (paths
  relative to this skill's base directory):

  | `<skill-name>` | SKILL.md to read |
  |---|---|
  | `jira-task-assigner` | `../jira-task-assigner/SKILL.md` |
  | `jira-task-executor` | `../jira-task-executor/SKILL.md` |
  | `jira-task-reviewer` | `../jira-task-reviewer/SKILL.md` |

  Anything not in this table (including `jira-task-helper`) → stop and
  say the name isn't one of the three analyzable skills.
- `<conversation-path>` — a Claude Code session transcript (`.jsonl`),
  usually a live file under `~/.claude/projects/<flattened-cwd>/`, or an
  already-filed copy under `conversations/<issue-key>/`. The conversation
  uuid is the filename without `.jsonl`.

If one argument is missing, don't guess silently. A missing conversation
path is a hard stop. A missing skill name is recoverable — step 0's script
needs it, so recover it from the transcript's own invocation first:

```bash
grep -o '<command-name>/[^<]*</command-name>' <conversation-path> \
  | grep -oE 'jira-task-(assigner|executor|reviewer)' | head -1
```

— then pass what you found and say you inferred it. Don't just take the
*first* `<command-name>`: a session can open with `/model`, `/usage`,
`/context` or `/compact` before the skill is ever invoked, so match the
skill names themselves, as above. The match tolerates a bare
`/jira-task-executor` as well as a namespaced `/jira-sdlc:jira-task-executor`
— the command loses its prefix when the skills are installed as loose files
or the plugin was renamed. No match → the transcript isn't a run of an
analyzable skill; stop and say so.

**Output convention** — one directory per issue: the report and a copy of
the transcript both land in `conversations/<ISSUE-KEY>/` at the project
root, so an issue's runs accumulate in one place. Step 0's script does the
recovering, creating, and copying; you never `mkdir` or `cp` by hand.

## Step 0 — collect the run, then read the prose

Run this first. It validates the transcript, profiles it, recovers the
issue key, and — only if that key is trustworthy — creates
`conversations/<ISSUE-KEY>/` and copies the transcript in.

**Script dispatch.** This script ships twice, like the shared scripts do:
the POSIX `scripts/posix/collect_run.sh` (shells out to `jq`) and the
Windows twin `scripts/win/collect_run.ps1` (PowerShell 5.1+, native JSON
parsing — no `jq`, no bash). Read your OS from your own runtime before
this first call and dispatch accordingly; both take identical arguments
and print the identical `KEY=VALUE` block.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/conversation-debugger/scripts/posix/collect_run.sh" <skill-name> <conversation-path> [issue-key]
```

```powershell
pwsh "${CLAUDE_PLUGIN_ROOT}/skills/conversation-debugger/scripts/win/collect_run.ps1" <skill-name> <conversation-path> [issue-key]
```

(Outside a plugin session it lives at `scripts/posix/collect_run.sh` /
`scripts/win/collect_run.ps1` relative to this skill's directory.) Exit
`1` → hard error: relay its stderr and stop. Exit `2` → nothing was filed
and a human has to decide; see `KEY_STATUS` below. Never `mkdir`/`cp` by
hand to work around either.

It prints `KEY=VALUE` lines; the ones you act on:

| key | what to do with it |
|---|---|
| `KEY_STATUS` | `expected`/`given` → filed, carry on. `no-invocation`/`stub`/`unexpected` → **ask the user** (below). |
| `INVOCATIONS` | How many times `<skill-name>` was invoked in this session. `0` never files (see `no-invocation`). `>1` = the skill was re-run — step 2 must cover **every** segment, not just the first. |
| `IS_STUB=yes` | **Stop analyzing.** No assistant lines means the real work happened in another session (resumed elsewhere, or a partial sync). Write the short stub report instead: what the stub does show (invocation time, cwd, branch, args), plus a pointer to find the full session in `~/.claude/projects/` by cwd + timestamp. |
| `COMPACTED=yes` | The session was summarized mid-run — steps inside the summarized span are **can't-tell**, not skipped (see Caveats). |
| `REPORT_DIR` | Where step 6 writes the report. Already created. |
| `ISSUE_KEY` + `KEY_SOURCE` | The key the folder is named for, and the site it came from. |

**`KEY_STATUS=no-invocation` — wrong transcript, or wrong skill named.** The
script only proceeds once it finds `<skill-name>` actually invoked in the
file. It looks for the invocation *anywhere*, not first: opening a session
with `/model`, `/usage`, `/context` or `/compact` before calling the skill is
normal and must not confuse the check. It also accepts the bare
`/jira-task-executor` form alongside `/jira-sdlc:jira-task-executor`, since
the namespace disappears on a loose-file install or a renamed plugin. Zero
matches means this almost certainly isn't that skill's run — the script
files nothing, lists the commands the transcript *does* contain, and stops.
Ask the user whether to analyze it as one of those instead, or to point at a
different transcript; don't re-run with a guess.

**Run metrics come from the script; never do this arithmetic yourself.**
The script emits what the transcript actually records, scoped to this
skill's own turns (via each line's `attributionSkill`, so pre-skill
`/model` chatter and other skills in the session don't pollute it):
`MODELS`, `SKILL_TURNS`, `TOOL_CALLS`, `TOOLS_USED`, `TOOL_ERRORS`,
`TOOL_ERRORS_BY_TOOL`, `SIDECHAIN_TURNS`, `TOKENS_IN` / `TOKENS_OUT` /
`TOKENS_CACHE_READ` / `TOKENS_CACHE_WRITE`, `FIRST_TS` / `LAST_TS` /
`WALL_CLOCK_S`. Copy them into the report's Run metrics table verbatim.
`TOOLS_USED` and `TOOL_ERRORS_BY_TOOL` are `Name:count` histograms, most-used
first (`Bash:8 Read:2 Write:2`) — a shape check, not the timeline: *which*
calls ran, in order, is step 2's job. Summing usage by hand is a trap the script already
handles: one API response is split across several assistant lines that each
repeat the *same* usage object, so a naive per-line sum overcounts (2.6× on
a real run) — that's why `SKILL_TURNS` counts distinct `message.id`, not
lines.

Read them for what they measure, and say so in the report:

- `WALL_CLOCK_S` is the **span** from first to last turn, not compute time
  or effort — it includes every pause while the run waited on a human. Call
  it "elapsed", never "working time".
- Token counts are the API's own, and **cache-read dominates** on a long
  run; `TOKENS_IN` looks absurdly small next to it because most input was
  cached. That's normal, not an anomaly to investigate.
- There is **no cost field** in the transcript. Don't convert tokens to
  money — that needs pricing the transcript doesn't carry.
- Nothing here is per-step. Don't attribute a token count or a duration to
  an individual skill step; the transcript can't support it.

Metrics are context for the verdict, not evidence for it: a compliance
finding still needs an entry uuid and a quote. But an outlier worth naming
— dozens of tool calls for a two-step run, a high `TOOL_ERRORS`, a
surprising `SIDECHAIN_TURNS` — is a legitimate pointer to where the prose
made the agent work too hard.

**Where the key comes from is known per skill, not guessed.** Each skill
produces its key at one specific point in its own run, and a recorded
transcript already contains that point — so the script reads it there:

| skill | when the key exists | where the script reads it |
|---|---|---|
| `jira-task-assigner` | **only once the issue is created** (step 6A.1) — before that the run has no key, because it mints one | the first `acli jira workitem create` result (`.key` under `--json`, else the key in the browse URL). Multistep: the first create is the top-level issue; sub-task creates follow. |
| `jira-task-executor` | **after statuscheck** — the key is derived from the worktree's branch, not passed in | statuscheck's `issue_key` row (its `branch` row as fallback) |
| `jira-task-reviewer` | **after statuscheck**, same derivation — then the run may climb from a sub-task branch to its parent | statuscheck's `issue_key` row (its `branch` row as fallback); note in the report if the run then climbed to a parent |

**A key found anywhere else is not the run's subject.** Frequency is
deliberately not the decision: a transcript can mention `<PROJECT-KEY>-nn`
for reasons that have nothing to do with what it did — "look what I did in
JST-nn, do the same here" is the common one, and the cited issue can easily
be mentioned more often than the real subject. The script reports
`KEY_RANKING` as context only, and files under the anchor even when the
anchor isn't the loudest key (it says so on stderr when they differ).

**On `KEY_STATUS=unexpected` — stop and ask, don't improvise.** It means the
key was absent from the site that skill is supposed to produce it, which is
itself a finding worth understanding before filing anything: an assigner run
with no `workitem create` never created an issue; an executor/reviewer run
with no resolved `issue_key` row never got past its healthcheck. The script
files nothing and prints what it found. Ask the user which key to file
under (offering the `KEY_RANKING` candidates and what the run appears to
have actually done), then re-run with the key as the third argument. Same
if the answer is "none — this run has no issue": say so and stop.

Then read the exact prose that ran, end to end — pull it from its tag (the
`/<version>/` segment of the transcript's Base-directory line is a SemVer
release): `git show v<version>:plugins/jira-sdlc/skills/<skill-name>/SKILL.md`.
You cannot judge divergence from prose you skimmed.

The transcript format — line types, content shapes, and the jq recipes
used below — is documented in [references/transcript-format.md](references/transcript-format.md).
Read it before writing any jq beyond the profiling above.

## Step 1 — recover what actually ran

The transcript embeds its own ground truth; prefer it over assumptions:

- **Invocation(s)**: `user` lines whose content contains
  `<command-name>/<skill-name></command-name>`, with or without a
  `<plugin>:` prefix. Step 0 already counted them (`INVOCATIONS`); locate
  them here. The first one is **not** necessarily the session's first
  command — `/model`, `/usage`, `/context`, `/compact` and ordinary chatter
  can all precede it. More than one match means the skill was re-run inside
  the session — treat each as a separate run segment and cover all of them
  (re-runs are a designed scenario for these skills, and the second run's
  behavior is often the interesting part).
- **The version that ran, and its arguments**: the first `text` block after
  the invocation starts with `Base directory for this skill: …/cache/…/<version>/skills/<skill-name>`
  and contains the full skill prompt as the agent saw it, with `$ARGUMENTS`
  substituted — recover the run's arguments here. The `/<version>/` segment is
  the marketplace release that ran (e.g. `…/jira-sdlc/0.4.5/skills/…`); record
  it as `plugin_version:` in the report frontmatter and the Run snapshot. You
  judge compliance against that version's prose — the tagged copy you pulled in
  Step 0 is exactly it — so the run can only be guilty of ignoring the prose it
  was given.
- **Run context**: `cwd`, `gitBranch`, `timestamp`, `version` sit on the
  envelope of the first `user` line.

## Step 2 — reconstruct the run timeline

Walk the transcript once and build a condensed timeline: for each
assistant turn, the tool calls made (`tool_use` name + the interesting
part of `input`), whether each result erred (`tool_result` with
`is_error`), user interjections, and permission denials or interrupts.
Ignore bookkeeping lines (`mode`, `permission-mode`, `file-history-*`,
`attachment`, `last-prompt`) and keep `isSidechain: true` traffic
attributed to the subagent call that spawned it, not the main thread.

Anchor everything you might cite: each meaningful entry has a stable
`uuid` and `timestamp` — quote those in the report, not line numbers,
which shift when files are re-synced.

## Step 3 — the compliance walk

Now hold the version's prose (the tagged copy you pulled) in one hand and
the timeline in the other. Go through the skill prose **in its own order** — every numbered
step, every load-bearing rule in the conventions block — and assign each
one a verdict:

- **followed** — evidence in the timeline matches the instruction.
  Cite the evidence (entry uuid + a short quote).
- **diverged** — the agent did something *else* where the instruction
  applied. This is the headline finding; capture what the prose says,
  what happened instead, and the visible consequence (or "none
  observable").
- **skipped** — the instruction applied and nothing in the transcript
  shows it happening. Distinguish honestly from…
- **not-reached** — the branch never applied to this run (wrong track,
  earlier stop, single-step vs. multistep). Not a defect; recording it
  keeps the table honest about coverage.
- **can't-tell** — the transcript doesn't contain enough to judge
  (evidence would live in tool output that was truncated, or in Jira/
  GitHub state the transcript doesn't show). Say so rather than
  guessing; a wrong "followed" poisons the report.

**Always check, regardless of skill: script dispatch.** The shared
scripts ship twice (`_shared/scripts/*.sh` for POSIX, `_shared/scripts/win/*.ps1`
for Windows), and each skill must pick the branch from its own runtime
*before* the first script runs. From the timeline, list every script
invocation with its full arguments, then verify:

- the variant matches the run's OS — `bash …/X.sh` on POSIX,
  `pwsh`/`powershell …/win/X.ps1` on Windows (the OS is visible in the
  envelope `cwd` path style and confirmed by statuscheck's `platform`
  row in its tool result);
- the choice was made up front, not discovered by trial and error
  (a failed `.sh` call followed by a `.ps1` retry is a dispatch
  divergence even if the run recovered);
- one run uses one branch throughout — mixing `.sh` and `.ps1` calls
  is a divergence unless `STATUSCHECK_FORCE_OS` is set (the deliberate
  cross-OS test override; note it in the run snapshot when present);
- arguments match what the prose specifies for that call site.

For every **diverged** and **skipped**, ask *why* before assigning
blame: ambiguous wording, an instruction buried mid-paragraph, an
environmental surprise the prose never anticipated, or the agent plainly
ignoring clear text. The "why" is what makes the report actionable — it
decides whether the fix is a prose edit, a new script, or nothing.

## Step 4 — code-execution incidents

Step 3 judges *instructions*; this step judges *executions*. Walk the
Step-2 timeline for every command or script invocation that **ran but
didn't behave as the skill prose expected** — a non-zero exit, an
`is_error` tool result, output the next instruction didn't anticipate,
or any point where the agent had to write an extra script/one-liner or
rewrite logic it had already committed to in order to get unblocked.
This is narrower than a compliance `diverged`/`skipped` row: it is about
something that *ran* and *misbehaved*, not an instruction the agent never
reached — keep the two in their own steps.

For each incident, answer:

- **What failed** — the command/script and its error or unexpected
  output, quoted, with the entry uuid.
- **Root cause** — internal (the skill's own prose or a shared script: a
  wrong path, a script bug, an instruction assuming something untrue on
  this run or machine) or external (missing dependency, OS/env quirk,
  network, stale Jira/git state, something specific to that machine)?
  Say which, and why.
- **How the agent reacted** — did it find the cause in one or two tries,
  or thrash through unrelated attempts first? Quote the turns that show it.
- **What unblocked it** — an ad-hoc script/one-liner, a change of course,
  a question to the user, or did it give up and leave it broken?
- **Outcome** — did the workaround actually unblock the run, or leave
  residue (a skipped step, a wrong downstream result)?
- **Suggested fix** — a change to the analyzed skill's SKILL.md or a
  shared script that would have prevented this or surfaced it sooner. If
  the workaround is itself worth promoting into a script, don't repeat the
  write-up here — cross-reference its row in Step 5 (helper scripts worth
  keeping).

Add further questions where they make an incident clearer — this list is
a floor, not a ceiling. A dispatch mismatch already flagged in Step 3 (a
failed `.sh` then a `.ps1` retry) is also an incident: record it here for
the execution view but cross-reference the Step 3 row rather than
re-arguing blame. A run where every command behaved as expected has no
incidents — say so and move on.

## Step 5 — mine for helper scripts worth keeping

Scan the timeline for tooling the agent had to invent mid-run — the
point is that the *next* run shouldn't reinvent it:

- `Write`/`Edit` calls that created `.sh` / `.py` / `.ps1` files, or any
  script written into a temp dir and then executed;
- multi-line Bash (loops, heredocs, non-trivial `jq`/`awk`/API calls)
  that re-derives something deterministic;
- the same command shape repeated with small variations — a loop or
  script the prose could have shipped.

For each candidate record: what it does, where in the transcript it was
born (uuid), whether it worked, and a suggested home — usually
`_shared/scripts/` (remember the Windows twin rule: a script promoted
there needs a `win/*.ps1` port) or a one-line recipe added to the
skill's prose. It's equally valid to conclude a candidate is
run-specific noise not worth keeping — say that too, so the next
debugging pass doesn't re-evaluate it.

## Step 6 — write the report

Write `<skill-name>-<conversation-uuid>.md` into step 0's `REPORT_DIR`
(`conversations/<ISSUE-KEY>/`), where it lands beside the copy of the
transcript it analyzes — the report and its evidence travel together, and
the uuid anchors you cite stay resolvable. Both names come from step 0's
output; don't re-derive them.

Do not edit AGENTS.md, READMEs, or the analyzed skill — the report
*recommends* changes; making them is a separate, human-approved step.

`conversations/` is git-ignored, and step 0's script creates that guard
before it copies anything in. Leave it that way: the transcript is a raw
session log (absolute paths, emails, instance URLs, whatever the run
printed) and this marketplace is public. Never `git add -f` it, and don't
"helpfully" narrow the ignore rule to let the report through — if the user
wants a report shared, that's their call to make explicitly.

Use exactly this skeleton (frontmatter keys are a contract — downstream
tooling matches on them):

```markdown
---
skill: <skill-name>
conversation: <conversation-uuid>
plugin_version: <version that ran, from the Base-directory line — e.g. 0.4.5>
---

# Run report: <skill-name> — <conversation-uuid>

## Run snapshot
When, cwd, branch, plugin version that ran (from the Base-directory line —
the same value as the `plugin_version:` frontmatter key), the arguments the
run received, number of invocations in the session, and a one-line outcome
(finished / stopped at step N / stub).

## Run metrics
| metric | value |
|---|---|
Copy step 0's measured values — never compute or estimate your own:
model(s) (`MODELS`), API turns (`SKILL_TURNS`), tool calls (`TOOL_CALLS`)
broken down by tool (`TOOLS_USED`) with how many erred (`TOOL_ERRORS`,
`TOOL_ERRORS_BY_TOOL`), tokens in / out / cache-read / cache-write
(`TOKENS_*`), subagent turns (`SIDECHAIN_TURNS`), and elapsed
(`WALL_CLOCK_S`, `FIRST_TS` → `LAST_TS`). Omit the section for a stub.

## Compliance walk
| Instruction (step / rule) | Verdict | Evidence |
|---|---|---|
One row per numbered step and load-bearing rule, in skill order.
Verdicts: followed · diverged · skipped · not-reached · can't-tell.
Evidence: entry uuid + short quote, or "—" for not-reached.

## Divergences in detail
One subsection per diverged/skipped row that matters:
what the prose says → what happened (quoted, with uuid) → consequence →
likely why → suggested fix (prose edit / script / no action).

## Incidents

### Code executions
| What failed (uuid) | Root cause | Agent's reaction | Workaround / fix | Suggested prose fix |
|---|---|---|---|---|
One row per incident found in Step 4, or "none — every command behaved as
expected" if the run had none.

## Helper scripts worth keeping
| What the agent built | Born at (uuid) | Worked? | Suggested home |
(or "none — nothing reinvented this run".)

## Verdict
2–4 sentences: overall compliance, the one finding to act on first, and
whether this run suggests the skill text or the agent needs the fix.
```

End your own turn by telling the user the report path and the two or
three findings they'd act on — don't make them open the file to learn
whether anything was wrong.

## Feature-level roll-up (`collect_feature` + `feature_report`)

Everything above analyzes **one** transcript. To profile a whole **feature**
instead — every conversation of one Jira issue at once, with per-conversation
metrics *and* per-feature token/model totals — use the two roll-up scripts.
They're Windows-only this round; their `posix/*.sh` twins are stubs that exit
non-zero, so dispatch is `pwsh …/win/*.ps1` (outside a plugin session the
scripts live under `scripts/win/` relative to this skill):

`collect_feature` puts the machine-readable JSON on **stdout** and the human
metrics view on **stderr**, so either form below prints the listing to the
console while the JSON flows onward cleanly. Two equivalent ways to run it:

```powershell
# 1. One-shot pipe — collector JSON straight into the report-builder → markdown
pwsh "${CLAUDE_PLUGIN_ROOT}/skills/conversation-debugger/scripts/win/collect_feature.ps1" <ISSUE-KEY> `
  | pwsh "${CLAUDE_PLUGIN_ROOT}/skills/conversation-debugger/scripts/win/feature_report.ps1" > <ISSUE-KEY>-feature-report.md
```

```powershell
# 2. Two steps — save the JSON first (keep/inspect it), then render markdown from it
pwsh "${CLAUDE_PLUGIN_ROOT}/skills/conversation-debugger/scripts/win/collect_feature.ps1" <ISSUE-KEY> > <ISSUE-KEY>.json
pwsh "${CLAUDE_PLUGIN_ROOT}/skills/conversation-debugger/scripts/win/feature_report.ps1" <ISSUE-KEY>.json > <ISSUE-KEY>-feature-report.md
```

Both dispatch each script as its own `pwsh` process. `feature_report` also
accepts input as a stage inside an existing session
(`… | .\feature_report.ps1 > out.md`) and from a `-`/stdin path — all forms
write the markdown to `>` correctly.

`collect_feature` resolves the feature's conversations by reusing
`sync_conversations`' list and runs `collect_run` over each — so its numbers are
the same measured metrics this skill already trusts, never re-estimated. It
auto-detects the feature **type** from Jira (a `subtasks` lookup): a plain issue
emits the flat `feature-report@2` JSON, while a parent with sub-tasks emits the
nested `feature-report@3` — the parent plus each **child feature** with its own
conversations in place, and a feature-wide roll-up across all of them.
`feature_report` renders whichever it's given (single-step output is unchanged).
The collector owns the JSON schema; `feature_report` only renders it. Read
[scripts/collect_feature.md](scripts/collect_feature.md),
[scripts/feature_report.md](scripts/feature_report.md), and
[references/feature-report-schema.md](references/feature-report-schema.md)
before running or changing either script — the per-transcript flow above (steps
0–6) is unaffected by this adjunct.

## Caveats that will bite

- **Long sessions get compacted**: a `summary`-type line (or an
  assistant text block that reads like a recap) means earlier turns were
  summarized away. Steps that fall inside the summarized span are
  **can't-tell**, not skipped.
- The user typing free-form course corrections mid-run is normal — an
  agent obeying the user *over* the skill is not a divergence, but note
  it, since repeated corrections in the same spot are a skill-text smell.
- One session can contain non-skill chatter before/after the invocation
  (the `<local-command-caveat>` blocks). It's outside the run; ignore it
  except as context.
