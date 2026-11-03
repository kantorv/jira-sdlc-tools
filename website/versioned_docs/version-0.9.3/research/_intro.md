While most of the effort here goes into the plugin itself, these skills are
**Markdown documents that people fork, adapt and translate** — and that turns
out to be its own problem. So alongside the plugin we research the continuous
editing of Markdown, and maintain two helper projects that came out of it:

| project | keeps in sync | distribution |
| -- | -- | -- |
| [cedit](cedit.md) | your local adaptations of a vendored document, across upstream updates | [`cedit`](https://pypi.org/project/cedit/) |
| [cl10n](cl10n.md) | translated mirrors of a document, one changed paragraph at a time | [`markdown-localization`](https://pypi.org/project/markdown-localization/) |

Both work the same way underneath: parse the document into an AST,
Merkle-hash it, and compare revisions **block by block** rather than line by
line — so what comes back is "this paragraph changed", not "this file
changed". One then re-applies your edits over the new upstream, the other
re-translates only what actually moved.

Neither is required to use the plugin. cedit is the one this repository
itself leans on: the `markdown-canonicalize` CI workflow gates every changed
`.md` with `cedit md canonicalize --check`.
