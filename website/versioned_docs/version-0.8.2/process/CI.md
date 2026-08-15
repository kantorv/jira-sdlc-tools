---
slug: /ci
sidebar_position: 2
sidebar_label: CI / GitHub Actions
---

> **Note on this document:** this describes the GitHub Actions workflows in
> `.github/workflows/` at the **marketplace repo root** (not inside the
> plugin) — they automate the release policy in [SDLC.md](SDLC.md) and the
> Jira issue transitions the `jira-sdlc` skills assume. It complements
> [AGENTS.md → Releasing](https://github.com/kantorv/jira-sdlc-tools/blob/main/AGENTS.md); this file is the CI-side
> reference, AGENTS.md is the authoring-side one. For the **user-facing** lab
> channel (how to install it, what extra skills it carries), see
> [LAB-CHANNEL.md](https://github.com/kantorv/jira-sdlc-tools/blob/lab/LAB-CHANNEL.md)
> — that doc lives on the `lab` branch. Everything project-specific is a
> secret or a `<TOKEN>` from `jira-sdlc-tools.env`, never a literal.

# CI / GitHub Actions

## Summary

Eight workflows, in four functional groups. The plugin itself is prompt files
plus two JSON manifests, so there is no build or test step for *it* — "CI" here
means **structure validation**, **release automation**, **documentation
publishing**, and **Jira status syncing**. The one thing that genuinely gets
built is the documentation site in `website/`.

| Workflow | Trigger | What it does |
| :- | :- | :- |
| `validator.yml` | push / PR to `development`, `main` | Runs `claude plugin validate .` and checks both manifests are well-formed JSON. The only gate on structural correctness. |
| `cut-release.yml` | manual `workflow_dispatch` (bump: patch/minor/major, default minor) | Computes the next SemVer from the latest **stable** tag + bump, cuts `release/sprint-<X.Y.Z>` off `development`, opens a **draft** PR into `main`. SDLC Phase 2. |
| `release.yml` | PR **merged** into `main` from `release/*` or `hotfix/*` | Cuts the versioned-docs snapshot onto `main`, tags `vX.Y.Z`, publishes the GitHub Release, bumps the manifests on `main`, back-merges `main`→`development` (opens a sync PR on conflict), deletes the branch, then dispatches `docs.yml`. SDLC Phase 4 / §4. |
| `docs.yml` | push to `main` touching `docs/**`, `website/**` or itself; `workflow_dispatch` | Builds the Docusaurus site in `website/` and deploys it to GitHub Pages. See [The docs site](#the-docs-site). |
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
  [AGENTS.md → Releasing](https://github.com/kantorv/jira-sdlc-tools/blob/main/AGENTS.md).
- **Docs path:** `docs/**` and `website/**` changes landing on `main` publish
  themselves through `docs.yml`; a *release* additionally cuts a versioned
  snapshot and has to ask for the run explicitly, because the push that carries
  the snapshot is made by CI and therefore triggers nothing. Both halves are in
  [The docs site](#the-docs-site).
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
  To reuse these three in your own project — secrets, status-name edits, and
  how they interleave with the skills — see
  [STATE-TRANSITIONS-WITH-GITHUB-ACTIONS.md](../github/STATE-TRANSITIONS-WITH-GITHUB-ACTIONS.md).

### Secrets used

| Secret | Used by |
| :- | :- |
| `GITHUB_TOKEN` (default) | `cut-release`, `release`, `update_lab` — push tags/branches, create releases & PRs, and dispatch `docs.yml`. Sufficient while `main`/`development` are unprotected; see AGENTS.md for the `RELEASE_PAT` swap if you enable branch protection. |
| *(none)* | `docs.yml` — `actions/deploy-pages` authenticates to Pages via OIDC (`id-token: write`), so no secret is configured for it. |
| `JIRA_ACCOUNT_URL`, `JIRA_ACCOUNT_EMAIL`, `JIRA_ISSUE_TRANSITION_TOKEN` | the three Jira transition workflows |

These Jira secrets are the **CI bot's own** credential, separate from the
skills' local auth: the skills authenticate per-request as
`JIRA_{ASSIGNER,EXECUTOR,REVIEWER}_{EMAIL,TOKEN}` from
`jira-sdlc-tools.local.env` and read nothing from these repo secrets.

______________________________________________________________________

## The docs site

`docs/**` is published to
`https://kantorv.github.io/jira-sdlc-tools/docs/<slug>` by **`docs.yml`**,
which builds the Docusaurus site in `website/` and deploys it to GitHub Pages.
Two jobs: `build` (checkout → Node 22 → `npm ci` → `npm run build` →
`upload-pages-artifact` from `website/build`) and `deploy`
(`actions/deploy-pages` in the `github-pages` environment).

Four settings in it are load-bearing rather than stylistic:

| Setting | Why |
| :- | :- |
| `paths:` filter on `docs/**`, `website/**` and `docs.yml` itself | without it, every source-only commit on `main` spends a minute republishing byte-identical output |
| `fetch-depth: 0` | `docusaurus.config.js` sets `showLastUpdateTime`, which reads git history. A shallow clone does not fail — it degrades to "cannot infer the update date" warnings and pages with no timestamps |
| `concurrency: {group: pages, cancel-in-progress: false}` | deploys queue instead of cancelling each other; a half-deployed site is worse than a stale one |
| `permissions: contents read, pages write, id-token write` | `deploy-pages` authenticates to Pages via OIDC, so `id-token: write` is not optional. No secret is involved |

### The human prerequisite

**Settings → Pages → Build and deployment → Source → "GitHub Actions"** must be
set by a person once. Until it is, `actions/deploy-pages` fails with
`Get Pages site failed` — an error that never mentions enabling Pages, and that
no YAML change fixes. Check it with
`gh api repos/kantorv/jira-sdlc-tools/pages` (a 404 means not enabled).

That same click creates the `github-pages` environment with a **deployment
branch policy allowing exactly one ref — the default branch**. It is invisible
until something tries to deploy from another ref:

```bash
gh api repos/kantorv/jira-sdlc-tools/environments/github-pages/deployment-branch-policies
```

### Why the release *dispatches* this workflow

`release.yml`'s `publish-docs` job runs
`gh workflow run "Docs site" --ref main` with the default `GITHUB_TOKEN` and
`permissions: actions: write`. Both halves of that are deliberate, and both
replace something that looks better and silently does not work:

- **A push would not be enough.** A push made with `GITHUB_TOKEN` **creates no
  workflow runs** — GitHub suppresses them to prevent loops. So the
  `docs:version` snapshot that `release.yml` commits to `main` never reaches
  `docs.yml`'s push trigger: no error, no failed run, no notification, and the
  site quietly stays on the previous version. `workflow_dispatch` and
  `repository_dispatch` are the documented carve-out that always create a run.
- **A reusable-workflow call (`uses: ./.github/workflows/docs.yml`) fails at the
  deploy.** A called workflow runs in the *caller's* context, so `github.ref` is
  `release.yml`'s ref — and `release.yml` triggers on a PR merge, making that ref
  a pull request merge ref, not a branch. The environment then refuses it:
  `Branch "refs/pull/<N>/merge" is not allowed to deploy to github-pages due to environment protection rules`. **`with: ref: main` does not rescue it** — that
  input only tells `actions/checkout` what to fetch, while the environment gate
  reads the *run's own* ref, which no input can change. Widening the deployment
  branch policy would "fix" it by whitelisting a pull request merge ref, i.e. by
  letting any PR deploy the site. Don't.

A dispatch sidesteps both: it creates its own run at `refs/heads/main`, which is
the one ref the policy allows.

The job's condition is
`if: ${{ !cancelled() && needs.release.result != 'skipped' }}`. `needs: release`
alone would mean "only if the entire release job succeeded, including its last
step" — and `release` ends with a back-merge and a branch delete, so a failure in
either would silently drop the docs publish *after* the tag and Release had
already shipped. The `!= 'skipped'` clause is what keeps every ordinary
(non-release) PR merged into `main` from republishing the site for nothing.

### Versioned docs

`release.yml` cuts `docusaurus docs:version <X.Y.Z>` onto `main` **before**
tagging, so the tagged commit carries the docs exactly as that release published
them. The version is reused from the release job's existing SDLC §5 resolution
(`release/*` → branch name, `hotfix/*` → patch on the latest tag) rather than
recomputed — a second implementation is how the tag and the snapshot drift
apart. `versioned_docs/`, `versioned_sidebars/` and `versions.json` are all
**committed**; `website/.gitignore` covers build products only, because an
ignored snapshot is a released version that silently is not on the site.

Once the first version exists, `docs/` becomes the *unreleased* docs served at
`/docs/next/…` and the newest snapshot serves the plain `/docs/…` route — so a
bare `/docs/sdlc` link keeps pointing at released docs, which is what the URLs
baked into the plugin's shipped files need.

> **The snapshot trap.** `docs:version` copies the docs root and nothing else,
> so anything a published doc references by a relative path from *outside* that
> root resolves fine in the working tree and breaks only inside the snapshot —
> and it **cannot fail until a version cut exists**. Manufacture one before
> merging any docs change that adds an asset:
>
> ```bash
> cd website
> npm run docusaurus -- docs:version 0.0.0-probe
> npm run build     # snapshot-only breakage fails HERE
> rm -rf versioned_docs/version-0.0.0-probe \
>        versioned_sidebars/version-0.0.0-probe-sidebars.json
> git checkout -- versions.json   # or delete it, before the first real cut
> ```
>
> `git status` must come back clean afterwards.

For the manual equivalent — needed for the release that introduces this
machinery, which runs the copy of `release.yml` that predates it — see
[SDLC.md → Cutting the docs version by hand](SDLC.md).

______________________________________________________________________

## Tagging Mechanics

Two independent tag namespaces live in this repo. They must never be
confused, because the release automation does version math on tag names.

### Stable tags — `vX.Y.Z`

Pure SemVer, no prefix beyond `v`, no suffix (no sprint tag, no pre-release).
Created **only** by `release.yml` on a `release/*` or `hotfix/*` merge into
`main`, on the merge commit — or, when that release cuts a docs snapshot, on the
snapshot commit sitting directly on top of it (see
[Versioned docs](#versioned-docs)).

- **`release/*`** takes its version from the branch name
  (`release/sprint-<X.Y.Z>`); a malformed name fails the job. The branch name
  is the single source of truth — to ship a different version, rename or
  re-cut the branch.
- **`hotfix/*`** is always a **patch** bump of the latest stable tag.
- The first ever release (no `v*` tag exists) is **`v0.1.0`**.
- `cut-release.yml` computes the *next* stable version = latest stable tag +
  bump level (default `minor`) and bakes it into the release branch name.

> **Manifest-vs-tag off-by-one on the stable path (by design).** `release.yml`
> tags *first*, then bumps `plugin.json` / `marketplace.json` in a *separate*
> later commit on `main`. So `git checkout vX.Y.Z` shows the manifest still at
> the previous version. (The lab path below does the opposite — it stamps the
> manifest *before* tagging, so an `@lab` install reports the exact build.) The
> **docs snapshot deliberately goes the other way** and is cut *before* the tag,
> so a checked-out tag does carry its own documentation; that ordering is
> explained in a comment next to the step.

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
| :- | :- | :- |
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
