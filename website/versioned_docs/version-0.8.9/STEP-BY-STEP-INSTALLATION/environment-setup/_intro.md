You will need:

- **Software** — see [Software](software.md)
  - Install `git`, `gh`, and `jq`
- **GitHub** — see [GitHub](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/github)
  - Account (can be free)
  - Repository
  - fine-grained PAT scoped to the repository with the following permissions:
    - `Contents` (read/write)
    - `Pull requests` (read/write)
    - `Meta` (read) - added automatically
- **Jira** — see [Jira](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/jira)
  - Account (can be free)
  - Space with a Board (you will have a `Project Key`, e.g. `XYZ`)
  - Four configured workflow statuses (names can differ):
    - `TODO`
    - `IN_PROGRESS`
    - `IN_REVIEW`
    - `DONE`
  - Users: can be only the owner, or additionally a dedicated user per each of
    the skills - `assigner`, `executor`, `reviewer` (fits the free tier - up to
    10 users in org).
  - Classic Jira API token (either for owner, or for each of the 3 users -
    `assigner`, `executor`, `reviewer`) with the following permissions:
    - `read:jira-user`
    - `read:jira-work`
    - `write:jira-work`
- **Coding Assistant** — see [Coding Assistant](https://kantorv.github.io/jira-sdlc-tools/docs/step-by-step-installation/coding-assistant)
  - Claude or any other compatible solution
    (see [Platform Compatibility Matrix](../coding-assistant/index.mdx#platform-compatibility-matrix))

Prefer a single tickable list over this section-by-section walkthrough? See
[Full setup checklist](../full-setup-checklist.md).

The pages below are the detailed reference for each item in the checklist.
