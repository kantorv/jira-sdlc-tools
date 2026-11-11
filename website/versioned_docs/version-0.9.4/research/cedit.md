---
slug: /research/cedit
sidebar_position: 1
sidebar_label: cedit
---

# cedit — continuous editing of vendored Markdown

- Repository: [github.com/sdlctools/cedit](https://github.com/sdlctools/cedit)
- Package: [pypi.org/project/cedit](https://pypi.org/project/cedit/)
- Docs: [sdlctools.github.io/cedit](https://sdlctools.github.io/cedit/)

## Why it exists

Say you cloned this plugin and adapted it: different branch names, extra logic
on a state move, a fence rewritten because your environment runs `zsh` rather
than `bash`. You now want both things at once — **your edits in place, and
upstream's fixes as they land**. A `git merge` of a vendored copy gives you
line-level conflicts across a document that was reflowed; re-applying your
changes by hand after every update gives you drift.

cedit keeps a **persistent block-level overlay** of your adaptations and
re-applies it by 3-way structural merge on the document's AST. Your edits
survive upstream reflows and moved blocks, upstream changes to blocks you
never touched flow straight in, and you are told — per block, with all three
versions — when upstream edited the very thing you had adapted.

## How it works

Each document is parsed into an AST and Merkle-hashed per block, so the merge
keys on *blocks*, not lines. Three versions meet at each block (base, upstream,
local) and the merge matrix decides: reuse yours, take theirs, or raise a
conflict. State lives in a committed `.cedit/` folder — the base snapshots are
the merge's memory.

```bash
pipx install cedit

cedit snapshot skills/SKILL.md --from vendor/skills/SKILL.md   # start tracking
# …adapt the file in place…
cedit diff                       # what your overlay currently holds
cedit sync --from vendor         # upstream moved: re-apply the overlay over it
cedit resolve skills/SKILL.md <hash> --take local   # or --take upstream
cedit status
```

Exit codes are `0` clean, `1` unresolved conflicts, `2` error. A document with
open conflicts refuses to sync again, and the working file always keeps *your*
text until you resolve it — never a silent clobber.

A second, stateless command group exposes the parser itself — `cedit md canonicalize`, `blocks`, `ast`, `json` — a file in, stdout out, no state
touched. **This repository uses that group:** the `markdown-canonicalize`
workflow runs `cedit md canonicalize --check` over every changed `.md`, which
is also why
[AGENTS.md](https://github.com/kantorv/jira-sdlc-tools/blob/main/AGENTS.md)
tells you to canonicalize before pushing.

## Status

Alpha, and phase 1 of its spec: it merges **replacements** — prose, fences,
table cells, front matter — and rejects local *structural* edits (inserting,
deleting or moving whole blocks) with a per-block report rather than guessing.
Fetching upstream is out of scope: `--from` takes a directory or a file, and
git submodules, subtrees or a copy step are your transport. Pin the version if
stability matters to you; nothing is promised stable before 1.0.
