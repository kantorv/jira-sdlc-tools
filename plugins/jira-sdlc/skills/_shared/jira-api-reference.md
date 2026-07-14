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
[6. People fields — assignee and reporter](#6-people-fields--assignee-and-reporter) ·
[7. Bulk field updates across a project](#7-bulk-field-updates-across-a-project) ·
[8. Gotchas](#8-gotchas)

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

## 6. People fields — `assignee` and `reporter`

`acli` can set an **assignee** (`workitem create/assign/edit --assignee`) but
has **no `--reporter` flag on any subcommand** — `workitem edit --reporter`
errors with `unknown flag`. Reporter is REST-only, which is the main reason a
skill would come here at all.

The two fields differ in a way worth knowing before you plan a change:

| field | mutable? | notes |
|---|---|---|
| `assignee` | yes | who *works* it. `acli` can do this — prefer it. |
| `reporter` | yes, **with permission** | who *filed* it. Needs the project's **Modify Reporter** permission (admin-level by default). |
| `creator` | **never** | set by Jira from the authenticated caller at create time. No API can change it, ever. |

**`creator` and `reporter` are set from whoever authenticates on create** — so
the ordinary way to get them right is simply to *be the right account*
(`jira_acli_login.sh assigner`, per
[`project-config.md`](project-config.md)); no field-setting needed. Reach for
the REST writes below only to **retrofit existing issues**.

### Check it's writable before you try

`editmeta` reports exactly which fields this account may set on this issue.
Do this first — it turns a permission problem into an answer instead of a
failed write:

```bash
api "$BASE/issue/<KEY>/editmeta" | jq '.fields | keys'          # what I may edit
api "$BASE/issue/<KEY>/editmeta" | jq '.fields.reporter.operations'
```

```json
// → ["set"]   ⇒ Modify Reporter is granted; the PUT below will work.
// reporter absent from .fields entirely ⇒ not permitted. Stop; ask an admin.
```

### Set them (both in one PUT)

People fields take an **`accountId`**, not an email. Resolve it first:

```bash
# email → accountId
api --get --data-urlencode "query=<EMAIL>" "$BASE/user/search" | jq -r '.[0].accountId'
# → "712020:65b369e4-8308-4edc-9899-6629aeab35e0"
```

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -X PUT \
  -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" -H 'Content-Type: application/json' \
  --data '{"fields":{
             "assignee": {"accountId":"<EXECUTOR_ACCOUNT_ID>"},
             "reporter": {"accountId":"<ASSIGNER_ACCOUNT_ID>"}
          }}' \
  "$BASE/issue/<KEY>"
# → 204, empty body. Success is the status code; there is nothing to parse.
```

## 7. Bulk field updates across a project

Retrofitting a whole project (e.g. making every existing issue look as if the
per-role identities had always been in place) is a loop of the §6 PUT. The
shape below is the one that matters — **collect keys → write → verify from the
server**.

### Collect the keys — paginate, and don't trust `acli` here

`acli jira workitem search --fields 'key'` returns entries whose `key` is
**`null`** — a key list built from it comes back empty, and a loop over it
silently does nothing. Use REST search, which pages with `nextPageToken`
(*not* `startAt` — that's the old `/search` endpoint):

```bash
next=""; : > keys.txt
while :; do
  resp=$(api --get \
    --data-urlencode 'jql=project = <PROJECT-KEY> ORDER BY key ASC' \
    --data-urlencode 'maxResults=100' --data-urlencode 'fields=key' \
    ${next:+--data-urlencode "nextPageToken=$next"} \
    "$BASE/search/jql")
  jq -r '.issues[].key' <<<"$resp" >> keys.txt
  next=$(jq -r '.nextPageToken // empty' <<<"$resp")
  [ -z "$next" ] && break
done
wc -l < keys.txt      # sanity-check the count BEFORE writing anything
```

### Write, counting failures rather than aborting

```bash
ok=0; fail=0
while read -r K; do
  code=$(curl -sS -o /tmp/err -w '%{http_code}' -X PUT \
    -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" -H 'Content-Type: application/json' \
    --data "{\"fields\":{\"assignee\":{\"accountId\":\"$EXE_ID\"},
                         \"reporter\":{\"accountId\":\"$ASG_ID\"}}}" \
    "$BASE/issue/$K")
  if [ "$code" = 204 ]; then ok=$((ok+1))
  else fail=$((fail+1)); echo "$K HTTP$code $(cat /tmp/err)" >&2; fi
done < keys.txt
echo "updated: $ok   failed: $fail"
```

A partial failure is normal (one issue in a screen you can't edit) and
shouldn't abort the other 78 — so count and report rather than `set -e`.

### Verify from the server, not from the exit codes

A `204` means the request was accepted, not that the project now looks how you
think. Re-read the whole project and assert:

```bash
# re-run the paginated search with fields=assignee,reporter, then:
awk -F'\t' '$2!="<EXPECTED_ASSIGNEE>" || $3!="<EXPECTED_REPORTER>"' verify.txt
# nothing printed ⇒ every issue conforms. This is the only real proof.
```

⚠️ **Dry-run first on one issue.** Prove the exact PUT body on a single key
and re-read it, *then* loop. And these writes are **not undoable in bulk** —
Jira keeps a per-issue changelog, but there is no "revert the last 79 edits"
button. Capture the before-state (the same paginated read) if you might need
to reconstruct it.

## 8. Gotchas

- **`401 Unauthorized; scope does not match`** — the token authenticated but
  lacks a scope the endpoint requires. Not a credential problem; see §5.
- **`401` from `/oauth/token/accessible-resources`** — that endpoint is for
  **OAuth 3LO access tokens** and rejects API tokens, whichever kind. It is
  *not* evidence that the gateway is broken or that your token is bad — it's
  the wrong endpoint. Resolve the cloud id from `_edge/tenant_info` (§1),
  which needs no auth at all.
- **`acli` search returns `null` keys with `--fields 'key'`** — see §7. Build
  key lists from REST search, not from `acli`.
- **People fields need `accountId`, not email** — `{"assignee":{"accountId":…}}`.
  An email in that field is rejected. Resolve via `$BASE/user/search` (§6).
- **`creator` cannot be changed** — by any API, ever (§6). If it's wrong, the
  only fix is to have created the issue as the right account. `reporter` is
  the mutable one.
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
