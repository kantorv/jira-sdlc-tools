# jira-api-reference.md (Jira Cloud REST API v3, direct)

Reference for Claude Code when driving Jira **directly over the REST API**
instead of through `acli` (see [`jira-acli-reference.md`](jira-acli-reference.md)
for the CLI path, which is what the three skills normally use).

Reach for this when you need to call Jira **without `acli`** — e.g. from a
GitHub Actions runner, or with a **scoped** API token that `acli` can't
use. Every `curl` below is a *verified working call*: they were run against
a live Jira Cloud instance on 2026-07-12 and are the exact shapes the
`.github/workflows/jira_issue_transition_*.yml` workflows use.

Project-specific values are `<TOKEN>`s resolved from the two config files
(see [`project-config.md`](project-config.md)):

**`jira-sdlc-tools.local.env` (machine-specific, gitignored)**
- `<JIRA_ACCOUNT_URL>` — e.g. `your-site.atlassian.net` (a scheme is tolerated; it gets stripped)
- `<JIRA_ACCOUNT_EMAIL>` — the account the token belongs to
- `<JIRA_TOKEN>` — API token (classic **or** scoped; see §5)

`<CLOUD_ID>` is *not* configured — resolve it at runtime (see §1).

**Sections:** [0. The one rule that matters](#0-the-one-rule-that-matters-host--auth) ·
[1. Resolve the cloud id](#1-resolve-the-cloud-id) ·
[2. A reusable auth helper](#2-a-reusable-auth-helper) ·
[3. Read an issue's status](#3-read-an-issues-status) ·
[4. Transition an issue by status name](#4-transition-an-issue-by-status-name) ·
[5. Token types & scopes](#5-token-types--scopes) ·
[6. Gotchas](#6-gotchas)

---

## 0. The one rule that matters: host + auth

Jira Cloud is reachable two ways, and **which host you use decides whether a
scoped token works**:

| Host | Auth | Classic token | Scoped token |
|---|---|---|---|
| `https://<JIRA_ACCOUNT_URL>` (site domain) | Basic (`-u email:token`) | ✅ | ❌ `401 AUTHENTICATED_FAILED` |
| `https://api.atlassian.com/ex/jira/<CLOUD_ID>` (gateway) | Basic (`-u email:token`) | ✅ | ✅ |

Bearer auth (`Authorization: Bearer <token>`) does **not** work with either
kind of API token here (that's for real OAuth 3LO access tokens) — use
Basic.

**Therefore: always go through the `api.atlassian.com/ex/jira/<CLOUD_ID>`
gateway.** It works for both token types, so it's the portable choice.
(`acli`, by contrast, hits the site domain for operations, which is exactly
why `acli` can't use a scoped token.)

## 1. Resolve the cloud id

The gateway is addressed by cloud id, not host name. The site's
`_edge/tenant_info` endpoint returns it and needs **no auth**:

```bash
SITE="${JIRA_ACCOUNT_URL#*://}"                 # strip any scheme
CLOUD_ID=$(curl -fsSL "https://$SITE/_edge/tenant_info" | jq -r '.cloudId')
BASE="https://api.atlassian.com/ex/jira/$CLOUD_ID/rest/api/3"
```

```json
// GET https://<JIRA_ACCOUNT_URL>/_edge/tenant_info   →  200
{ "cloudId": "00000000-0000-0000-0000-000000000000" }
```

## 2. A reusable auth helper

Every authenticated call is Basic auth against `$BASE`. Define once:

```bash
api() { curl -sSfL -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" -H "Accept: application/json" "$@"; }
```

`-sSfL` = silent, but show errors, **fail the process on any HTTP ≥ 400**
(so `set -euo pipefail` catches auth/scope problems), and follow redirects.

Confirm the token authenticates at all:

```bash
api "$BASE/myself" | jq -r '.displayName'        # → "Ada Lovelace"   (200)
```

## 3. Read an issue's status

```bash
api "$BASE/issue/<KEY>?fields=status" | jq -r '.fields.status.name'
```

```json
// GET $BASE/issue/<KEY>?fields=status   →  200
{
  "key": "<KEY>",
  "fields": { "status": { "name": "<STATUS_TODO>" } }
}
```

## 4. Transition an issue by status name

The REST API transitions by **transition id**, not by target status name.
So it's two calls: list the available transitions, pick the one whose
**destination status** matches the name you want, then POST its id.

**4a. List available transitions** (depends on the issue's *current* status):

```bash
api "$BASE/issue/<KEY>/transitions"
```

```json
// GET $BASE/issue/<KEY>/transitions   →  200
{
  "transitions": [
    { "id": "11", "name": "To Do",       "to": { "name": "<STATUS_TODO>" } },
    { "id": "21", "name": "In Progress", "to": { "name": "<STATUS_IN_PROGRESS>" } },
    { "id": "31", "name": "In Review",   "to": { "name": "<STATUS_IN_REVIEW>" } },
    { "id": "41", "name": "Done",        "to": { "name": "<STATUS_DONE>" } }
  ]
}
```

**4b. Resolve the target status name → transition id** (`.to.name`, not
`.name`):

```bash
TID=$(api "$BASE/issue/<KEY>/transitions" \
  | jq -r --arg t "<STATUS_IN_PROGRESS>" 'first(.transitions[] | select(.to.name == $t) | .id) // empty')
# empty TID ⇒ no transition to that status is available from the current one
```

**4c. Perform the transition** (returns `204 No Content` on success):

```bash
api -X POST -H "Content-Type: application/json" \
  -d "{\"transition\":{\"id\":\"$TID\"}}" \
  "$BASE/issue/<KEY>/transitions"
```

Full round-trip that was verified (`<STATUS_TODO>` → `<STATUS_IN_PROGRESS>`
→ back), all `204`:

```
status before   : <STATUS_TODO>
POST transition (id 21)  →  204   →  status: <STATUS_IN_PROGRESS>
POST transition (id 11)  →  204   →  status: <STATUS_TODO>
```

## 5. Token types & scopes

Create tokens at `id.atlassian.com` → Security → API tokens.

- **Classic, unscoped** ("Create API token") — works on both hosts; carries
  the account's full Jira permissions. Simplest; restrict via the account's
  project permissions.
- **Scoped** ("Create API token with scopes") — least privilege, gateway
  only. For the read-status + transition flow above, the minimal set is
  three **coarse** scopes:

  | Scope | Grants |
  |---|---|
  | `read:jira-user` | `GET /myself` (identity) |
  | `read:jira-work` | `GET /issue`, `GET /issue/{key}/transitions` |
  | `write:jira-work` | `POST /issue/{key}/transitions` |

  Do **not** use the *granular* per-resource scopes (`read:issue:jira`,
  `read:issue.transition:jira`, `write:issue:jira`, …): `GET /issue`
  requires a whole bundle of them simultaneously, and any missing member
  returns `401 {"message":"Unauthorized; scope does not match"}`. The three
  coarse scopes above avoid that trap.

## 6. Gotchas

- **`401 Unauthorized; scope does not match`** — the token authenticated but
  lacks a scope the endpoint requires. Not a credential problem; see §5.
- **`401 AUTHENTICATED_FAILED`** (`x-seraph-loginreason` header) — a scoped
  token used against the **site domain**. Switch to the gateway (§0/§1).
- **`404 "Issue does not exist or you do not have permission to see it."`** —
  Jira masks missing *permission* as `404` (not `403`). If the key is
  correct, suspect scope/permission, not a typo.
- **`POST …/transitions` returns `204` with an empty body** — success has no
  JSON; don't try to parse it. Re-`GET` the issue to confirm the new status.
- **Transitions are current-status-dependent** — the id for a target status
  can differ (or be absent) depending on where the issue is now. Always
  resolve the id from a fresh `GET …/transitions`; never hard-code it.
