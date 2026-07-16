# Claude Code session transcript format (`.jsonl`)

One JSON object per line. Every recipe below was verified against real
jira-sdlc session files; shapes outside this doc do appear (the format
is Claude Code's internal one and versions drift), so when a jq filter
returns nothing unexpectedly, inspect a raw line before concluding the
event never happened.

## Line types

| `.type` | What it is | Analysis value |
|---|---|---|
| `user` | A user turn **or** a tool result (results come back as user-role lines) | invocation, args, interjections, tool outputs |
| `assistant` | A model turn: `thinking` / `text` / `tool_use` blocks | the agent's actions and stated reasoning |
| `system` | Meta events — `.subtype` seen: `turn_duration`, `away_summary` | mostly skip; `away_summary` is a free recap |
| `summary` | Compaction marker — earlier turns were summarized away | everything before it is partially invisible |
| `attachment` | Injected context (`skill_listing`, `agent_listing_delta`, …) | skip |
| `mode`, `permission-mode`, `file-history-snapshot`, `file-history-delta`, `last-prompt` | Session bookkeeping | skip |

Useful envelope fields on `user`/`assistant` lines: `uuid`,
`parentUuid`, `timestamp`, `cwd`, `gitBranch`, `sessionId`, `version`
(Claude Code version), `isSidechain` (true = subagent traffic, not the
main thread).

## Content shapes

`user` lines — `.message.content` is **either a string or an array**;
handle both:

- string → the raw prompt (slash-command invocations look like
  `<command-message>…</command-message>\n<command-name>/jira-sdlc:jira-task-executor</command-name>`)
- array of blocks:
  - `{type:"text", text:"…"}` — for a skill invocation, the block right
    after the command line starts with
    `Base directory for this skill: ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/<name>`
    followed by the **entire skill prompt as the agent received it**
    (installed-cache version; `$ARGUMENTS` already substituted — an
    empty args shows up as a bare `` `` ``).
  - `{type:"tool_result", tool_use_id:"…", content: <string or [{type:"text",…}]>, is_error: <bool?>}`

`assistant` lines — `.message.content` is an array of
`{type:"thinking"}` / `{type:"text"}` /
`{type:"tool_use", id, name, input}` blocks.

## Recipes

Profile a file (also the stub check — no `assistant` lines = stub):

```bash
jq -r '.type' "$f" | sort | uniq -c
```

Find the invocation(s) and run context:

```bash
jq -c 'select(.type=="user")
       | select((.message.content|tostring) | contains("<command-name>"))
       | {uuid, timestamp, cwd, gitBranch}' "$f"
```

Extract the embedded skill text (what actually ran) to a file:

```bash
jq -r 'select(.type=="user") | .message.content
       | if type=="array" then .[] | select(.type=="text") | .text else empty end' "$f" \
  | awk '/^Base directory for this skill:/{found=1} found' > /tmp/embedded-skill.md
```

The `Base directory` line's `/<version>/` path segment is the installed
plugin version — diff `/tmp/embedded-skill.md` against the working-copy
`SKILL.md` for the drift section (expect noise: the embedded copy has
`$ARGUMENTS` substituted and no frontmatter).

Timeline of tool calls (main thread only):

```bash
jq -r 'select(.type=="assistant" and (.isSidechain|not))
       | .uuid as $u | .timestamp as $t
       | .message.content[]? | select(.type=="tool_use")
       | [$t, $u, .name, (.input|tostring|.[0:160])] | @tsv' "$f"
```

Failed tool calls:

```bash
jq -r 'select(.type=="user") | .uuid as $u
       | .message.content | if type=="array" then .[] else empty end
       | select(.type=="tool_result" and .is_error==true)
       | [$u, (.content|tostring|.[0:200])] | @tsv' "$f"
```

The agent's own narration (what it *said* it was doing — compare
against what the tool calls show it *did*):

```bash
jq -r 'select(.type=="assistant" and (.isSidechain|not))
       | .message.content[]? | select(.type=="text") | .text' "$f"
```

User interjections after the invocation (course corrections):

```bash
jq -r 'select(.type=="user")
       | select(.message.content | type=="string")
       | select((.message.content|contains("<command-"))|not)
       | .message.content' "$f"
```

Shared-script invocations with their arguments (for the dispatch
check — `.sh` vs `win/*.ps1` must match the run's OS and stay
consistent across the run):

```bash
jq -r 'select(.type=="assistant") | .uuid as $u
       | .message.content[]? | select(.type=="tool_use" and .name=="Bash")
       | select(.input.command | test("_shared/scripts"))
       | [$u, (.input.command|.[0:200])] | @tsv' "$f"
```

Helper-script candidates — files the agent wrote, plus heavyweight bash:

```bash
jq -r 'select(.type=="assistant") | .uuid as $u
       | .message.content[]? | select(.type=="tool_use")
       | select(.name=="Write" or .name=="Edit")
       | [$u, .input.file_path] | @tsv' "$f"

jq -r 'select(.type=="assistant") | .uuid as $u
       | .message.content[]? | select(.type=="tool_use" and .name=="Bash")
       | select((.input.command|test("\n")) or ((.input.command|length) > 300))
       | [$u, (.input.command|.[0:200])] | @tsv' "$f"
```

## Matching results to calls

A `tool_result`'s `tool_use_id` equals the `tool_use` block's `id`.
For big transcripts build a join table once instead of re-scanning:

```bash
jq -r 'select(.type=="assistant") | .message.content[]?
       | select(.type=="tool_use") | [.id, .name] | @tsv' "$f" > /tmp/calls.tsv
jq -r 'select(.type=="user") | .message.content
       | if type=="array" then .[] else empty end
       | select(.type=="tool_result")
       | [.tool_use_id, (if .is_error==true then "ERR" else "ok" end)] | @tsv' "$f" > /tmp/results.tsv
```

A call with no matching result usually means the turn was interrupted
or the session ended mid-call — worth a note in the timeline.
