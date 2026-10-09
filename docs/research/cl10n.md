---
slug: /research/cl10n
sidebar_position: 2
sidebar_label: cl10n
---

# cl10n — continuous localization for Markdown

- Repository: [github.com/sdlctools/cl10n](https://github.com/sdlctools/cl10n)
- Package: [pypi.org/project/markdown-localization](https://pypi.org/project/markdown-localization/)

## Why it exists

The same problem as [cedit](cedit.md), one step over: translations. A skill is
a Markdown document, and once it is translated, every upstream change puts the
mirror out of date. Running an LLM over the whole file again is the obvious
move and the wrong one — it costs the full document every time, and it
re-words paragraphs nobody touched, so the diff of the translation is
unreadable.

cl10n **retranslates only what actually changed.** Everything else is served
from a committed translation memory.

## How it works

Each document is parsed into an AST and Merkle-hashed, and two revisions are
diffed structurally. The result is a per-paragraph verdict — reuse, recheck,
revise, translate — and only the last two become LLM jobs. Rendering then
splices the translations back into the *source* tree, so headings, list
nesting, table shape and code fences come from the original and a translation
cannot corrupt them.

```bash
pip install markdown-localization[groq]   # also [nvidia], [mistral], [all-providers]
export GROQ_API_KEY=...

cl10n plan   --langs he,ru                # diff the corpus into a queue of jobs
cl10n run    l10n/queue/queue.json -c 8   # execute the queue
cl10n render --langs he,ru                # memory → locales/he/**, locales/ru/**
cl10n status --langs he,ru                # coverage per language
```

The distribution is `markdown-localization`; the command and the importable
package are both `cl10n`. Python 3.11+, and providers are pluggable.

The same four commands serve a first translation and a daily update — a first
translation is just an incremental update whose previous revision was empty.
Kill a run and re-run it: the resume state is the memory rather than the queue,
so finished work is never re-billed and interrupted work is never lost.

What the pipeline guarantees, and which the plugin's own docs would need:
a paragraph repeated in two files costs one translation; inline code, link
targets and image sources are checked against every response, at translation
time and again at render time; a render refuses to write a file whose block
structure moved; and a unit with no usable translation falls back to English
and is *counted*, never shipped silently.
