# Design: a bash Jira REST client (`jira.sh`)

A design for a small, extensible shell client that replaces the toolkit's
`acli` usage with direct calls to the Jira Cloud REST API v3. This is a
**design doc, not an implementation** — it fixes the shape before any code
is written, because in bash a wrong shape shows up as error-handling
smeared across every call site, and here there's a second hard constraint
most shell tools don't carry (see [§1](#1-the-governing-constraints)).

Precursors this builds on — read them first:
- [`acli-to-rest-api-migration.md`](acli-to-rest-api-migration.md) — the
  per-command `acli`→REST map, live-verified. **This client is that map,
  packaged.** Every operation here corresponds to a row of its §2 table.
- [`../skills/_shared/jira-api-reference.md`](../skills/_shared/jira-api-reference.md)
  — verified REST call shapes (gateway host, cloud-id resolution, Basic
  auth, token scopes, people fields). The client *implements* these; it
  doesn't reinvent them.

---

## 1. The governing constraints

Four facts drive every decision below. When a choice is made, it traces to
one of these.

1. **Every script ships as a bash↔PowerShell contract pair.** The
   `_shared/scripts/posix/*.sh` originals each have a `win/*.ps1` twin with
   identical args, output, and exit codes (AGENTS.md, "Its `win/*.ps1` twin
   must stay in sync"). Consequence: **the smaller and more regular the
   surface, the cheaper the twin.** This is the single strongest argument
   for the choices in §2.
2. **Script deterministic transport, not judgment** (AGENTS.md, "If it can
   be scripted…"). The client owns CRUD, auth, and error mapping. It must
   *not* own skill decisions (PR-base resolution, which role a skill uses,
   the assignee-ownership gate). Those stay in skill prose, where the model
   can reason outside the enumerated cases.
3. **REST auth is per-request Basic** (migration doc §0–§1). There is no
   login, no stored credential, no global auth state. "Role" degrades to
   "which `email:token` pair does this one call use." The entire
   `jira_acli_login` / `auth status` / `jira_config.yaml` machinery
   (migration doc §1) does not carry over — the client has no state to
   manage.
4. **Composable output.** Read operations emit the raw JSON body on stdout
   so the caller (`jq`, or the model) extracts what it needs; the client
   does not pre-digest. Write operations return status through the **exit
   code**, which in bash is the only structured return channel.

---

## 2. Architecture — four layers

Each layer depends only on the one below it. The payoff: **layers 1–2 are
written once and never change; all extension happens in layer 3.**

```
┌─ Layer 4  CLI dispatcher    — arg parsing, subcommand routing, --help, usage errors
├─ Layer 3  typed operations  — issue_view / issue_create / transition_to / …   ← extend HERE
├─ Layer 2  transport core    — _request(): url + auth + curl + status→exit-code   ← the choke point
└─ Layer 1  config resolver   — env files, role→cred, cloud-id (cached), ADF encode, email→accountId
```

Governing rule: **layers 1–2 know nothing about Jira operations, and layer
3 knows nothing about `curl`.** A new endpoint is a ~6-line layer-3
function plus one `case` arm in layer 4 — no transport edits, so no risk to
existing calls, and only the parts that changed need re-mirroring to pwsh.

Why a **single dispatcher** rather than today's one-script-per-operation
pattern (`check_assignee.sh`, `get_assignee_email.sh`, …): under constraint
#1, every new script *doubles* (bash + pwsh). One dispatcher means the
whole client is **one pair** to keep in sync, and new operations are arms
inside it, not new files.

Why a dispatcher rather than a **sourceable library**
(`source jira_api.sh; jira_issue_view …`): (a) dot-sourcing semantics
differ between bash and pwsh, making the twin harder; (b) a process
boundary gives one clean stdout/exit-code contract to mirror; (c) it
matches the existing dispatch rule already used across the toolkit
(`bash …/X.sh` on POSIX ↔ `pwsh/powershell …/win/X.ps1` on Windows). So:
**dispatcher is the public interface; sourcing is not.**

---

## 3. Layer 2 — the single HTTP choke point

The most important function. In a low-level language you want **exactly one
place** that touches `curl`, captures both response body and HTTP status,
and maps status → a meaningful exit code. Everything else calls it.

```bash
# _request METHOD PATH [JSON_BODY]
#   body (if any) → $RESP_FILE, which the op layer cats to stdout.
#   returns a *semantic* exit code (see §6), not curl's raw one.
_request() {
  local method=$1 path=$2 body=${3-}
  local -a c=(curl -sS -u "$_CRED" -H "Accept: application/json"
              -X "$method" -o "$RESP_FILE" -w '%{http_code}')
  [ -n "$body" ] && c+=(-H "Content-Type: application/json" --data "$body")
  local code
  code=$("${c[@]}" "$_BASE$path") || { echo "jira: transport error (curl failed)" >&2; return 1; }
  case "$code" in
    2??) return 0 ;;
    400) _fail 5 "$code" "validation — bad body / unknown field or issue type" ;;
    401) _fail 3 "$code" "unauthorized — token stale/invalid for this role" ;;
    403) _fail 6 "$code" "forbidden — permission" ;;
    404) _fail 4 "$code" "not found (or no permission — Jira masks 403 as 404)" ;;
    *)   _fail 7 "$code" "unexpected status" ;;
  esac
}

# human-readable message → stderr; machine body stays in $RESP_FILE untouched.
_fail() {
  echo "jira: HTTP $2 — $3: $(jq -rc '.errors // .errorMessages // .message // empty' "$RESP_FILE" 2>/dev/null)" >&2
  return "$1"
}
```

Why the exit-code discipline matters **in bash specifically**: the exit
code is the only structured return channel a subprocess has. Distinct codes
(3=auth, 4=missing, 5=validation, …) let a skill branch — "was that issue
*not found* or *not permitted*?" — without scraping stderr. This is the
shell analogue of typed exceptions, and it is the reason all HTTP handling
must funnel through one function: scatter it and the codes drift.

---

## 4. Layer 3 — typed operations (thin wrappers)

Each is short because the core does the work. Two of them
(`transition_to`, `assign`) deliberately hide *multi-step* REST behind a
name-based interface, so the caller never juggles transition ids or
accountIds — the determinism AGENTS.md wants scripted.

```bash
issue_view()   { _request GET "/issue/$1?fields=$2"; cat "$RESP_FILE"; }
issue_create() { _request POST "/issue" "$1"; jq -r '.key' "$RESP_FILE"; }   # $1 = prebuilt JSON (see §7 ADF)
comment_add()  { _request POST "/issue/$1/comment" "$2"; }                   # $2 = ADF {"body":…}
comment_list() { _request GET  "/issue/$1/comment"; cat "$RESP_FILE"; }
issue_delete() { _request DELETE "/issue/$1"; }

# name→id resolved internally, current-status-dependent, never hard-coded (migration doc §3.8)
transition_to() {
  _request GET "/issue/$1/transitions" || return
  local tid; tid=$(jq -r --arg t "$2" 'first(.transitions[]|select(.to.name==$t)|.id)//empty' "$RESP_FILE")
  [ -n "$tid" ] || { echo "jira: no transition to '$2' from current status" >&2; return 8; }
  _request POST "/issue/$1/transitions" "{\"transition\":{\"id\":\"$tid\"}}"
}

# email → accountId resolved internally (migration doc §3.7 N2); '@me' → whoami
assign() {   # assign KEY <email|@me>   |   assign KEY --remove
  local acct
  case "$2" in
    --remove) acct=null ;;
    @me)      _request GET "/myself"; acct="\"$(jq -r .accountId "$RESP_FILE")\"" ;;
    *)        acct="\"$(_account_id_for "$2")\"" ;;   # /user/search helper, layer 1
  esac
  _request PUT "/issue/$1/assignee" "{\"accountId\":$acct}"
}
```

---

## 5. Layer 4 — dispatcher surface, and the `raw` escape hatch

```
jira.sh whoami
jira.sh project exists   <KEY>
jira.sh issue view       <KEY> [--fields a,b,c]
jira.sh issue create     --project K --type Task --summary S
                         [--parent K] [--assignee email|@me] [--desc-file f | --adf-file f]
jira.sh issue transition <KEY> --to "In Review"
jira.sh issue assign     <KEY> (--to email|@me | --remove)
jira.sh issue comment add  <KEY> (--body-file f | --adf-file f)
jira.sh issue comment list <KEY>
jira.sh issue delete     <KEY>
jira.sh raw <METHOD> </PATH> [--data-file f]             ← extensibility valve (PATH under /rest/api/3, e.g. /myself)
```

Global option resolved once in layer 1: `--role executor|assigner|reviewer`
(or `$JIRA_ROLE`; default the `JIRA_ACCOUNT_*` pair) → sets `$_CRED`. That
flag is the **entire** replacement for `acli`'s login/logout/`auth status`
dance (constraint #3).

**`raw` is what makes "extended in future" real.** Any endpoint not yet
wrapped works *today* — it just hands `_request` a caller-supplied method
and path. So the client is never a bottleneck for a new need. When a `raw`
usage proves recurring, promote it to a named subcommand: one `case` arm +
one layer-3 function. Named operations thus accrete only for calls that earn
a name (a stable interface, internal multi-step logic, or a
plain-text/ADF/accountId convenience), and everything else rides `raw`.

This is the direct analogue of the AGENTS.md guidance "script the stable
deterministic parts; leave the rest to the model": `raw` is the seam
between the two.

---

## 6. Contracts — output and exit codes

**Output.** Read ops (`view`, `comment list`, `whoami`) print the raw JSON
body on stdout; the caller `jq`s it. `issue create` prints the new key (the
analogue of grepping `acli`'s "✓ … created" line). Write ops (`transition`,
`assign`, `delete`, `comment add`) print nothing on success — success is the
exit code, and REST returns `204` with an empty body anyway (migration doc
§4). Human-readable errors always go to **stderr**, so stdout stays clean
for piping.

**Exit codes** (stable, part of the contract the pwsh twin must match):

| code | meaning | typical HTTP |
|---|---|---|
| 0 | success | 2xx |
| 1 | transport error (curl failed, DNS, timeout) | — |
| 2 | usage error (bad args, unknown subcommand) | — |
| 3 | unauthorized — token bad/stale for the role | 401 |
| 4 | not found / no permission (Jira masks 403 as 404) | 404 |
| 5 | validation — bad body, unknown field/type | 400 |
| 6 | forbidden — permission | 403 |
| 7 | unexpected status | other |
| 8 | no transition to the requested status from current | — (logical) |

A caller that needs to distinguish "unassigned" from "assigned to someone
else" still does the accountId comparison itself (migration doc §3.3) — the
client surfaces the data, the skill makes the call (constraint #2).

---

## 7. Layer 1 — cross-cutting resolution

- **Config.** Resolve `jira-sdlc-tools.env` + `jira-sdlc-tools.local.env`
  once at startup (reuse the existing `ensure_local_env` copy-into-worktree
  behaviour). `--role` selects the `JIRA_<ROLE>_EMAIL/_TOKEN` pair → `$_CRED`.
- **Cloud id, cached.** It never changes for a site but
  `_edge/tenant_info` is a network hop. Resolve once, cache to
  `${XDG_CACHE_HOME:-$HOME/.cache}/jira-sdlc/<site>.cloudid`; read the cache
  if present, refresh only if missing. Fast repeated invocations without
  reintroducing login-style state.
- **ADF encoding**, one helper, two entry points: `--desc-file` /
  `--body-file` (plain text → the `jq -Rs` paragraph builder, migration doc
  §3.10) vs `--adf-file` (caller supplies rich ADF verbatim). This is where
  the biggest `acli`→REST nuance (plain string → `400`; migration doc N1)
  is absorbed so callers never hit it.
- **email→accountId** (`_account_id_for`): `GET /user/search` (migration doc
  §3.7 N2), used by `assign` and `create --assignee`.

---

## 8. Deliberately out of scope

Keeping these out preserves the "transport, not judgment" line (constraint
#2) and keeps the pwsh twin small:

- **PR-base resolution / parent-branch search** — git + skill prose, not
  Jira (jira-acli-reference §12).
- **The assignee-ownership gate** — the client exposes `whoami` and
  `view …?fields=assignee`; the accountId comparison and the decision to
  *stop* belong to the skill.
- **Retry/backoff beyond one attempt** — "retry if Jira was slow" is the
  caller's call; a client that silently retries hides state from the model.
- **Skill-specific field lists as defaults** — `--fields` is passed
  explicitly; the canonical fetch-with-comments / review-fetch lists stay
  named in jira-acli-reference §3 (single source of truth), not baked in
  here.

---

## 9. Testing & parity

- **pwsh parity harness** (AGENTS.md): pwsh 7 runs on Linux, so diff each
  subcommand's stdout/exit-code against the `.ps1` twin under a forced OS.
  The narrow, regular surface (one dispatcher, JSON-in/JSON-out) is what
  makes this tractable — there's little Windows-only surface to diverge
  (no backslash paths in play; the cache path uses `$env:LOCALAPPDATA` on
  the pwsh side).
- **Live smoke test**: the create→view→comment→assign→transition→delete
  round-trip from the migration doc is the acceptance test; it ran green on
  2026-07-24 and is the shape each op is verified against.
- **`raw` as its own test surface**: because every named op is `raw` plus
  sugar, testing `raw` exercises the core; named-op tests then only need to
  check the sugar (ADF encode, id/accountId resolution).

---

## 10. Open decisions (resolve before implementing)

1. **Scope of the first cut** — ship only the calls the three skills invoke
   today ([migration doc §2](acli-to-rest-api-migration.md)) with `raw`
   covering the rest, or also wrap `search`/`edit`/reporter as named
   subcommands up front? (Recommendation: skill-invoked calls only; let
   `raw` cover the others until one earns a name.)
2. **Migration strategy** — introduce `jira.sh` alongside `acli` and cut the
   skills over one call at a time (lower risk, temporary duplication), or one
   atomic swap (removes the `jira_acli_login` layer in a single change)?
3. **Fate of the existing scripts** — `check_assignee.sh` /
   `get_assignee_email.sh` become thin wrappers over `jira.sh whoami` +
   `issue view`, or are absorbed as subcommands and deleted? Either way the
   `jira_acli_login.sh` login machinery (constraint #3) is removed entirely.
4. **Estimated size** — ~200 lines of `jira.sh` + its `jira.ps1` twin,
   replacing the per-operation scripts *and* the login layer.
