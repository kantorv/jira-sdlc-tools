# Extending the Gitflow / SDLC rules

How to change what the skills consider a legal branch, base, or flow —
without leaving half the repo believing the old rule.

This is a companion to
[skill-development-considerations.md](skill-development-considerations.md)
(which covers *how to write a skill*) and to [SDLC.md](SDLC.md) (which *is*
the policy). This document covers the mechanics of changing that policy once
it already has six layers of machinery pointing at it.

The worked examples are both real: JST-271 widened the branch convention from
two prefixes to four, and — in the same Story — added a new flow, `bugfix/`
cut from a `release/*` branch. They are deliberately different *classes* of
change, and the second is the one that bites.

> **Reading this before JST-271 lands?** This guide is merged ahead of the
> change it describes, so the method is available to the next person instead
> of trailing behind it. Until JST-271 reaches `<DEFAULT_BASE_BRANCH>`, the
> four-prefix convention described below is the state of *that* branch, not
> of the one you are reading this on. The examples hold either way — they
> document what the work did, not what is currently merged.

---

## 1. Why this needs a guide at all

A branching rule here is not stored in one place. It is stored six times, in
six different representations, because six different consumers need it:

| # | Layer | Lives in | Represents the rule as |
| :--- | :--- | :--- | :--- |
| L1 | **Policy** | [SDLC.md](SDLC.md) | Prose + tables for humans. The source of truth. |
| L2 | **Canonical spec** | [`skills/_shared/jira-api-reference.md`](../skills/_shared/jira-api-reference.md) §12–§13 | The machine-facing interface: the regex, the prefix table, the prefix/base sanity table. |
| L3 | **Scripts** | `skills/_shared/scripts/posix/*.sh` + `win/*.ps1` | Deterministic derivation (key from branch, base from branch). **Policy-free by design** — see §5. |
| L4 | **Skills** | the four `SKILL.md` files | Judgment: which start states are legal, which path a run takes, when to stop and ask. |
| L5 | **CI** | `.github/workflows/*.yml` | Triggers and gates — the only layer that *enforces* anything at runtime. |
| L6 | **Explanation** | the rest of `docs/`, incl. mermaid diagrams | Narrative + pictures for people learning the system. |

Nothing keeps these six in sync automatically. There is no build step, no
type system, and no test suite — [AGENTS.md](../../../AGENTS.md) says so
outright. **The layers drift silently, and a drifted layer looks completely
reasonable in a diff.** That is the whole problem this guide exists to solve.

### Order matters: L1 → L2 → everything else

Write the policy first (L1), then the canonical spec (L2), *then* implement.
L2 is what every other layer cites — `§12`, `§13` appear by name in scripts,
skills, and docs. If you implement first and write the spec last, each
implementer invents their own phrasing of the rule and you get four subtly
different rules that all look right individually.

State the rule **once**, in L2, in a form that can be quoted verbatim:

```
^(feature|bugfix|chore|hotfix)/([A-Z][A-Z0-9]*-[0-9]+)-
```

Then every other layer points at it instead of paraphrasing it.

---

## 2. Two classes of change

Classify your change before planning it, because the two need different work
and have different failure modes.

| | **Class A — widen the vocabulary** | **Class B — change a flow** |
| :--- | :--- | :--- |
| Example | add `bugfix/`, `chore/` to the allowed prefixes | let `bugfix/` be cut from `release/*` |
| Shape | additive; every old input keeps its old meaning | a rule that *used* to hold stops holding |
| Findable by grep? | **Yes** — the old pattern is a literal string | **No** — there is no old string to search for |
| Main risk | missing one of ~40 sites | breaking an invariant nobody wrote down |
| Verification | grep for the old pattern → zero hits | trace each flow end to end by hand |
| Parallelisable? | Yes — split by layer | Rarely — the decision logic is one file |

A Story can be both at once. JST-271 was: the four-prefix widening (A) and
the release-branch QA-fix path (B). They were *planned* together and
*executed* separately, which is the right instinct — see §4.

---

## 3. Class A worked example — widening the branch convention

**The change:** two prefixes (`feature/`, `hotfix/`) become four (`feature/`,
`bugfix/`, `chore/`, `hotfix/`).

### 3.1 Split the work by layer, not by file

JST-271's four sub-tasks map exactly onto the layer table, which is why they
ran in parallel without conflicts — **disjoint file sets**:

| Sub-task | Layer | Files |
| :--- | :--- | :--- |
| JST-272 | L1 + L6 | `SDLC.md` + 12 reference/doc files |
| JST-273 | L3 | 3 POSIX scripts + 3 PowerShell twins |
| JST-274 | L2 + L4 | `jira-api-reference.md` + all four `SKILL.md` |
| JST-275 | L5 | 11 workflow files |

What *couples* them is the specification, not the code — so the spec went in
the parent Story's description, and each sub-task applied it to its own
files. If you cannot write a spec crisp enough that four people could apply
it independently, the change is not ready to split.

### 3.2 The rules that made it safe

**Widen, never narrow.** Every existing branch and open PR must keep working
unchanged. This is what makes Class A additive, and it is what lets you ship
without a migration. Check it explicitly — it is an acceptance criterion, not
an assumption.

**Prefer prefix-agnostic derivation over a maintained list.** The best change
in JST-271 removed the need for future changes. Where a script only needs the
*key*, it strips everything up to the first `/` and never learns the prefixes
at all:

```bash
BR_TAIL=${BR#*/}
KEY=$(printf '%s' "$BR_TAIL" | grep -oE '^[A-Za-z][A-Za-z0-9]*-[0-9]+' || true)
```

`check_assignee` and `pr_base` derive keys this way, so a *fifth* prefix
would need no edit there at all. Only sites that must **distinguish** the
prefixes (validators, gates, the branch-search glob) need the enumerated
list. Ask, per site: does this need to know *which* prefix, or just *the
key*?

**Allowlist, never denylist, for anything version-bearing.** `release.yml`
fires on `release/*` and `hotfix/*` and nothing else. Because it is an
allowlist, adding two prefixes to the convention could not accidentally make
a `chore/` merge cut a release — the guard excludes new prefixes *by
construction*. A denylist ("not `feature/`") would have silently broken here.
This is the single most valuable structural property in the CI layer.

**Every POSIX script edit needs its `win/*.ps1` twin.** They are a contract
pair — same args, same output, same exit codes — and Windows drifts silently
otherwise. Re-verify with the parity procedure in
[AGENTS.md](../../../AGENTS.md) (`STATUSCHECK_FORCE_OS=windows`, diff each
port against its twin). This is not optional and not deferrable.

### 3.3 Sites that need the enumerated list

For reference, the kinds of site that genuinely need updating:

- **Validators** — `if [[ ! "$BRANCH" =~ ^(feature|…)/… ]]` in the CI gates
- **Extractors** — `sed -nE 's#^(feature|…)/([A-Z]…)-.*$#\2#p'`
- **Job-level `if:` guards** — `startsWith(github.head_ref, 'feature/') || …`
- **Branch globs** — `git for-each-ref 'refs/heads/feature/*' …`,
  `git branch -a --list "*feature/$KEY-*" …`
- **`case` statements** — statuscheck's `feature/*|hotfix/*)` branch row
- **Error messages** — they name the legal formats, and a stale one actively
  misleads whoever hits it
- **Skill prose** — anywhere a `SKILL.md` says "a `feature/` or `hotfix/`
  branch"

---

## 4. Class B worked example — adding `bugfix/` off `release/*`

**The change:** a defect found while hardening a release branch gets a
`bugfix/` branch cut *from that release branch*, with its PR targeting the
same branch — not `development`.

Grep finds nothing here. There is no old string that means "you may not
branch from a release branch"; the rule was implicit in the *absence* of a
path. This is what makes Class B harder, and the work is different in kind.

### 4.1 What a flow change actually demands

**a. A new legal start state (L4).** The assigner previously classified a
checkout as: base branch → proceed; production → hotfix only; issue branch →
stop; anything else → *ask the user*. A `release/*` checkout was falling into
"anything else", so the skill would ask a question the convention now
answers. A new flow almost always means an existing catch-all branch must be
split.

**b. A new column in the decision table (L4).** Assigner step 5C went from a
two-path table (planned work / hotfix) to four paths. Note it stayed a
*table*: closed decision spaces belong in tables, per
[skill-development-considerations.md](skill-development-considerations.md).

**c. An invariant that quietly stops holding (L2).** This is the signature of
a Class B change, and the thing to hunt for deliberately.

> Before: **every prefix had exactly one legal base.** §13's sanity check
> could therefore be two lines — "`hotfix/` with a non-production base is
> wrong; `feature/` with a production base is wrong."
>
> After: `bugfix/` is the first prefix with **two** legal bases
> (`development` *or* a `release/*`). The two-line pair cannot express that,
> so it had to become a table.

Nothing in a grep tells you this. You find it by asking, for each existing
rule: *is this still a function?* A one-to-one mapping becoming one-to-many
breaks every consumer that assumed uniqueness.

**d. A resolver whose fallback is now wrong (L3 consequence).** `pr_base`
resolves a PR base from four sources in order, ending at
`DEFAULT_BASE_BRANCH`. For a release-branch fix that default is *actively
harmful* — it aims the PR at `development`, and the fix misses the release it
exists to fix. The script did not change; what changed is that the durable
Jira `PR target branch:` comment became **load-bearing** rather than a
convenience, so the assigner must now confirm it posted. A new flow that
cannot be re-derived from the branch name alone must persist its base
somewhere durable.

**e. Symmetric stop conditions (L4).** Adding a path means adding its
mirror-image guard. The three non-hotfix paths all cut from your own
checkout, so:

- on `PRODUCTION_BRANCH`, decision is *not* hotfix → stop
- on `release/*`, decision is *not* QA-fix → stop (you would cut next
  sprint's work off a branch about to be tagged and closed)

A new path without its stop condition is how a flow change turns into
production damage.

### 4.2 The judgment call: teach the script, or teach the prose?

The most instructive thing about this change is what did **not** happen.
Neither script learned about release branches:

```
pr_base.sh      → zero mentions of "release"   (resolver stays policy-free)
statuscheck.sh  → the branch row reports release/* as "neither"
```

The judgment lives entirely in skill prose. That is deliberate, and it
follows the repo's existing split:

> **Scripts derive; skills judge.** `statuscheck` is role-agnostic on
> purpose — it reports what it sees (`linked worktree`, `issue branch`,
> `neither`) and never decides whether that context is right for whoever ran
> it. Each skill judges that in prose, which is exactly why one script can
> serve the assigner (wants the base branch), the executor, and the reviewer
> (want an issue branch).

Teaching `statuscheck` that `release/*` is legal-for-the-assigner-only would
have forced role branches into a role-agnostic script — the one thing its
design forbids. So the assigner's `branch` row documentation absorbed it
instead: *"the script only knows the base branch by name, so it reports
`PRODUCTION_BRANCH` and a `release/*` branch alike as neither; match those
yourself."*

**Rule of thumb:** put it in the script when it is deterministic and
role-independent (parse this branch → that key). Keep it in prose when it
depends on *who is asking* or on judgment the script cannot make.

---

## 5. The checklist

For any change to the branching or release rules:

```
PLAN
[ ] Classify: Class A (widen vocabulary) or Class B (change a flow)? Both?
[ ] Write the spec ONCE, in the Story description or L2 — not four times
[ ] Class B: list every invariant the change breaks (one-to-one → one-to-many?)
[ ] Split sub-tasks by LAYER, so file sets are disjoint and work parallelises

IMPLEMENT (in this order)
[ ] L1  docs/SDLC.md — the policy itself
[ ] L2  jira-api-reference.md §12 (convention) and §13 (base resolution + sanity)
[ ] L3  scripts/posix/*.sh  — prefer prefix-agnostic derivation over a list
[ ] L3  scripts/win/*.ps1   — every twin, no exceptions
[ ] L4  the four SKILL.md — start states, decision tables, stop conditions
[ ] L5  .github/workflows/ — validators, extractors, job-level if: guards
[ ] L5  confirm version-bearing guards stayed ALLOWLISTS (release.yml)
[ ] L6  docs + mermaid diagrams + demo-flow docs

VERIFY
[ ] grep the repo for the OLD pattern — expect zero hits (see §6)
[ ] claude plugin validate .
[ ] bash scripts/check-skill-size.sh
[ ] bash scripts/check-mermaid.sh
[ ] ps1/sh parity per AGENTS.md (STATUSCHECK_FORCE_OS=windows)
[ ] Class B: trace each flow end to end — assigner → executor → reviewer
[ ] Confirm every pre-existing branch/PR still behaves identically
```

---

## 6. Verification: grep for the old rule, not for the files you changed

The three repo validators (`plugin validate`, `check-skill-size`,
`check-mermaid`) all pass on a half-applied rule change. They check
structure, size, and diagram syntax — **none of them knows what your rule
is.** The only check that finds a missed site is searching for the pattern
you are replacing:

```bash
# Class A: the old enumeration, anywhere
grep -rn 'feature|hotfix' --include='*.sh' --include='*.ps1' \
     --include='*.yml' --include='*.md' . \
  | grep -v '^./translations/' | grep -v '/.agent/'

# and the prose form of the same claim
grep -rni 'feature/\* or hotfix/\*\|feature/ or hotfix/' .
```

### The cautionary tale, from the change that prompted this guide

Run against JST-271's branch after all four sub-tasks had been reviewed,
approved and merged into it, that grep found exactly one survivor —
`docs/applications/ci-review-pr-demo.md`, which still quoted
`^(feature|hotfix)/[A-Z][A-Z0-9_]+-[0-9]+-` for a workflow that by then read
`^(feature|bugfix|chore|hotfix)/[A-Z][A-Z0-9_]*-[0-9]+-`. Stale in two ways:
the prefix list *and* the `+`→`*` quantifier. (Fixed on the JST-271 branch,
where that loose end belongs.)

The instructive part: **that file was not overlooked.** The same change had
already edited it in two other places. A reviewer reading the diff sees
`ci-review-pr-demo.md` in the changed-files list and reasonably concludes it
was handled — and four sub-task reviews plus an aggregate review all did
exactly that. One occurrence inside an already-edited file is the single most
likely thing to survive a careful review, because "was this file updated?"
is the wrong question and it *looks* like the right one.

That is the entire argument for grepping the **whole repo for the old
pattern** rather than re-reading the diff: the diff can only show you what
changed, and what you are hunting is what didn't.

**Excluded from the sweep by policy:** `translations/` (generated skill
copies, regenerated by the localisation flow) and `.agent/skills/` plus other
platform mirrors (gitignored, divergent, maintained by hand by the repo
owner). Do not edit either.

---

## 7. Repo-specific traps

- **Bootstrapping order.** New prefixes are not recognised by the transition
  workflows until the workflow change *lands on the default branch*. A
  `chore/` branch cut before then silently skips its Jira transitions. So the
  branches for the change itself must use the *old* convention, and the first
  run that can use the new one is the one after the change merges. Say this
  in the Story, or someone will burn an afternoon on it.
- **Mermaid: `;` is a statement separator.** A semicolon anywhere in message
  text truncates the line and breaks the whole diagram, and the parser points
  at the token *after* it. Write `—` or `·`. Everything else you might
  suspect (angle brackets, colons, `→`, backticks) is fine.
- **Skill word budget.** `SKILL.md` files are capped (~5,000 words, hard
  ceiling 6,500) and a flow change *adds* prose. `jira-task-reviewer` is
  already a recorded exception at ~6,100. If your change pushes a skill over,
  the fix is progressive disclosure into `skills/_shared/*.md`, not deletion.
- **The `.env` token rule.** Never hardcode a real project's branch names.
  `DEFAULT_BASE_BRANCH`, `PRODUCTION_BRANCH` and friends are tokens resolved
  from `.jst/jira-sdlc-tools.env`. A literal `development` in a `SKILL.md`
  body breaks the next project that installs this.
- **Renames are not self-contained.** If a change renames a skill or the
  plugin, grep first — several skills hardcode `/jira-sdlc:...` slash
  commands and cross-reference each other by name. AGENTS.md lists the sites.

---

## 8. The one-paragraph version

Decide whether you are widening a vocabulary or changing a flow. Write the
rule once, in SDLC.md and §12/§13, before touching anything that quotes it.
Split the work by layer so file sets stay disjoint. Prefer derivations that
never learn the list over lists you must maintain. Keep version-bearing CI
guards as allowlists. Update every PowerShell twin. Then grep the whole repo
for the *old* rule and expect zero hits — because none of the automated
checks in this repo knows what your rule is, and a stale line in an
already-edited file is what survives review.
