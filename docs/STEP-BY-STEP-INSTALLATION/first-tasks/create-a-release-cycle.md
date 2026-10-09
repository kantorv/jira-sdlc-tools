---
slug: /step-by-step-installation/create-a-release-cycle
sidebar_position: 3
sidebar_label: Create a release cycle
---

# Create a release cycle

The skills finish at a merged PR: every issue lands on `DEFAULT_BASE_BRANCH`
(or, for a hotfix, on `PRODUCTION_BRANCH`). Getting from there to a tagged,
released version is up to your project, and the plugin doesn't impose a
process. This page describes one that works, **this repository's own**, so a
task can point at it and adapt it instead of designing a pipeline from scratch.

The strategy is Gitflow with sprint releases, defined in
[SDLC.md](../../process/SDLC.md). Two GitHub Actions workflows automate it, and
both are reprinted in full below.

## How the cycle runs

1. **Cut.** Run `cut-release.yml` by hand and pick a bump level (`patch` /
   `minor` / `major`, default `minor`). It computes the next version from the
   latest `vX.Y.Z` tag, creates `release/sprint-<X.Y.Z>` from `development`,
   and opens a **draft** PR into `main`.
2. **Harden.** QA runs on the release branch. Fixes are PRs into
   `release/sprint-<X.Y.Z>`; no new features go in.
3. **Merge.** Mark the draft PR ready and merge it into `main`.
4. **Release.** `release.yml` fires on that merge: it tags `vX.Y.Z`, publishes
   the GitHub Release, back-merges `main` into `development` (or opens a sync
   PR if that conflicts, never force-pushing), and deletes the release branch.

A `hotfix/*` PR merged into `main` runs the same step 4 with a patch bump.

## Where the version comes from

| merged branch | version | on a malformed or missing input |
| -- | -- | -- |
| `release/sprint-<X.Y.Z>` | taken from the branch name | the job fails; rename or re-cut the branch |
| `hotfix/*` | latest `vX.Y.Z` tag + patch | the job fails if no release tag exists yet |
| any other branch | no release | `release.yml`'s job-level `if:` skips it |

The first release, with no `v*` tag yet, is `v0.1.0`. Tags are pure SemVer, and
no PR label is read. Details: [SDLC.md §5](../../process/SDLC.md) and
[CI.md → Tagging Mechanics](../../process/CI.md#tagging-mechanics).

## Prerequisites

- **Two distinct long-lived branches**, the base and the production branch
  (see [Split production from base](../environment-setup/github/split-production-from-base.md)).
  Both workflows name `development` and `main` literally, so replace those with
  your own `DEFAULT_BASE_BRANCH` / `PRODUCTION_BRANCH` if they differ.
- **Settings → Actions → General → "Allow GitHub Actions to create and approve
  pull requests"** turned on. Without it `cut-release.yml` cannot open its draft
  PR, and `release.yml` cannot open a conflict sync PR.
- **Token.** The default `GITHUB_TOKEN` is enough while `main` and `development`
  are unprotected. With branch protection enabled, create a `RELEASE_PAT`
  secret and use it for the pushes in `release.yml`.

## Adapting it to your project

`cut-release.yml` is generic and can be copied as is. `release.yml` carries four
pieces specific to this repository. Keep the rest and replace these with
whatever *releasing* means for your project:

| piece in `release.yml` | what it does here | in your project |
| -- | -- | -- |
| step **Cut the versioned docs snapshot** | snapshots the Docusaurus docs for the version | drop it, or swap in your own docs or changelog step |
| step **Bump plugin manifests** | writes the version into `plugin.json` / `marketplace.json` | bump `package.json`, `pyproject.toml`, … or drop it |
| job **publish-docs** | dispatches the docs-site workflow | drop it, or dispatch your deploy |
| job **sync-lab** | dispatches the `lab` pre-release sync | drop it |

For this repository, publishing the GitHub Release *is* going to production,
because a plugin marketplace installs from tags. For a deployed application,
the "Release" step is where your deploy pipeline starts, whether that happens in
this workflow or through a trigger on the new tag.

## `cut-release.yml`

Reprinted from this repository as of v0.8.6. If this copy and the
[live file](https://github.com/kantorv/jira-sdlc-tools/blob/main/.github/workflows/cut-release.yml)
ever differ, the live file wins.

```yaml
# Cuts a release branch for the next sprint — SDLC §3 Phase 2 (Feature
# Freeze & Release Cut). Manual dispatch: takes a bump level (patch / minor /
# major, default minor), computes the next SemVer from the latest v* tag on
# origin + that level, branches `release/sprint-<X.Y.Z>` off `development`, and
# opens a DRAFT PR into `main`. The version is baked into the branch name;
# `release.yml` reads it back from there. To ship a different version, rename
# or re-cut the branch.
#
# Humans QA on the branch (Phase 3) by opening fix PRs back into
# `release/sprint-<X.Y.Z>`, then mark this draft PR ready and merge it (Phase 4,
# step 1). `release.yml` takes over on that merge.
#
# Prereq: the repo setting "Allow GitHub Actions to create and approve pull
# requests" must be ON for `gh pr create --draft` to succeed.
name: Cut release

on:
  workflow_dispatch:
    inputs:
      bump:
        description: Bump level for the release (patch / minor / major). Default minor — the sprint-default per SDLC §5.
        type: choice
        required: true
        default: minor
        options:
          - patch
          - minor
          - major

permissions:
  contents: write
  pull-requests: write

jobs:
  cut:
    name: Cut release/sprint-<version> from development
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with:
          ref: development
          fetch-depth: 0

      - name: Resolve version from latest tag + bump level
        id: resolve
        env:
          BUMP: ${{ inputs.bump }}
        run: |
          set -euo pipefail
          # Validate input (belt-and-suspenders — the choice UI already constrains)
          case "${BUMP}" in
            patch|minor|major) ;;
            *) echo "::error::bump must be one of patch/minor/major (got '${BUMP}')"; exit 1 ;;
          esac
          # Query origin for the latest release tag (checkout may not have
          # fetched every tag). Use --refs to suppress peeled-ref duplicates.
          # Keep ONLY plain vX.Y.Z release tags — exclude prereleases such as
          # the lab builds update_lab.yml tags (vX.Y.Z-lab.N). `sort -V` ranks a
          # -lab prerelease ABOVE its release, and the node regex below rejects
          # it, so an unfiltered latest-tag would break the release cut.
          prev="$(git ls-remote --refs --tags origin 'v[0-9]*' \
            | sed -E 's#.*refs/tags/##' \
            | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -V | tail -1 || true)"
          if [ -z "${prev}" ]; then
            # No tags yet -> first release is 0.1.0 (matches release.yml logic).
            next="0.1.0"
          else
            # Reuse release.yml's SemVer bump logic (Node is clearer than shell
            # arithmetic). Output without leading 'v' — the branch name uses the
            # bare version (release/sprint-<X.Y.Z>).
            export PREV="${prev}" LEVEL="${BUMP}"
            next="$(node -e '
              const m = process.env.PREV.match(/^v(\d+)\.(\d+)\.(\d+)$/);
              if (!m) { console.error("unparseable prev tag:", process.env.PREV); process.exit(2); }
              let [maj, min, pat] = [+m[1], +m[2], +m[3]];
              const lvl = process.env.LEVEL;
              if (lvl === "major")      { maj++; min = 0; pat = 0; }
              else if (lvl === "minor") { min++; pat = 0; }
              else                      { pat++; }
              process.stdout.write(`${maj}.${min}.${pat}`);
            ')"
          fi
          echo "prev=${prev:-<none — first release>}" >> "$GITHUB_OUTPUT"
          echo "next=${next}" >> "$GITHUB_OUTPUT"

      - name: Create release/sprint-${{ steps.resolve.outputs.next }}
        id: create
        env:
          NEXT: ${{ steps.resolve.outputs.next }}
        run: |
          set -euo pipefail
          branch="release/sprint-${NEXT}"
          if git ls-remote --heads origin "${branch}" | grep -q .; then
            echo "::error::Branch ${branch} already exists on origin. Delete it first, or choose a different bump."
            exit 1
          fi
          git checkout -b "${branch}" origin/development
          git push -u origin "${branch}"
          echo "::notice::Created ${branch} from development"
          echo "branch=${branch}" >> "$GITHUB_OUTPUT"

      - name: Open draft PR into main
        id: pr
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NEXT: ${{ steps.resolve.outputs.next }}
          BRANCH: ${{ steps.create.outputs.branch }}
        run: |
          set -euo pipefail
          # Unquoted heredoc so ${NEXT}/${BRANCH} expand; deliberately backtick-free.
          body=$(cat <<EOF
          Release cut from development — SDLC Phase 2.

          1. QA runs against this branch (Phase 3). Fix bugs as PRs into
             release/sprint-${NEXT}; never merge new features here.
          2. When green, mark this draft PR ready and merge it into main.
          3. release.yml then tags v${NEXT}, publishes the GitHub Release,
             back-merges main into development, and deletes this branch.

          The version is set in the branch name at cut time. To ship a
          different version, rename or re-cut the branch — do not relabel.

          Diff: development...release/sprint-${NEXT}
          EOF
          )
          url=$(gh pr create \
            --base main --head "${BRANCH}" --draft \
            --title "Release v${NEXT}" \
            --body "${body}")
          echo "draft_pr=${url}" >> "$GITHUB_OUTPUT"
          echo "${url}"

      - name: Job summary
        env:
          NEXT: ${{ steps.resolve.outputs.next }}
          PREV: ${{ steps.resolve.outputs.prev }}
          BUMP: ${{ inputs.bump }}
          BRANCH: ${{ steps.create.outputs.branch }}
          DRAFT_PR: ${{ steps.pr.outputs.draft_pr }}
        run: |
          {
            echo "## Cut release v${NEXT}"
            echo ""
            echo "- bump  : ${BUMP} (from ${PREV})"
            echo "- branch: \`${BRANCH}\` (cut from \`development\`)"
            echo "- draft PR: ${DRAFT_PR}"
            echo ""
            echo "Next: QA on this branch, then merge the draft PR into \`main\` — \`release.yml\` does the rest."
          } >> "$GITHUB_STEP_SUMMARY"
```

## `release.yml`

Reprinted from this repository as of v0.8.6. If this copy and the
[live file](https://github.com/kantorv/jira-sdlc-tools/blob/main/.github/workflows/release.yml)
ever differ, the live file wins.

```yaml
# Tags and releases on every PR merge into main from a release/* or
# hotfix/* branch — SDLC §3 Phase 4 (release) and §4 (hotfix). Runs the full
# release sequence the policy mandates, in order:
#   1. resolve the version (release/* -> from the branch name; hotfix/* ->
#      latest v* tag + patch; a malformed release name fails the job — §5)
#   2. cut the versioned-docs snapshot for that version onto main (JST-289)
#   3. tag vX.Y.Z (pure SemVer, no sprint suffix — §5 note)
#   4. publish the GitHub Release (= "deploy main to Production" for a
#      plugin marketplace — there's nothing else to ship)
#   5. back-merge main -> development  (§3 Phase 4 step 6 / §4 Step 4)
#   6. delete the release/hotfix branch (§3 Phase 4 step 7)
# then two more jobs — publish-docs and sync-lab — dispatch the docs and lab
# workflows respectively. Both are dispatches rather than reusable-workflow
# calls for the same reason: a push made with GITHUB_TOKEN creates no workflow
# runs, so the snapshot/back-merge commits would never reach the target's push
# trigger (see the comment on publish-docs, and CI.md -> The docs site).
#
# Only fires for release/* and hotfix/* head branches — a feature PR merged
# straight into main does NOT trigger a release (the `if:` guard below).
#
# Auth: the default GITHUB_TOKEN works while main/development are unprotected
# (verified at implementation time). If branch protection is later enabled, or
# you want the back-merge commit to re-trigger the validator workflow, set a
# RELEASE_PAT secret and swap GH_TOKEN/GIT_AUTHOR/PAT comments below. See
# AGENTS.md -> Releasing.
name: Release

on:
  pull_request:
    branches: [main]
    types: [closed]

permissions:
  contents: write        # create tags + GitHub Releases
  pull-requests: write  # open the sync-back PR on conflict

jobs:
  release:
    name: Tag, release, sync main -> development, cleanup
    runs-on: ubuntu-latest
    # Only real merges from a release/* or hotfix/* branch, never a closed
    # PR or a feature PR sneaking into main.
    if: >-
      github.event.pull_request.merged == true
      && (
        startsWith(github.event.pull_request.head.ref, 'release/')
        || startsWith(github.event.pull_request.head.ref, 'hotfix/')
      )
    # Expose the sync step's outcome for the sync-lab job below to read. Only
    # a real back-merge push moves development — "pushed" means lab has work to
    # pick up, a conflict sync-PR URL means development did not move, and an
    # empty value (skipped, or failed before the sync step) means it did not.
    outputs:
      synced: ${{ steps.sync.outputs.synced }}
    steps:
      - name: Checkout merge commit (full history + tags)
        uses: actions/checkout@v6
        with:
          ref: ${{ github.event.pull_request.merge_commit_sha }}
          fetch-depth: 0
          persist-credentials: true   # default token pushes tags, releases, back-merge, branch delete

      - name: Configure git identity
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

      - name: Resolve version
        id: version
        env:
          HEAD_REF: ${{ github.event.pull_request.head.ref }}
        run: |
          set -euo pipefail
          # Previous release on both paths: the most recent v*-prefixed tag
          # reachable from the merge commit. The Publish step passes this to
          # `gh release create --notes-start-tag` so the release notes start
          # from there.
          # --exclude '*-*' skips pre-release / lab tags (e.g. vX.Y.Z-lab-N) so
          # only strict stable tags count as the "previous release".
          prev="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude '*-*' 2>/dev/null || true)"
          echo "prev=${prev}" >> "$GITHUB_OUTPUT"

          # The version comes from the head ref, by SDLC §5. The two branch
          # types differ only in how `next` is resolved; everything downstream
          # (tag, release, manifest bump, back-merge, branch delete) is shared.
          case "${HEAD_REF}" in
            release/*)
              # The branch name IS the source of truth — release.yml no longer
              # re-derives the version from the latest tag + a PR label. The
              # ONLY accepted form is release/sprint-<X.Y.Z> (no leading v);
              # this is what cut-release.yml produces and what SDLC §2 names.
              # One canonical spelling, one regex. A v-prefixed or otherwise
              # malformed name fails loudly — no fallback to tag arithmetic —
              # since the way to change a release's version is to rename or
              # re-cut the branch, not to relabel a PR (SDLC §5).
              if ! [[ "${HEAD_REF}" =~ ^release/sprint-([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
                echo "::error::Release branch '${HEAD_REF}' is not 'release/sprint-<X.Y.Z>' (no leading 'v' in the version). The branch name is the source of truth for the release version; rename or re-cut the branch."
                exit 1
              fi
              next="v${BASH_REMATCH[1]}"
              # Display-only bump kind (does NOT drive `next` — the branch name
              # does). 'initial' on the first release, when no prior tag exists.
              if [ -z "${prev}" ]; then
                level="initial"
              else
                pv="${prev#v}"; nv="${next#v}"
                pmj="${pv%%.*}"; rest="${pv#*.}"; pmn="${rest%%.*}"
                nmj="${nv%%.*}"; rest="${nv#*.}"; nmn="${rest%%.*}"
                if   [ "${nmj}" -gt "${pmj}" ]; then level="major"
                elif [ "${nmn}" -gt "${pmn}" ]; then level="minor"
                else                                 level="patch"
                fi
              fi
              ;;
            hotfix/*)
              # A hotfix is by SDLC §4's definition an emergency fix for a
              # critical production bug — that IS a patch. Always patch-bump
              # the latest tag; no PR label is read (labels play no part in
              # the release pipeline anymore — SDLC §5). A hotfix cannot
              # precede the first release, so a missing prev tag is an error
              # rather than a silent v0.1.0.
              level="patch"
              if [ -z "${prev}" ]; then
                echo "::error::hotfix/* merged but no release tag exists yet — a hotfix cannot precede the first release."
                exit 1
              fi
              export PREV="${prev}"
              next="$(node -e '
                const m = process.env.PREV.match(/^v(\d+)\.(\d+)\.(\d+)$/);
                if (!m) { console.error("unparseable prev tag:", process.env.PREV); process.exit(2); }
                let [maj, min, pat] = [+m[1], +m[2], +m[3]];
                pat++;
                process.stdout.write(`v${maj}.${min}.${pat}`);
              ')"
              ;;
            *)
              echo "::error::Unexpected head ref ${HEAD_REF} (expected release/* or hotfix/*)."
              exit 1
              ;;
          esac

          echo "next=${next}" >> "$GITHUB_OUTPUT"
          echo "level=${level}" >> "$GITHUB_OUTPUT"

      - name: Print resolved versions
        env:
          PREV: ${{ steps.version.outputs.prev }}
          NEXT: ${{ steps.version.outputs.next }}
          LEVEL: ${{ steps.version.outputs.level }}
        run: |
          echo "bump level : ${LEVEL}"
          echo "previous   : ${PREV:-<none — first release>}"
          echo "next       : ${NEXT}"

      - name: Set up Node (for the docs version cut)
        uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: npm
          cache-dependency-path: website/package-lock.json

      - name: Cut the versioned docs snapshot
        id: docs_version
        env:
          NEXT: ${{ steps.version.outputs.next }}
          MERGE_SHA: ${{ github.event.pull_request.merge_commit_sha }}
        run: |
          set -euo pipefail
          # WHY THIS STEP SITS HERE — before the tag, after the version resolve.
          # It looks arbitrary six months later, so: `docusaurus docs:version`
          # writes a snapshot into the working tree that has to be committed
          # somewhere, and cutting it *before* the tag is what makes the tagged
          # commit carry its own docs — `git checkout vX.Y.Z` then shows the
          # docs exactly as that release published them. Two supporting
          # reasons: this is the last point where a failure costs nothing (no
          # tag, no Release, no branch deleted yet — just re-run), and the
          # constraint from the field notes this was modelled on (cut *after*
          # the package build, because the build needed the tree at the release
          # version) does not apply — this repo has no package build. The
          # manifest bump deliberately stays *after* the tag; that off-by-one
          # is documented in docs/CI.md and is not what this step changes.
          #
          # VERSION comes from the "Resolve version" step above — SDLC §5's one
          # implementation (release/* -> branch name, hotfix/* -> patch on the
          # latest tag). Nothing is recomputed here; a second implementation is
          # how the tag and the docs snapshot would drift apart.
          VERSION="${NEXT#v}"
          # Build on the merge commit rather than origin/main so a plain
          # (non-force) push fails loudly if main moved under us, instead of
          # quietly tagging a commit carrying somebody else's work.
          git checkout -B main "${MERGE_SHA}"
          if [ -d "website/versioned_docs/version-${VERSION}" ]; then
            echo "::notice::website/versioned_docs/version-${VERSION} already exists — nothing to cut."
          else
            (cd website && npm ci && npm run docusaurus -- docs:version "${VERSION}")
            # All three artefacts are committed, never gitignored: an ignored
            # snapshot is a released version that silently is not on the site.
            git add website/versioned_docs website/versioned_sidebars website/versions.json
            git commit -m "docs: version snapshot ${NEXT}"
            # This push is made with GITHUB_TOKEN, so it creates NO workflow
            # runs — docs.yml's push trigger will not see it. That is exactly
            # what the publish-docs job below exists to work around.
            git push origin main
          fi
          echo "sha=$(git rev-parse HEAD)" >> "$GITHUB_OUTPUT"

      - name: Tag the release commit
        env:
          NEXT: ${{ steps.version.outputs.next }}
          # The merge commit, or the docs-snapshot commit sitting directly on
          # top of it — see the placement comment on the step above.
          RELEASE_SHA: ${{ steps.docs_version.outputs.sha }}
        run: |
          set -euo pipefail
          if git rev-parse -q --verify "refs/tags/${NEXT}" >/dev/null; then
            echo "::error::Tag ${NEXT} already exists; not overwriting. Resolve before re-running."
            exit 1
          fi
          git tag -a "${NEXT}" -m "Release ${NEXT}" "${RELEASE_SHA}"
          git push origin "${NEXT}"

      - name: Publish GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          PREV: ${{ steps.version.outputs.prev }}
          NEXT: ${{ steps.version.outputs.next }}
        run: |
          set -euo pipefail
          # The tag was created + pushed in the previous step on the exact
          # release commit, so gh release create just attaches the release to
          # that existing tag — no --target needed (and avoiding one sidesteps
          # a gh-version-specific error when --target meets a pre-existing tag).
          # --generate-notes derives the body from PR titles/commits since the
          # previous tag (or all history on first release). Using PR titles
          # avoids this repo's non-Conventional-Commits merge messages and
          # stays generic for any repo. No CD pipeline exists for a plugin
          # marketplace — publishing this Release IS going to production.
          if [ -n "${PREV}" ]; then
            gh release create "${NEXT}" --title "${NEXT}" \
              --generate-notes --notes-start-tag "${PREV}"
          else
            gh release create "${NEXT}" --title "${NEXT}" \
              --generate-notes
          fi

      - name: Bump plugin manifests to ${NEXT}
        env:
          NEXT: ${{ steps.version.outputs.next }}
        run: |
          set -euo pipefail
          # Strip leading 'v' from NEXT (e.g. v0.3.0 -> 0.3.0)
          NEXT_NO_V="${NEXT#v}"
          # The docs-version step already left us on main; re-point at
          # origin/main anyway so this step stands on its own.
          git checkout -B main origin/main
          # Update the two manifest files using jq (select plugin by name, not index)
          jq --arg ver "$NEXT_NO_V" '.version = $ver' plugins/jira-sdlc/.claude-plugin/plugin.json > plugin.json.tmp && mv plugin.json.tmp plugins/jira-sdlc/.claude-plugin/plugin.json
          jq --arg ver "$NEXT_NO_V" '(.plugins[] | select(.name == "jira-sdlc") | .version) = $ver' .claude-plugin/marketplace.json > marketplace.json.tmp && mv marketplace.json.tmp .claude-plugin/marketplace.json
          # Commit and push to main
          git add plugins/jira-sdlc/.claude-plugin/plugin.json .claude-plugin/marketplace.json
          git commit -m "chore: bump plugin version to ${NEXT}"
          git push origin main

      - name: Back-merge main into development
        id: sync
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NEXT: ${{ steps.version.outputs.next }}
        run: |
          set -euo pipefail
          git fetch origin development
          git checkout -B development origin/development
          # --no-ff keeps the merge topology explicit (a real sync commit,
          # not a fast-forward that would hide that main moved).
          if git merge --no-ff origin/main -m "chore: sync main into development after ${NEXT}"; then
            git push origin development
            echo "synced=pushed" >> "$GITHUB_OUTPUT"
          else
            # Conflict -> never force-push. Abort, push a sync branch, open a
            # PR for a human to resolve (SDLC keeps the final merge human).
            git merge --abort
            sync_branch="sync/main-to-dev-${NEXT}"
            git checkout -B "${sync_branch}" origin/main
            git push -u origin "${sync_branch}"
            # Body intentionally backtick-free (unquoted heredoc, ${NEXT} expands).
            body=$(cat <<EOF
          Auto-opened by release.yml — back-merge of main into development
          after ${NEXT} conflicted and needs a human to resolve. SDLC §3
          Phase 4 step 6 / §4 Step 4 require this sync so the next sprint
          carries the release's QA fixes.
          EOF
          )
            url=$(gh pr create --base development --head "${sync_branch}" \
              --title "chore: sync main into development after ${NEXT}" \
              --body "${body}")
            echo "synced=${url}" >> "$GITHUB_OUTPUT"
            echo "::warning::Back-merge conflicted; opened PR for resolution: ${url}"
          fi

      - name: Delete the release/hotfix branch
        # SDLC §3 Phase 4 step 7. Acting on the PR's head ref (not a
        # hardcoded branch) and gated by the job-level `if:` release/* /
        # hotfix/* check, so main/development can never be targeted here.
        env:
          HEAD_REF: ${{ github.event.pull_request.head.ref }}
        run: |
          set -euo pipefail
          git push origin --delete "${HEAD_REF}"
          echo "::notice::Deleted branch ${HEAD_REF}"

      - name: Job summary
        env:
          NEXT: ${{ steps.version.outputs.next }}
          PREV: ${{ steps.version.outputs.prev }}
          LEVEL: ${{ steps.version.outputs.level }}
          HEAD_REF: ${{ github.event.pull_request.head.ref }}
          SYNCED: ${{ steps.sync.outputs.synced }}
        run: |
          {
            echo "## Release ${NEXT}"
            echo ""
            echo "- merged: \`${HEAD_REF}\` -> main"
            echo "- bump   : ${LEVEL} (from ${PREV:-<none>})"
            echo "- tag    : ${NEXT}"
            echo "- release: https://github.com/${{ github.repository }}/releases/tag/${NEXT}"
            case "${SYNCED}" in
              pushed) echo "- sync   : main -> development (pushed)" ;;
              *)      echo "- sync   : back-merge PR opened — ${SYNCED}" ;;
            esac
            echo "- cleanup: deleted \`${HEAD_REF}\`"
          } >> "$GITHUB_STEP_SUMMARY"

  publish-docs:
    name: Publish the docs site
    needs: release
    runs-on: ubuntu-latest
    # WHAT THIS CONDITION DOES, stated so the comment and the YAML agree:
    #   !cancelled()                       -> run even if `release` FAILED.
    #   needs.release.result != 'skipped'  -> but not when it was skipped.
    # `needs: release` on its own would mean "only if the whole release job
    # succeeded, including its last step" — and release ends with a back-merge
    # and a branch delete, so a failure in either would silently take the docs
    # publish down with it after the tag and the Release had already shipped.
    # The second clause is what stops every ordinary (non-release) PR merged
    # into main from republishing the site for nothing: on those, release's own
    # `if:` guard skips it, and skipped is the one result we do not act on.
    if: ${{ !cancelled() && needs.release.result != 'skipped' }}
    permissions:
      actions: write        # dispatching a workflow run needs it; nothing else does
    steps:
      # WHY A DISPATCH AND NOT `uses: ./.github/workflows/docs.yml`.
      # The reusable-workflow call looks strictly better — declarative, no CLI,
      # no token — and it does build the site correctly. Then it dies at the
      # deploy with:
      #
      #   Branch "refs/pull/<N>/merge" is not allowed to deploy to github-pages
      #   due to environment protection rules.
      #
      # Two invisible things combine. A called workflow runs in the CALLER's
      # context, so github.ref is this workflow's ref — and this workflow
      # triggers on a PR merge, so that ref is a pull request merge ref, not a
      # branch at all. Meanwhile the github-pages environment allows exactly one
      # ref: the default branch. `with: ref: main` does NOT rescue it; that
      # input only tells actions/checkout what to fetch, while the environment
      # gate reads the RUN's own ref, which no input can change. You can build
      # exactly the right bytes and still be refused.
      #
      # Widening the deployment branch policy is the tempting fix. Don't: the
      # ref you would be whitelisting is a pull request merge ref, which would
      # let any PR deploy the site.
      #
      # A dispatch has none of this — it creates its own run at refs/heads/main,
      # which is the ref the policy allows. It is also the documented carve-out
      # from "a GITHUB_TOKEN push creates no workflow runs", so no PAT and no
      # long-lived secret is needed here.
      - name: Dispatch the docs workflow
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: gh workflow run "Docs site" --ref main --repo "${{ github.repository }}"

  sync-lab:
    name: Dispatch the lab sync
    needs: release
    runs-on: ubuntu-latest
    # Runs only when the back-merge actually pushed development. Why the three
    # clauses, stated so this comment and the YAML agree:
    #   !cancelled()                         -> never dispatch from a cancelled run.
    #   needs.release.result != 'skipped'    -> an ordinary feature PR merged
    #       into main skips the release job (its own `if:` guard), and must not
    #       dispatch a lab sync for a development push that never happened.
    #   needs.release.outputs.synced == 'pushed'
    #       -> the back-merge step sets "pushed" on a real push, and a sync-PR
    #       URL on conflict (where development has NOT moved, so there is
    #       nothing for lab to sync). "pushed" is the only value that means
    #       update_lab.yml has a development change to pick up.
    # It is a dispatch and not a `uses:` call for exactly the reason publish-docs
    # documents: a GITHUB_TOKEN push creates no workflow runs, so the back-merge
    # commit never reaches update_lab.yml's push trigger; workflow_dispatch is
    # the documented carve-out. See CI.md -> The docs site.
    if: ${{ !cancelled() && needs.release.result != 'skipped' && needs.release.outputs.synced == 'pushed' }}
    permissions:
      actions: write        # dispatching a workflow run needs it; nothing else does
    steps:
      - name: Dispatch the lab sync
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: gh workflow run "Sync Lab with Development" --ref main --repo "${{ github.repository }}"
```

## Task prompt

Paste this into your coding assistant from the main checkout. It names this page
so the executor adapts a known-good pipeline rather than designing one:

```text
/jira-sdlc:jira-task-assigner "Add a release cycle to this repository, modelled
on https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/create-a-release-cycle
— a manual cut-release workflow that creates release/sprint-<X.Y.Z> from the
base branch and opens a draft PR into the production branch, and a release
workflow that, on merging that PR, tags vX.Y.Z, publishes a GitHub Release,
back-merges production into base, and deletes the release branch. Hotfix merges
into production get a patch bump. Use the base and production branch names from
.jst/jira-sdlc-tools.env. Replace the page's repository-specific steps (docs
snapshot, plugin manifest bump, publish-docs, sync-lab) with what releasing
means for this project, or drop them. Lint both workflow files with actionlint,
and list the repository settings a human must change."
```
