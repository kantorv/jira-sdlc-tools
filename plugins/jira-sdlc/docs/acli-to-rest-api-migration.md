# acli → REST API migration

A one-stop map from every `acli` call this toolkit invokes to a plain
`curl` call against the **Jira Cloud REST API v3**, so a skill (or a
GitHub Actions runner, or anyone without `acli` installed) can do the same
work with nothing but `curl` + `jq`.

This is the *bridge* doc. The two references it sits between:

- [`../skills/_shared/jira-acli-reference.md`](../skills/_shared/jira-acli-reference.md)
  — the lean `acli` call surface the skills use today (the **from** side).
- [`../skills/_shared/jira-api-reference.md`](../skills/_shared/jira-api-reference.md)
  — the verified REST call shapes: cloud-id resolution, the auth helper,
  token types/scopes, people fields, bulk updates (the **to** side).
  This migration doc does **not** restate those; it references them and
  fills the gap — the *per-acli-command* mapping and the behavioural
  differences you hit when you swap one for the other.

**Every `curl` below was run against a live Jira Cloud instance
(`coolapp-dev.atlassian.net`) on 2026-07-24**, through the
`api.atlassian.com` gateway with an API token, and the observed HTTP
status is recorded in each section and in the summary table.

---

## 0. The two constants: host + auth

Set these once; every call below assumes them. This is the §0–§2 setup from
[`jira-api-reference.md`](../skills/_shared/jira-api-reference.md) condensed —
read that for the *why* (scoped vs. classic tokens, why the gateway and not
the site domain).

```bash
# from jira-sdlc-tools.local.env
SITE="${JIRA_ACCOUNT_URL#*://}"                       # strip any scheme
CLOUD_ID=$(curl -fsSL "https://$SITE/_edge/tenant_info" | jq -r '.cloudId')
BASE="https://api.atlassian.com/ex/jira/$CLOUD_ID/rest/api/3"

# Basic auth on every call. Per-role: pass that role's email:token pair.
api() { curl -sSfL -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" -H "Accept: application/json" "$@"; }
```

- **Host = the gateway** `https://api.atlassian.com/ex/jira/<CLOUD_ID>`, not
  the site domain — it accepts both classic and scoped tokens.
- **Auth = Basic** `-u email:token` per request. Not Bearer (that's OAuth 3LO).
- Cloud id comes from `_edge/tenant_info` (no auth needed).

---

## 1. What migrating *away from acli* deletes entirely

The single biggest change isn't any one command — it's that **REST auth is
per-request, so there is no stored credential and no global auth state**.
That erases a whole machinery the skills carry today (see
`jira-acli-reference.md` §0 and `jira_acli_login.sh`):

| acli behaviour (gone under REST) | Why it existed | REST replacement |
|---|---|---|
| `acli jira auth login` storing a credential | acli caches one credential in `~/.config/acli/jira_config.yaml` | Nothing to store — pass `-u email:token` on each call |
| **logout-before-login** dance | a 2nd `login` won't overwrite a stale credential | N/A — no stored credential to go stale |
| `acli jira auth status` as a probe (~20s, cache-backed) | "am I logged in as X?" | `GET $BASE/myself` → `.accountId` / `.emailAddress` (one fast authenticated call, no cache) |
| reading `jira_config.yaml` for the active `account_id` | avoid the 20s status call | not needed — you already hold the token you're using |
| **machine-global single-account race** — last login wins in every shell | acli stores exactly one active account | **gone**: each call carries its own `-u`, so assigner / executor / reviewer run concurrently with no interference |

That last row is the JST-146 concern (see the acli multi-profile race note):
per-request auth removes the shared mutable `current_profile` that made
concurrent role sessions race, and removes the fragile YAML-parsing in
`check_assignee.sh` used to discover "who am I". Under REST, "who am I" is
just `GET /myself` with the token in hand.

**Verification analogue for a role login** — instead of `login` + `auth
status`, confirm the token authenticates as the expected identity:

```bash
api "$BASE/myself" | jq -r '{accountId, displayName, emailAddress}'   # → 200
```
Observed: the three role tokens → `200` with the matching identity; the
stale legacy `JIRA_TOKEN` → `401`.

---

## 2. Command-by-command map (summary)

Every distinct `acli` call the skills / `_shared/scripts` invoke, and its
verified REST analogue. Sub-sections below give the full curl for each.

| # | `acli` call | REST analogue | Method + path | Verified |
|---|---|---|---|---|
| 3.1 | `auth login` / `logout` / `auth status` | per-request Basic; identity check | `GET /myself` | `200` / `401` |
| 3.2 | `project list --paginate --json` | project search | `GET /project/search?query=<KEY>` | `200` |
| 3.3 | `workitem view <KEY> --json --fields '…'` | get issue | `GET /issue/<KEY>?fields=…` | `200` |
| 3.4 | `workitem create …` (top-level) | create issue | `POST /issue` | `201` |
| 3.4 | `workitem create --parent …` (sub-task) | create issue w/ `fields.parent` | `POST /issue` | `201` |
| 3.4 | `workitem create --assignee …` | create issue w/ `fields.assignee` | `POST /issue` | `201` |
| 3.5 | `workitem comment create --key --body[-file]` | add comment | `POST /issue/<KEY>/comment` | `201` |
| 3.6 | `workitem comment list --key --json` | get comments | `GET /issue/<KEY>/comment` | `200` |
| 3.7 | `workitem assign --key --assignee <email>` | resolve email → set assignee | `GET /user/search` + `PUT /issue/<KEY>/assignee` | `200` + `204` |
| 3.7 | `workitem assign --remove-assignee` | clear assignee | `PUT /issue/<KEY>/assignee` `{"accountId":null}` | `204` |
| 3.8 | `workitem transition --key --status <name>` | resolve name → id, then post | `GET /issue/<KEY>/transitions` + `POST …/transitions` | `204` |
| 3.9 | `workitem delete --key --yes` | delete issue | `DELETE /issue/<KEY>` | `204` |

Reference-only `acli` commands **no skill invokes** — `workitem
search --jql`, `workitem edit`, `workitem link *`, `workitem worklog add`,
`comment update`/`delete`/`visibility`, `board`/`sprint`/`field`/`filter
list` — are out of scope here. `search` (`POST /search/jql` with
`nextPageToken` paging) and `edit`/reporter (`PUT /issue/<KEY>`) are already
covered in [`jira-api-reference.md`](../skills/_shared/jira-api-reference.md)
§7 and §6.

---

## 3. The calls

Two nuances recur, so they're stated once here and referenced below:

> **N1 — ADF, not plain text.** REST v3 requires the `description` and
> comment `body` fields to be an **Atlassian Document Format** object.
> A plain string is rejected:
> ```
> POST /issue  {"fields":{…,"description":"plain string"}}
> → 400 {"errors":{"description":"The field value is not valid Atlassian Document Format (ADF) content."}}
> ```
> `acli` accepted plain text *or* ADF and wrapped plain text for you; over
> REST you must send ADF yourself. §3.10 has a `jq` one-liner that turns a
> plain-text file into ADF.

> **N2 — accountId, not email.** People fields (`assignee`, `reporter`)
> take an opaque `accountId`, never an email. `acli`'s
> `--assignee <email>` resolved it implicitly; over REST add one
> `GET /user/search` lookup (§3.7).

### 3.1 Auth — see §1

No REST command *is* login. Replace login+status verification with
`GET /myself` (§1). Everything else in this section carries the token via
`api()` (`-u email:token`).

### 3.2 Project list / access check

`acli jira workitem`'s healthcheck greps `project list --paginate --json`
for `<PROJECT-KEY>` to prove the account can see the project. The pagination
flag `acli` *requires* has no analogue — REST paginates by default. Query by
key:

```bash
api "$BASE/project/search?query=<PROJECT-KEY>" | jq -e '.values[].key | select(. == "<PROJECT-KEY>")'
# → prints the key and exits 0 if visible; empty + exit 1 if not.   HTTP 200
```

### 3.3 View an issue with a field list

```bash
# executor fetch-with-comments (jira-acli-reference §3):
api "$BASE/issue/<KEY>?fields=summary,description,issuetype,status,parent,subtasks,comment"
# reviewer review-fetch (no comments):
api "$BASE/issue/<KEY>?fields=summary,description,issuetype,status,parent,subtasks"
```
`HTTP 200`. Same canonical field lists as `acli --fields`; pass them
comma-joined in the `fields` query param. Notes:
- The `acli` positional-key-vs-`--key` inconsistency is **gone** — REST is
  always `/issue/<KEY>`.
- `subtasks` returns `[{"key":…,"fields":{"summary":…}}]`; `parent` and
  `comment` appear only when present — identical to the `acli` shape the
  skills already parse, so `jq` paths (`.fields.parent.key`,
  `.fields.subtasks[].key`, `.fields.comment.comments[]`) are unchanged.
- **Comparing an assignee?** Same rule as `acli` (§3 there): compare
  `.fields.assignee.accountId` (always present), never `emailAddress`
  (present only when the issue is assigned to *you*). Get "my" accountId
  from `GET /myself` instead of the `jira_config.yaml` read.

### 3.4 Create an issue

Top-level, with an ADF description and an assignee (N1, N2):

```bash
curl -sS -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/issue" --data '{
    "fields": {
      "project":   {"key": "<PROJECT-KEY>"},
      "issuetype": {"name": "Task"},
      "summary":   "Your summary",
      "assignee":  {"accountId": "<ASSIGNEE_ACCOUNT_ID>"},
      "description": {"type":"doc","version":1,"content":[
        {"type":"paragraph","content":[{"type":"text","text":"Your description."}]}
      ]}
    }}'
# → 201  {"id":"…","key":"<PROJECT-KEY>-N", "self":"…"}
```

Capture the new key from `.key` in the `201` body — the analogue of
grepping `acli`'s "✓ Work item … created" line.

**Sub-task**: same call, `"issuetype":{"name":"Subtask"}` plus
`"parent":{"key":"<PARENT-KEY>"}`. This is the direct analogue of `acli
--parent`, and — unlike `jira-cli`, which silently drops the parent
(jira-acli-reference §2) — the REST `fields.parent.key` is honoured
(`201`, sub-task shows under the parent's `subtasks`). So the original
reason `acli` was preferred over `jira-cli` for sub-tasks doesn't reappear
under REST.

- `assignee` / `parent` are optional — omit to leave unassigned / top-level.
- `creator` and `reporter` are set from the **authenticated caller** at
  create time (same as `acli`) — so create as the right role and they're
  correct for free. `creator` can never be changed after; `reporter` is
  `PUT /issue/<KEY>` with Modify Reporter permission
  ([`jira-api-reference.md`](../skills/_shared/jira-api-reference.md) §6).

### 3.5 Add a comment

ADF body (N1). Analogue of both `--body` and `--body-file` — build the ADF
however you like (§3.10 for a text file):

```bash
curl -sS -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/issue/<KEY>/comment" --data '{
    "body": {"type":"doc","version":1,"content":[
      {"type":"paragraph","content":[{"type":"text","text":"PR target branch: development."}]}
    ]}}'
# → 201  {"id":"…","author":{…}, …}
```

The `--body-file -`/stdin breakage and the backtick-in-quoted-`--body`
shell hazard (jira-acli-reference §6) both **vanish** — the body is JSON in
`--data`, not a shell-parsed string, and text goes in via `--data @file`.
The machine-recoverable markers (`PR target branch: …`, `Task memory
(jira-task-executor)`) are just text inside the ADF `text` node, so the
grep-them-back workflow is unchanged.

### 3.6 List comments

```bash
api "$BASE/issue/<KEY>/comment" | jq -r '.comments[].body.content[].content[]?.text // empty'
# → 200
```
`.comments[]` is the array (the `acli --json` analogue). To grep a marker
line, walk the ADF text nodes as above — the marker sits in a `text` node,
not at the top level as it did in `acli`'s plainer JSON.

### 3.7 Assign / unassign

`acli --assignee <email>` becomes a two-step: resolve email → accountId
(N2), then `PUT` the assignee. `acli --assignee '@me'` → use your own
`GET /myself` accountId.

```bash
ACCOUNT_ID=$(api --get --data-urlencode "query=<EMAIL>" "$BASE/user/search" | jq -r '.[0].accountId')  # 200
curl -sS -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" -H "Content-Type: application/json" \
  -X PUT "$BASE/issue/<KEY>/assignee" --data "{\"accountId\":\"$ACCOUNT_ID\"}"                          # 204, empty body
```

Unassign (`acli --remove-assignee`):

```bash
curl -sS -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" -H "Content-Type: application/json" \
  -X PUT "$BASE/issue/<KEY>/assignee" --data '{"accountId":null}'                                       # 204
```

`204` with an empty body = success; there's nothing to parse. (Assignee can
also be set inline on create, §3.4, or via `PUT /issue/<KEY>`.)

### 3.8 Transition by status name

Two calls, because REST transitions by **id**, and the available ids depend
on the *current* status — never hard-code them. This is the exact flow in
[`jira-api-reference.md`](../skills/_shared/jira-api-reference.md) §4:

```bash
TID=$(api "$BASE/issue/<KEY>/transitions" \
  | jq -r --arg t "<STATUS_IN_PROGRESS>" 'first(.transitions[]|select(.to.name==$t)|.id)//empty')  # 200
# empty TID ⇒ no transition to that status from the current one — stop, don't guess.
curl -sS -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" -H "Content-Type: application/json" \
  -X POST "$BASE/issue/<KEY>/transitions" --data "{\"transition\":{\"id\":\"$TID\"}}"              # 204
```
Match on `.to.name` (destination status), **not** `.name` (the transition's
own label). `acli --yes` (skip the confirm prompt) has no analogue — REST
POST is already non-interactive. Verified round-trip: `To Do` → id 21 →
`In Progress`, `204`.

### 3.9 Delete (destructive — same guardrail as acli)

```bash
curl -sS -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" -X DELETE "$BASE/issue/<KEY>"        # 204
```
The `jira-acli-reference.md` §8 agent rule carries over unchanged: **never
delete unless the user asked for that exact key in this message.** To delete
a parent that still has sub-tasks, either delete the sub-tasks first (as
verified here) or add `?deleteSubtasks=true`.

### 3.10 Helper — plain-text file → ADF (covers N1 for §3.4 and §3.5)

`acli` let you point `--description-file` / `--body-file` at a plain-text
file. The REST analogue: turn each non-empty line into an ADF paragraph
with `jq`, then post the object with `--data @file`.

```bash
# BODY_TXT holds the caller's plain text; ADF is a private temp we build + post + remove.
# mktemp gives a unique path so parallel runs (multiple sub-tasks in flight) never
# clobber a shared /tmp/adf.json.
ADF=$(mktemp "${TMPDIR:-/tmp}/jira-adf.XXXXXX.json"); trap 'rm -f "$ADF"' EXIT
jq -Rs '{body:{type:"doc",version:1,content:[
          splits("\n") | select(length>0) | {type:"paragraph",content:[{type:"text",text:.}]}
       ]}}' "$BODY_TXT" > "$ADF"
curl -sS -u "$JIRA_ACCOUNT_EMAIL:$JIRA_TOKEN" \
  -H "Accept: application/json" -H "Content-Type: application/json" \
  -X POST "$BASE/issue/<KEY>/comment" --data @"$ADF"                               # 201
```
For a `description`, replace the outer key `body` with `description` and nest
it under `{"fields": …}` for the create/edit call. This is a **lossless
plain-text** conversion (paragraphs only) — it does *not* render markdown
(`##`, `-`, `1.` stay literal), exactly like `acli`'s plain-text handling.
Rich structure (headings, lists, code blocks) needs richer ADF nodes;
that's a deliberate authoring step, not an automatic markdown conversion.

---

## 4. Status-code cheat sheet (all observed live)

| Operation | Success | Notable failure |
|---|---|---|
| `GET /myself` | `200` | `401` — bad/stale/revoked token (the legacy `JIRA_TOKEN` returns this) |
| `GET /project/search`, `GET /issue`, `GET …/transitions`, `GET …/comment`, `GET /user/search` | `200` | `404` on an issue can mean **no permission**, not a typo (Jira masks 403 as 404) |
| `POST /issue`, `POST …/comment` | `201` | `400` — most often non-ADF body (N1) or an unknown `issuetype`/field |
| `PUT …/assignee`, `POST …/transitions`, `DELETE /issue` | `204` (empty body) | `400` invalid transition id / `403` permission |
| scoped-token call on the **site domain** instead of the gateway | — | `401 AUTHENTICATED_FAILED` — switch to the gateway (§0) |
| scoped token missing a scope | — | `401 "scope does not match"` — not a credential problem ([`jira-api-reference.md`](../skills/_shared/jira-api-reference.md) §5) |

Success on the write calls (`204`) has **no body** — confirm by re-reading
(`GET /issue/<KEY>?fields=status`), never by parsing the response.
