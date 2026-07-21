> **Note on this document:** this describes the GitHub Actions workflows in
> `.github/workflows/` at the **marketplace repo root** (not inside the
> plugin) — they automate the release policy in [SDLC.md](SDLC.md) and the
> Jira issue transitions. Those transition workflows matter more than they
> used to: **no skill moves a card by itself** ([JIRA-STATES.md](JIRA-STATES.md)),
> so CI is one of the two supported ways to drive the board — the other
> being a rule in `JIRA-SDLC-TOOLS-RULES.md`. It complements
> [AGENTS.md → Releasing](../../../AGENTS.md); this file is the CI-side
> reference, AGENTS.md is the authoring-side one. For the **user-facing** lab
> channel (how to install it, what extra skills it carries), see
> [LAB-CHANNEL.md](https://github.com/kantorv/jira-sdlc-tools/blob/lab/LAB-CHANNEL.md)
> — that doc lives on the `lab` branch. Everything project-specific is a
> secret or a `<TOKEN>` from `jira-sdlc-tools.env`, never a literal.

# CI / GitHub Actions

## Summary

Seven workflows, in three functional groups. There is no build or test
step — the plugin is prompt files plus two JSON manifests — so "CI" here
means **structure validation**, **release automation**, and **Jira status
syncing**.

| Workflow | Trigger | What it does |
| :--- | :--- | :--- |
| `validator.yml` | push / PR to `development`, `main` | Runs `claude plugin validate .` and checks both manifests are well-formed JSON. The only gate on structural correctness. |
| `cut-release.yml` | manual `workflow_dispatch` (bump: patch/minor/major, default minor) | Computes the next SemVer from the latest **stable** tag + bump, cuts `release/sprint-<X.Y.Z>` off `development`, opens a **draft** PR into `main`. SDLC Phase 2. |
| `release.yml` | PR **merged** into `main` from `release/*` or `hotfix/*` | Tags `vX.Y.Z`, publishes the GitHub Release, bumps the manifests on `main`, back-merges `main`→`development` (opens a sync PR on conflict), deletes the branch. SDLC Phase 4 / §4. |
| `update_lab.yml` | push to `development` or `lab` | Merges `development`→`lab` to keep the lab channel current, stamps the plugin manifests with a `X.Y.Z-lab.N` version **on the branch**, and tags the build `vX.Y.Z-lab.N`. See [Tagging Mechanics](#tagging-mechanics). |
| `jira_issue_transition_on_branch.yml` | `create` (a `feature/*` or `hotfix/*` branch) | Advances the issue **To Do → In Progress**. |
| `jira_issue_transition_on_pr_open.yml` | PR opened/reopened from `feature/*` / `hotfix/*` | Advances the issue **→ In Review**. |
| `jira_issue_transition_on_merge.yml` | PR closed (merged) on an issue branch | Advances the issue **→ Done**. |

### How the pieces connect

- **Release path (stable):** `cut-release` → QA on `release/sprint-<X.Y.Z>`
  → merge the draft PR into `main` → `release.yml` does tag + release +
  back-merge + cleanup. The version lives in the **branch name**, read back
  by `release.yml` — no PR label, no `VERSION` file. Full policy in
  [SDLC.md](SDLC.md); order-of-operations in
  [AGENTS.md → Releasing](../../../AGENTS.md).
- **Lab path (continuous):** every push to `development` cascades into `lab`
  and produces a `vX.Y.Z-lab.N` build, giving an always-current pre-release
  channel that runs **independently** of the stable release path.
- **Jira transitions** derive the issue key from the branch name and drive
  status changes to mirror `STATUS_TODO` / `STATUS_IN_PROGRESS` /
  `STATUS_IN_REVIEW` / `STATUS_DONE` from `jira-sdlc-tools.env`. They call the
  Jira REST API through the `api.atlassian.com` gateway (resolving `cloudId`
  from the site's `/_edge/tenant_info`), because a scoped API token is
  rejected by Basic auth on the `*.atlassian.net` domain. Each transition is
  **guarded** to only advance from the expected source status, never regress.

### Secrets used

| Secret | Used by |
| :--- | :--- |
| `GITHUB_TOKEN` (default) | `cut-release`, `release`, `update_lab` — push tags/branches, create releases & PRs. Sufficient while `main`/`development` are unprotected; see AGENTS.md for the `RELEASE_PAT` swap if you enable branch protection. |
| `JIRA_ACCOUNT_URL`, `JIRA_ACCOUNT_EMAIL`, `JIRA_ISSUE_TRANSITION_TOKEN` | the three Jira transition workflows |

---

## Tagging Mechanics

Two independent tag namespaces live in this repo. They must never be
confused, because the release automation does version math on tag names.

### Stable tags — `vX.Y.Z`

Pure SemVer, no prefix beyond `v`, no suffix (no sprint tag, no pre-release).
Created **only** by `release.yml` on a `release/*` or `hotfix/*` merge into
`main`, on the merge commit.

- **`release/*`** takes its version from the branch name
  (`release/sprint-<X.Y.Z>`); a malformed name fails the job. The branch name
  is the single source of truth — to ship a different version, rename or
  re-cut the branch.
- **`hotfix/*`** is always a **patch** bump of the latest stable tag.
- The first ever release (no `v*` tag exists) is **`v0.1.0`**.
- `cut-release.yml` computes the *next* stable version = latest stable tag +
  bump level (default `minor`) and bakes it into the release branch name.

> **Manifest-vs-tag off-by-one on the stable path (by design).** `release.yml`
> tags the merge commit *first*, then bumps `plugin.json` / `marketplace.json`
> in a *separate* later commit on `main`. So `git checkout vX.Y.Z` shows the
> manifest still at the previous version. (The lab path below does the
> opposite — it stamps the manifest *before* tagging, so an `@lab` install
> reports the exact build.)

### Lab tags — `vX.Y.Z-lab.N`

A continuously-updated pre-release channel, minted by `update_lab.yml`. For
the user-facing side (install commands, the two lab-only skills), see
[LAB-CHANNEL.md](https://github.com/kantorv/jira-sdlc-tools/blob/lab/LAB-CHANNEL.md).
Format:

```
v0.5.0-lab.3
│  │  │   └── N: build counter WITHIN this base — resets to 1 when the base bumps
│  └──┴────── vX.Y.Z: the latest STABLE release this build sits on top of
└──────────── same leading v as stable tags
```

- **Base `vX.Y.Z`** = the latest *plain* SemVer tag (prereleases — anything
  with a `-` — are excluded). It answers "what release is this lab build built
  on?"
- **Counter `N`** = highest existing `v<base>-lab.N` + 1. It is scoped to the
  **current base**, so it increments within a base (`…-lab.1`, `…-lab.2`, …)
  and **resets to 1** when a stable release bumps the base
  (`v0.5.0-lab.7` → release `v0.6.0` → next is `v0.6.0-lab.1`).

What one `update_lab.yml` run does, in order:

1. **Sync** — merge `development` into `lab`. If the merge conflicts *only* in
   the two manifest files (`plugin.json` + `marketplace.json`) — the expected
   case, since their version lines diverge by design — it **auto-resolves**
   by taking `development`'s copy (the version is re-stamped in step 3
   anyway). A conflict touching **anything else** stops the run for a human.
2. **Skip-if-already-tagged** — if `HEAD` is already an exact `v*-lab.*` tag
   (nothing new merged in), it pushes the sync and stops without a new tag.
3. **Stamp + commit** — write `X.Y.Z-lab.N` into both manifests and commit it
   **onto the `lab` branch** as `chore(lab): X.Y.Z-lab.N [skip ci]`.
4. **Push + tag** — push `lab`, then create and push the annotated tag
   `vX.Y.Z-lab.N` on that commit.

> **The version lives on the branch, not just the tag.** Because step 3
> commits the stamped manifest onto `lab`, **both** an `@lab` *branch* install
> and a `vX.Y.Z-lab.N` *tag* install report the correct build version. The
> `[skip ci]` marker on that commit stops the resulting push from
> re-triggering the workflow, so a dev update yields exactly one tag — no
> double-tag, no loop. A `concurrency` group serialises runs so two pushes
> can't collide on the counter. Lab builds are git tags only — **no GitHub
> Release** is published.

### Namespace isolation — why lab tags can't corrupt the stable version math

Both stable pickers scan for `v[0-9]*`, which *also* matches `vX.Y.Z-lab.N`.
Left unfiltered, a lab tag would be mistaken for the latest stable and crash
version resolution. Each picker is therefore hardened to accept only strict
`vX.Y.Z`:

| Workflow | Picker | Guard against lab tags |
| :--- | :--- | :--- |
| `cut-release.yml` | `git ls-remote … 'v[0-9]*'` → sort → tail | strip to bare name, then `grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'` (no suffix) |
| `release.yml` | `git describe --match 'v[0-9]*'` | `--exclude '*-*'` (drops any hyphenated tag) |

Result: lab tags are invisible to the stable path, and stable tags are the
only input to version bumps.

### The ordering caveat (intentional)

Whether `vX.Y.Z-lab.N` is "greater than" `vX.Y.Z` depends on who's asking:

- **Git `sort -V`** ranks `v0.5.0-lab.3` **above** `v0.5.0` — matching the
  intuition that a lab build is "v0.5.0 plus more."
- **Strict SemVer** treats the `-` suffix as a **pre-release**, ranking
  `v0.5.0-lab.3` **below** `v0.5.0`.

This mismatch is harmless — in fact useful. A strict-SemVer "pick the latest
stable" will **never** select a lab build, which is exactly what you want from
a pre-release channel: lab tags are opt-in by exact tag (or the `@lab`
branch), never auto-promoted.
