# Granular scopes for a scoped Jira API token

**Question this answers:** `jira.sh` / `jira.ps1` are documented against a
**classic** token, or a **scoped** token carrying the three *coarse* scopes
(`read:jira-user`, `read:jira-work`, `write:jira-work`). If you'd rather issue a
scoped token with **granular** per-resource scopes, which ones must you tick?

**Short answer:** the 29 in [§3](#3-the-set-to-select--29-scopes). Read
[§5](#5-caveats) before you commit to this path — granular is strictly more
fragile than the coarse trio, and the failure mode impersonates a bad token.

Related: [`jira-api-reference.md`](../../skills/_shared/jira-api-reference.md) §5
(token types) · [`rest-client-design.md`](../rest-client-design.md) ·
[`acli-to-rest-api-migration.md`](../acli-to-rest-api-migration.md) ·
[`granular-scopes.json`](granular-scopes.json) (the full picker list, for diffing)

---

## 1. How this list was derived

Not from the HTML reference pages — they truncate. From Atlassian's own OpenAPI
spec, where every operation carries `x-atlassian-oauth2-scopes` with two states:

| `state` | meaning |
|---|---|
| `Current` | the **classic / coarse** scope (`read:jira-work`, …) |
| `Beta` | the **granular** per-resource scopes |

```bash
curl -sSL -o swagger.json https://developer.atlassian.com/cloud/jira/platform/swagger-v3.v3.json
jq -c '.paths["/rest/api/3/myself"].get["x-atlassian-oauth2-scopes"]' swagger.json
# [{"scheme":"OAuth2","scopes":["read:jira-user"],"state":"Current"},
#  {"scheme":"OAuth2","scopes":["read:application-role:jira","read:group:jira",
#                               "read:user:jira","read:avatar:jira"],"state":"Beta"}]
```

Every scope in §3 was confirmed to exist in
[`granular-scopes.json`](granular-scopes.json) (the token-creation picker list),
so all 29 are actually selectable — the union diffs empty against that file.

## 2. What the client actually calls

The full endpoint surface of `_shared/scripts/posix/jira.sh` (and its
`win/jira.ps1` twin), command by command:

| command | call | granular scopes required |
|---|---|---|
| *(cloud-id resolve)* | `GET https://<site>/_edge/tenant_info` | **none** — unauthenticated |
| `whoami` | `GET /myself` | `read:application-role:jira` `read:group:jira` `read:user:jira` `read:avatar:jira` |
| `project exists` | `GET /project/search` | `read:project:jira` `read:project.property:jira` `read:project-category:jira` `read:project-version:jira` `read:project.component:jira` `read:issue-type:jira` `read:issue-type-hierarchy:jira` `read:user:jira` `read:application-role:jira` `read:avatar:jira` `read:group:jira` |
| `issue view` | `GET /issue/<KEY>` | `read:issue:jira` `read:issue-meta:jira` `read:issue-security-level:jira` `read:issue.vote:jira` `read:issue.changelog:jira` `read:status:jira` `read:field-configuration:jira` `read:user:jira` `read:avatar:jira` |
| `issue create` | `POST /issue` | `write:issue:jira` `write:comment:jira` `write:comment.property:jira` `write:attachment:jira` `read:issue:jira` |
| `issue transition` | `GET /issue/<KEY>/transitions` | `read:issue.transition:jira` `read:status:jira` `read:field-configuration:jira` |
| " | `POST /issue/<KEY>/transitions` | `write:issue:jira` `write:issue.property:jira` |
| `issue assign`, `issue create --assignee` | `GET /user/search` | `read:user:jira` `read:user.property:jira` `read:application-role:jira` `read:avatar:jira` `read:group:jira` |
| " | `PUT /issue/<KEY>/assignee` | `write:issue:jira` |
| `issue comment add` | `POST /issue/<KEY>/comment` | `write:comment:jira` `read:comment:jira` `read:comment.property:jira` `read:project:jira` `read:project-role:jira` `read:group:jira` `read:user:jira` `read:avatar:jira` |
| `issue comment list` | `GET /issue/<KEY>/comment` | as above, minus `write:comment:jira` |
| `issue delete` | `DELETE /issue/<KEY>` | `delete:issue:jira` |

`--assignee @me` short-circuits `GET /user/search` to `GET /myself`, so it needs
no scope the table doesn't already list.

## 3. The set to select — 29 scopes

Everything `jira.sh` can do:

```
delete:issue:jira
read:application-role:jira
read:avatar:jira
read:comment:jira
read:comment.property:jira
read:field-configuration:jira
read:group:jira
read:issue:jira
read:issue-meta:jira
read:issue-security-level:jira
read:issue-type:jira
read:issue-type-hierarchy:jira
read:issue.changelog:jira
read:issue.transition:jira
read:issue.vote:jira
read:project:jira
read:project-category:jira
read:project-role:jira
read:project-version:jira
read:project.component:jira
read:project.property:jira
read:status:jira
read:user:jira
read:user.property:jira
write:attachment:jira
write:comment:jira
write:comment.property:jira
write:issue:jira
write:issue.property:jira
```

## 4. Trimming it

- **Read-only token** — enough for `statuscheck.sh`'s live probe
  (`jira.sh whoami`, `jira.sh project exists`) plus `issue view`. 18 scopes: the
  `read:*` list above minus `read:comment:jira`, `read:comment.property:jira`,
  `read:project-role:jira`, `read:issue.transition:jira`, `read:user.property:jira`.
- **Drop `delete:issue:jira`** unless you actually run `issue delete` — no normal
  skill flow does; it exists for cleanup and for `jira.test.sh`.
- **`raw` is an escape hatch**, so it needs whatever the call you make needs.
  Two likely ones, beyond the 29:
  | raw call | adds |
  |---|---|
  | `POST /search/jql` | `read:issue-details:jira` `read:field:jira` `read:field.default-value:jira` `read:field.option:jira` `read:group:jira` |
  | `POST /issue/<KEY>/attachments` | `read:attachment:jira` (its `write:attachment:jira`, `read:user:jira`, `read:avatar:jira` are already in the 29) |
  | `PUT /issue/<KEY>` (edit / reporter) | nothing — `write:issue:jira`, already in the 29 |

## 5. Caveats

1. **Granular is all-or-nothing per endpoint.** `GET /issue` alone needs nine
   scopes simultaneously; any missing member fails the whole call with
   `401 {"message":"Unauthorized; scope does not match"}`. That is why
   [`jira-api-reference.md`](../../skills/_shared/jira-api-reference.md) §5 steers
   you to the coarse trio — §3 here is that complete bundle, which is what makes
   granular viable at all.
2. **A scope gap looks exactly like a stale token.** `_request` maps every 401 to
   `EX_AUTH` with *"unauthorized — token stale/invalid for role '<role>'"*. Before
   regenerating a token that just 401'd, check the body:
   ```bash
   bash .../jira.sh --role executor raw GET /myself | jq .message
   ```
   `scope does not match` → add the missing scope; anything else → credential.
3. **Granular scopes are `state: "Beta"`.** Atlassian can add a required scope to
   an endpoint's bundle, so a token that works today can start returning 401
   without anything on your side changing. The coarse trio is `state: "Current"`
   and stable — that difference, not the scope count, is the real trade.
4. **Gateway host only.** Scoped tokens of either kind authenticate against
   `https://api.atlassian.com/ex/jira/<cloudId>/rest/api/3` — which is what
   `jira.sh` builds — never the site domain, which answers
   `401 AUTHENTICATED_FAILED`. See `acli-to-rest-api-migration.md` §0.

## 6. Sources

- [Jira Cloud platform REST v3 API](https://developer.atlassian.com/cloud/jira/platform/rest/v3/)
- [swagger-v3.v3.json](https://developer.atlassian.com/cloud/jira/platform/swagger-v3.v3.json) — authoritative for §2's per-endpoint lists
- [Jira scopes for OAuth 2.0 (3LO) and Forge apps](https://developer.atlassian.com/cloud/jira/platform/scopes-for-oauth-2-3LO-and-forge-apps/)
