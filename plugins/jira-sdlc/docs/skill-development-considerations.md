# Skill development considerations

> **Status: working hypotheses, not settled rules.** These are the
> guidelines behind the "Editing a skill" section in the repo root's
> `AGENTS.md`, written out with their reasoning and caveats so we can
> test them properly later (see [How to actually test
> this](#how-to-actually-test-this)). Nobody has published rigorous
> benchmarks of "prose vs. pseudo-code in skill files" — what follows
> comes from known LLM behaviors plus the guidance in Anthropic's
> [skill-creator](https://claude.com/plugins/skill-creator) skill,
> which independently agrees with all three hypotheses. Until we run
> our own evals, treat each as a suggestion with a stated failure
> mode, not a MUST.

## Why we care (the motivating data)

A `SKILL.md` body is a prompt the LLM re-reads on every invocation of
that skill. In this repo the three `jira-sdlc` skills dominate real
usage — a July 2026 snapshot of one heavy user's `/usage` showed the
plugin accounting for ~40% of weekly requests, with 35% of usage
hitting >100k-token cache misses and 11–18% of turns running above
150k tokens of context. Two consequences:

1. **The expensive unit is the model round trip, not the skill file.**
   The skill bodies themselves are a few thousand tokens — trimming
   them barely moves cost. But every step the model executes "by hand"
   is a full API round trip with the whole (large) context re-sent.
2. **Reliability compounds.** A skill invoked hundreds of times per
   week turns a 2% per-run deviation into a weekly incident.

Each hypothesis below targets one of those two levers.

## Hypothesis 1 — if it fits in one line, keep it one line

**Suggestion:** prefer the shortest phrasing that is still
unambiguous; don't introduce a trivial flow or decision with pages of
prose.

**Why it should help:** the payoff is *reliability, not tokens*. Long
prompts dilute attention, and instructions buried mid-file get skipped
or half-applied — the "lost in the middle" effect is measured LLM
behavior, not folklore. Fewer lines also means fewer places for two
instructions to quietly contradict each other.

**Caveats:**
- Over-terse is a worse failure mode than over-long. A one-liner the
  model misreads costs more than three lines it follows. Cut
  redundancy and hedging — not the "why" clause on load-bearing rules.
- If you can't state a rule in one line, that's often a sign the rule
  itself isn't crisp yet. Fix the rule before compressing the wording.
- Token savings from trimming a 300–450-line skill body are marginal
  at the context sizes these skills actually run at. Don't justify a
  brevity pass on cost grounds; justify it on instruction-following.

**What a test would measure:** pass rate on the same eval prompts
before/after a leanness pass, with special attention to instructions
located mid-file in the long version.

## Hypothesis 2 — if it can be scripted, script it

**Suggestion:** deterministic sequences (queries, status transitions,
environment checks, multi-step setup) belong in
`skills/_shared/scripts/posix/` as bash/python, with the `SKILL.md` reduced
to "run X, act on its output". `statuscheck.sh` is the in-repo pattern
to copy. If eval transcripts show runs repeatedly improvising the same
command sequence, that's the signal to extract a script.

**Why it should help:** this is the strongest of the three, for two
independent reasons.
- *Cost/latency:* when the model reproduces a procedure from prose,
  each step is a model round trip carrying the full context. A script
  collapses N model turns into one `Bash` call returning a compact
  result — at 100k+ contexts this is the dominant lever, far bigger
  than anything wording changes can buy.
- *Determinism:* a script executes identically every run. Prose
  re-derivation is sampling — each run is a fresh chance to deviate,
  skip a step, or reorder two steps that matter.

**Caveats:**
- Scripts fail *differently*, not less. A bug in a script is wrong
  100% of the time and — in a repo with no test suite — rots silently,
  whereas a model following prose can notice something is off and
  adapt. So: script the stable, deterministic parts; leave judgment
  and error recovery to the model.
- A script is a second artifact to keep in sync with the prose that
  invokes it (flags, output format, exit codes). Renames and output
  changes now have two homes.
- Environment variance (missing CLI, auth mode, OS differences) hits
  scripts harder than prose. Scripts should fail loudly with a
  remediation message, not half-succeed.

**What a test would measure:** total tokens and wall-clock duration
per eval run (skill-creator's benchmark captures both), plus deviation
rate across repeated runs of the same prompt — prose-driven runs
should show higher variance.

## Hypothesis 3 — pseudo-code over prose for branching logic

**Suggestion:** when a decision has an enumerable set of branches
(status transitions, track selection, single-step vs. multistep),
express it as a decision table or numbered if/else rather than
paragraphs.

**Why it should help:** models follow explicit structure more reliably
than branching buried in prose — fewer places to misparse which
condition owns which action, and a reader (human or model) can verify
the branch set is exhaustive at a glance.

**Caveats — true for closed decision spaces, risky for open ones:**
- Pseudo-code wins when the branch space is *closed*: every case the
  model will meet is one of the enumerated ones.
- When reality can land outside the enumerated branches, rigid
  structure misfires: the model force-fits the situation into the
  nearest listed branch instead of reasoning. For open decision
  spaces, a sentence of reasoning ("prefer X because Y") generalizes
  better than a table.
- Same warning skill-creator gives about caps-lock MUSTs: structure
  without rationale invites literal-minded misreads. Even inside a
  decision table, a one-line "why" on the non-obvious branch is cheap
  insurance.

**What a test would measure:** branch-selection accuracy on eval
prompts that hit each enumerated case, *plus* deliberately
out-of-distribution prompts that fit none of the branches — the
pseudo-code version should win the former and is at risk on the
latter.

## How to actually test this

skill-creator's eval loop exists for exactly this question — no
custom harness needed:

1. Snapshot the skill as-is (`cp -r <skill> <workspace>/skill-snapshot/`).
2. Apply *one* hypothesis as a transform (a leanness pass, or a
   script extraction, or a prose→pseudo-code rewrite — not all three
   at once, or the results won't attribute).
3. Run the same eval prompts against both versions as parallel
   subagent runs (skill-creator's "improving an existing skill" flow,
   with the snapshot as baseline).
4. Compare pass rate, total tokens, and duration from
   `benchmark.json`; run each prompt several times so variance —
   hypothesis 2's main prediction — is visible.
5. Read the transcripts, not just the scores: repeated improvised
   command sequences argue for hypothesis 2; skipped mid-file
   instructions argue for hypothesis 1; force-fitted branches argue
   against overdoing hypothesis 3.

Given how much of real usage flows through these three skills, even a
small measured improvement is worth the afternoon — and a null result
is worth knowing before we restructure skills around a belief.
