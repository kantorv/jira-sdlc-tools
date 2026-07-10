> **Note on this document:** this is the branching and release policy the
> `jira-sdlc` skills (in `../skills/`) were written against — it's what
> "the default base branch," the `feature/`/`hotfix/` split, and the
> squash-merge-into-parent-then-manual-release logic all assume. It's
> already generic (no project names, no company specifics — reviewed
> before publishing this repo). If your process differs, adapt this
> document to match yours, then update `<DEFAULT_BASE_BRANCH>` in
> `jira-sdlc-tools.env` in the project root (see `../skills/_shared/project-config.md`)
> and the branch-prefix rules in
> `jira-task-assigner` and `jira-acli-reference.md` §7 to match.

# Software Development Life Cycle (SDLC) & Branching Strategy

## 1. Overview and Purpose
This document defines the standard operating procedures for the Software Development Life Cycle (SDLC), Git branching strategy, and release management for this repository. 

**Audience:** Human developers, DevOps engineers, and Autonomous AI/LLM coding assistants.

**Core Philosophy:**
- **Continuous Integration / Batched Deployment:** We merge code continuously to staging but release to production in scheduled two-week sprint batches.
- **Decoupled Deployments:** Deployment does not equal release. We rely heavily on **Feature Flags** to merge incomplete or untested features safely into production without exposing them to end-users.

---

## 2. Branch Architecture

| Branch Name Pattern | Protected? | Source | Merges To | Purpose |
| :--- | :---: | :--- | :--- | :--- |
| `main` | ✅ Yes | `release/*`, `hotfix/*` | `development` | Represents the current production state. Strictly tagged with Semantic Versioning (e.g., `v1.2.3`). |
| `development` | ✅ Yes | `main` | `release/*` | The default working branch. Represents Staging/Integration. Code here is continuously deployed to the staging environment. |
| `feature/ISSUE-KEY-slug` | ❌ No | `development` | `development` | Used for new features and non-critical bug fixes. |
| `hotfix/ISSUE-KEY-slug` | ❌ No | `main` | `main` & `development` | Used **only** for critical production bugs that cannot wait for the next sprint release. |
| `release/sprint-<X.Y.Z>` | ❌ No | `development` | `main` | Temporary branch created at the end of a sprint for QA hardening and final bug fixes before production release. Named after the intended release version (computed from latest `v*` tag + chosen bump label, default `minor` — see §5). |

---

## 3. The 2-Week Sprint Lifecycle

Our development cycles run in 14-day sprints. The Git workflow strictly follows this cadence.

### Phase 1: Active Development (Days 1 to 11)
- Developers branch off `development` to create `feature/*` branches.
- Pull Requests (PRs) are opened against `development`.
- Once approved, PRs are merged immediately. 
- *Rule:* If a feature is incomplete, it MUST be wrapped in a Feature Flag before merging into `development`.

### Phase 2: Feature Freeze & Release Cut (Day 12)
- A new release branch is cut from `development` (e.g., `release/sprint-0.3.0`). The branch name embeds the intended SemVer version — `cut-release.yml` computes it from the latest `v*` tag + the chosen bump label (`patch`/`minor`/`major`, default `minor` per §5).
- **No new features** are allowed into this release branch. 
- `development` remains open for developers to start merging features for the *next* sprint.

### Phase 3: QA & Hardening (Days 12 to 14)
- QA tests the `release/*` branch in the staging environment.
- If bugs are found, developers branch directly off the `release/*` branch, fix the bug, and open a PR back into the `release/*` branch.

### Phase 4: Production Deployment (Day 14)
- The `release/*` branch is merged into `main` via a PR.
- A **Semantic Version Tag** (e.g., `v0.95.4`) is applied to the merge commit on `main`.
- The CI/CD pipeline deploys `main` to Production.
- `main` is merged back into `development` to ensure all QA bug fixes are synced.
- The `release/*` branch is deleted.

---

## 4. Emergency Production Bug Flow (Hotfixes)

When a critical bug is discovered in production that cannot wait for the end of the 2-week sprint cycle, the **Hotfix Flow** is triggered. This process completely bypasses the `development` branch to ensure we do not accidentally deploy unreleased sprint features prematurely.


```

[main (v1.0.0)] ────► [hotfix/ISSUE-123] ────► [QA/Verification]
│                                              │
▼                                              ▼
[main (v1.0.1)] ◄─────────────────────────────────────┘ (Merge & Tag)
│
▼
[development] (Sync back immediately)

```

### Step 1: Isolate and Branch
- Do **NOT** branch from `development`. 
- Pull the latest code from `main` and create a hotfix branch:
```bash
git checkout main
git pull origin main
git checkout -b hotfix/ISSUE-KEY-short-description

```

### Step 2: Fix and Validate

* Implement the fix locally.
* Deploy the hotfix branch to an isolated staging/preview environment for immediate QA validation.

### Step 3: Production Merge and Patch Tagging

* Open a Pull Request targeting `main`.
* Once approved, merge the PR into `main`.
* Increment the **PATCH** version of your semantic tag (e.g., `v1.2.4` becomes `v1.2.5`).
* The CI/CD pipeline triggers an automatic immediate deployment to Production.

### Step 4: Downstream Synchronization (Crucial)

* To prevent the bug from being reintroduced during the next sprint release, `main` **must** be merged back into `development` immediately following the production deployment.

```bash
git checkout development
git pull origin development
git merge main
git push origin development

```

---

## 5. Versioning Strategy (SemVer)

We strictly adhere to [Semantic Versioning](https://semver.org/) (`vMAJOR.MINOR.PATCH`) on the `main` branch.

* **MAJOR (`v2.0.0`):** Breaking changes, massive UI overhauls, or major architectural shifts.
* **MINOR (`v1.5.0`):** New sprint releases containing backward-compatible features (the standard increment for Day 14 releases).
* **PATCH (`v1.5.1`):** Emergency `hotfix/*` branches merged directly to `main` mid-sprint.

> *Note: Version tags must contain ONLY the semantic version number (e.g., `v1.5.0`), never sprint identifiers (e.g., `v1.5.0-sprint24`), to ensure compatibility with standard package managers and CI tools.*

---

## 6. Feature Flags

To prevent merge conflicts and "branch rot", long-running feature branches are discouraged.

* All code should ideally be merged into `development` within 3-4 days.
* If a feature spans multiple sprints, it MUST be protected by a feature flag.
* The feature is deployed to production silently. The product team toggles the flag to `true` when the feature is ready for public consumption.

---

## 7. 🤖 LLM System Directives

*Instructions for AI coding assistants (Copilot, Cursor, Gemini, etc.) reading this document:*

1. **Branch Naming:** When asked to generate a git branch command, strictly format it as `<type>/<ISSUE-KEY>-<kebab-case-description>`. (e.g., `git checkout -b feature/PROJ-123-add-user-auth`).
2. **Target Branches:** Always default PR creation scripts or git merge targets to `development`, unless explicitly told it is a production `hotfix`. If it is a hotfix, the source must be `main` and the target must be `main`.
3. **Feature Flags:** When generating code for a new UI component or API route that the user describes as "in progress" or "draft", automatically wrap the entry point in a standard feature flag check.
4. **Commit Messages:** Follow Conventional Commits format (`feat:`, `fix:`, `chore:`, `docs:`) to assist with automated SemVer changelog generation.
