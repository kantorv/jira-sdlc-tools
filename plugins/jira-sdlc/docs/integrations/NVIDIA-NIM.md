# NVIDIA NIM Integration (Native Claude Skills Spec, via fcc)

> **DRAFT.** The architecture and the model-proxy requirement below are **Verified** against fcc's
> own README (https://github.com/Alishahryar1/free-claude-code); the end-to-end NIM + fcc + skills
> run was **not** exercised in this environment (no NIM API key or GPU here). Each step is tagged
> inline **Verified** / **Unverified** accordingly — see Platform-Specific Caveats.

Uses the native Claude skills specification, but with a defining difference from Cursor, Kilo, and
OpenCode. Those connect to the skills through a same-spec runtime; NVIDIA NIM serves models behind an
**OpenAI-compatible** API. The skills reader here is **Claude Code itself**, and a **model-proxy
platform** sits between Claude Code and NIM — presenting an Anthropic-compatible API to Claude Code
and translating it to NIM's OpenAI-compatible endpoint. That proxy is separate software installed on
top of the usual prerequisites, and it is **required**: Claude Code cannot talk to a NIM endpoint
directly.

The verified instance of that proxy is **fcc** (free-claude-code, https://github.com/Alishahryar1/free-claude-code) —
what the issue title names. **Router9** (https://www.router9.com/) is a similar hosted gateway. Any
Anthropic-compatible proxy that can route to an OpenAI-style endpoint can play the same role (see
Alternative proxies).

> **Correction of the originating issue's assumption.** The issue described fcc as the thing that
> "loads Claude-spec skills against a NIM-served model." fcc's own README does not mention `SKILL.md`,
> skills paths, slash commands, or plugins — fcc is a *proxy*, not a skills loader. The skills
> catalogue is loaded by the real Claude Code CLI that `fcc-claude` launches, so skill wiring is the
> standard Claude Code wiring in step 3. Recorded here so the next run starts from the corrected model.

## Prerequisites

- `acli` (Atlassian CLI) authenticated — see `jira-sdlc-tools.env` in your marketplace **root**
  (not the plugin root)
- `gh` (GitHub CLI) authenticated
- `jira-sdlc-tools.env` and `jira-sdlc-tools.local.env` in your **project root** — see
  [project-config.md](../../skills/_shared/project-config.md)
- **A model-proxy platform** that exposes an Anthropic-compatible API and can route to your NIM
  endpoint — fcc (below) is the verified instance; Router9 and similar fulfill the same role.
  Required; NIM cannot front Claude Code without it.
- **NVIDIA NIM access** — an API key for NIM's hosted service (issued at `build.nvidia.com/settings/api-keys`)
  **or** a self-hosted NIM endpoint. These values live in the proxy's own config, **not** in
  `jira-sdlc-tools.env` (which is the Jira/Git project layer, not the model endpoint).
- **Claude Code CLI** — fcc launches Claude Code, which loads skills from `~/.claude/` as usual.
  *(Unverified: whether the fcc installer installs `claude` itself or expects it pre-installed —
  assume you need Claude Code installed first.)*

## Install / Wire-up Steps

Three independent layers: the proxy, the NIM endpoint it points at, and the skills (loaded by
Claude Code exactly as in the standard setup). The steps use **fcc** as the proxy because the issue
names it; the alternative-proxy notes after the steps cover Router9 and the general category.

### 1. Install and configure the proxy (fcc)

**Verified** against the fcc README (https://github.com/Alishahryar1/free-claude-code).

1. **Install fcc** (macOS/Linux — `uv` is used under the hood; config lands in `~/.fcc/`):

   ```
   curl -fsSL "https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/install.sh" | sh
   ```

2. **Start the proxy server** — it listens locally (default `http://localhost:8082`, per the README's
   Claude Code example) and exposes an Anthropic-compatible endpoint:

   ```
   fcc-server
   ```

3. **Configure the NIM provider** in fcc's Admin UI (opened from the running server): set the NIM
   API key in the `NVIDIA_NIM_API_KEY` field, and pick the model id in fcc's `<provider-id>/<model-id>`
   form — the README's NIM example is `nvidia_nim/nvidia/nemotron-3-super-120b-a12b`. Treat the real
   values as tokens:

   ```
   NVIDIA_NIM_API_KEY = <NIM_API_KEY>
   MODEL              = <NIM_MODEL_ID>     # e.g. nvidia_nim/nvidia/nemotron-3-super-120b-a12b
   ```

   fcc's route-tier knobs (`MODEL_FABLE`, `MODEL_OPUS`, `MODEL_SONNET`, `MODEL_HAIKU`) can map
   Claude's model tiers to different NIM models; `MODEL` is the fallback default. *(Verified that
   these setting names exist in the fcc README; Unverified which tier a given skill run actually
   requests on a real NIM model — see Caveats.)*

4. **Launch Claude Code through the proxy** — `fcc-claude` starts the real Claude Code CLI with
   `ANTHROPIC_BASE_URL` pointed at fcc and `ANTHROPIC_AUTH_TOKEN` set to fcc's shared token. The
   README's Claude Code integration cites exactly `ANTHROPIC_BASE_URL=http://localhost:8082` and
   `ANTHROPIC_AUTH_TOKEN=freecc`:

   ```
   fcc-claude
   ```

   From this point the session **is** Claude Code — only the model endpoint changed; everything else
   (skill discovery, slash commands, frontmatter parsing, harness behaviour) is unmodified Claude
   Code. *(Unverified end-to-end: not run against a real NIM endpoint here. The
   `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` payload is the same standard mechanism Claude Code
   uses for any custom endpoint — what is specific to fcc is only that it wraps and sets them for
   you.)*

### 2. Point the proxy at your NIM endpoint

The NIM side is invisible to Claude Code behind the proxy. The proxy needs two things from NIM:

| value | where it comes from | token |
|---|---|---|
| NIM API key | hosted NIM: `build.nvidia.com/settings/api-keys`; self-hosted NIM: your own | `<NIM_API_KEY>` |
| NIM base URL | hosted NIM: NIM's OpenAI-compatible endpoint (see the build.nvidia.com quickstart; commonly published as `https://integrate.api.nvidia.com/v1`); self-hosted NIM: `http://<NIM_HOST>:<NIM_PORT>/v1` | `<NIM_BASE_URL>` |

**Verified** that NIM exposes an OpenAI-compatible chat-completions endpoint and takes a bearer API
key — this is what lets fcc (or any translation proxy) treat it as a backing provider, and it is the
load-bearing reason a proxy is required. *(Unverified: the exact hosted base-URL string — confirm
against your NIM provider's quickstart rather than taking the commonly-published one on trust. For a
self-hosted NIM you already know your `<NIM_HOST>:<NIM_PORT>`.)*

In the fcc path you typically set **only** `NVIDIA_NIM_API_KEY` + model id — fcc resolves NIM's
hosted endpoint from the model-id prefix. You set `<NIM_BASE_URL>` explicitly only for a self-hosted
NIM (fcc's Admin UI exposes a base-URL override for providers) or when using a non-fcc proxy.

### 3. Install the skills (standard Claude Code wiring)

Because `fcc-claude` *is* Claude Code, the skill install is identical to the canonical Claude Code
path. Run these **inside the `fcc-claude` session**, not a plain shell, so they persist into
`~/.claude/`:

```
/plugin marketplace add <GITHUB_OWNER>/<GITHUB_REPO>     # or </ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>
/plugin
```

then install the `jira-sdlc` entry from the Discover tab. Verified Claude Code install layout:
`~/.claude/plugins/cache/<MARKETPLACE>/jira-sdlc/<version>/skills/` (three skill folders plus
`_shared/`). After install, `/reload-plugins` inside the session sees them.

See [CURSOR.md](CURSOR.md) Method 1 for the verified Linux flow — the only difference here is that the
session was launched via `fcc-claude`, not `claude` directly. The plugin README's "Option B —
Drop-in" (symlink `plugins/jira-sdlc/skills/*` into `~/.claude/skills/`) is the alternative if you
don't want a marketplace install.

### Alternative proxies (Router9, and similar)

The proxy is replaceable; the requirement is invariant — *an Anthropic-compatible endpoint that
forwards to your NIM*.

- **Router9** (https://www.router9.com/) — a hosted SaaS LLM gateway that exposes **both** a native
  Anthropic endpoint and an OpenAI-compatible one ("change the base URL and key, nothing else"). You
  would point Claude Code's `ANTHROPIC_BASE_URL` at Router9's Anthropic endpoint instead of localhost
  fcc, and use a Router9 model id. **Known gap:** Router9's public page lists a curated hosted
  catalog (GPT, Claude, Gemini, DeepSeek, "hundreds more"); it says nothing about routing to a
  **self-hosted NIM** endpoint. So Router9 is "a model-proxy platform that can front Claude Code,"
  but whether it can reach *your* NIM specifically is **Unverified** — confirm before assuming it
  substitutes 1:1 for the fcc/self-hosted-NIM pairing.
- **Any open translation proxy** (e.g. an OSS OpenAI↔Anthropic translation server, LiteLLM-style
  gateway) satisfies the same contract: expose an Anthropic-compatible API at some
  `ANTHROPIC_BASE_URL`, set `ANTHROPIC_AUTH_TOKEN`, and forward to `<NIM_BASE_URL>` with header key
  `<NIM_API_KEY>`. Launch Claude Code yourself (not via `fcc-claude`) with those env vars set.

## Invoking the Three Skills

Inside the `fcc-claude` session, invoke the skills exactly as in the standard Claude Code setup — the
plugin namespace is unchanged because the runtime *is* Claude Code:

- `/jira-sdlc:jira-task-assigner` — break down a task into Jira issues with branches
- `/jira-sdlc:jira-task-executor` — implement an issue from its worktree
- `/jira-sdlc:jira-task-reviewer` — review sub-task PRs from the parent worktree

## Platform-Specific Caveats and Known Gaps

- **A model proxy is required; NIM cannot front Claude Code alone.** This is the one structural
  difference from every other integration in this directory. Cursor, Kilo, and OpenCode connect via a
  same-spec runtime; NVIDIA NIM is OpenAI-compatible, so an Anthropic-compatible proxy (fcc, Router9,
  or a self-run translation gateway) must translate. Without it, Claude Code has no endpoint to talk
  to.
- **`disable-model-invocation: true` is honoured — by Claude Code, not by the proxy.** Because
  `fcc-claude` launches the real Claude Code CLI, the harness that parses skill frontmatter and gates
  auto-invocation is Claude Code's own; fcc only swaps the model endpoint and does not touch skill
  behaviour, so the flag behaves exactly as documented for the standard Claude Code setup (explicit
  `/jira-sdlc:…` invocation only). The proxy choice (fcc vs Router9 vs a gateway you run) does not
  change this. *(Verified architecturally from the fcc README's claim that fcc merely fronts Claude
  Code with new env vars; Unverified end-to-end on a live NIM model — not run here.)*
- **fcc does not itself read `SKILL.md`**; skills, `allowed-tools`, and frontmatter are parsed by the
  Claude Code CLI that `fcc-claude` launches. The originating issue's "fcc loads Claude-spec skills"
  phrasing is wrong; the skills reader is Claude Code. Repeating here so the next run doesn't
  re-derive it.
- **Model fidelity is the dominant practical risk.** These skills are agentic — they shell out to
  `acli`, `gh`, `git`, and the bash/PowerShell scripts under `skills/_shared/scripts/`, follow
  multi-step prose runbooks, and resolve `<TOKEN>`s and PR-base branches. Their correctness depends
  on the backing model's tool-calling reliability and instruction-following, not on the proxy. A
  NIM-served model that calls tools unreliably, drifts on the script-dispatch rules, or backslides on
  long stepwise instructions may mis-execute a skill even when the wiring is correct. **Unverified:**
  how any specific NIM model (e.g. Nemotron) actually performs these skills end-to-end — that needs a
  real NIM + fcc run per the issue, and is out of scope for this draft.
- **The skills assume the same toolchain as the standard setup.** fcc proxies model calls only; it
  does not provide or sandbox `acli` / `gh` / `git` / `python3` / `pwsh`. Those must be installed and
  on PATH in the environment the `fcc-claude` session runs in — same prerequisites as the Claude Code
  integration. Any sandboxing fcc applies is limited to model I/O, not the skill scripts, so
  tool-availability limits belong here.
- **NIM credentials are not `jira-sdlc-tools.env` values.** `<NIM_API_KEY>`, `<NIM_BASE_URL>`, and
  `<NIM_MODEL_ID>` are the *model* layer and live in the proxy's own config (fcc's `~/.fcc/` / Admin
  UI; Router9's dashboard; your gateway's env). Keep them out of the project env to avoid committing
  model-provider keys into the repo.
- **Per-tier model mapping can drift.** If you map Claude's `OPUS` / `SONNET` / `HAIKU` / `FABLE`
  tiers to different NIM models via fcc's `MODEL_*` settings, a session that *thinks* it is using a
  high-capability tier may quietly receive a smaller NIM model. Pin `MODEL` explicitly if you care
  which NIM model answers. *(Unverified which tier a given skill run requests.)*
- **Run `fcc-claude` from the issue's worktree.** The executor and reviewer skills derive the issue
  key from the current branch and expect to be run from the issue's own worktree. Launch `fcc-claude`
  from inside that worktree the same way you would `claude`; the proxy changes the model endpoint,
  not the working directory.
- **Router9 cannot be assumed to reach a self-hosted NIM** — see Alternative proxies: Router9's
  catalog is hosted, and routing to an arbitrary `<NIM_BASE_URL>` is Unverified. Don't choose Router9
  expecting a drop-in for the fcc/self-hosted-NIM pairing without confirming its
  bring-your-own-endpoint support.
- **No project-specific literals.** Everything NIM-shaped in this doc is a `<TOKEN>`
  (`<NIM_API_KEY>`, `<NIM_BASE_URL>`, `<NIM_MODEL_ID>`); everything repo-shaped
  (`<GITHUB_OWNER>/<GITHUB_REPO>`, `<MARKETPLACE>`, `</ABSOLUTE/PATH/TO/MARKETPLACE/ROOT>`) is the same
  token set the rest of this directory uses. No real NIM key, hosted domain, or model id is written
  into the file.
