# website/

The [Docusaurus](https://docusaurus.io) site that publishes this repo's
documentation to <https://kantorv.github.io/jira-sdlc-tools/>.

The site reads the docs; it does not own them. Pages live in `../docs` at the
repo root (`docs.path` in `docusaurus.config.js`), where contributors and
GitHub's own renderer expect them — there is no copy step to keep in sync.
`website/` holds only the config, the sidebar, the theme and the landing page.

## Commands

Requires Node 20+ (CI pins 22; 24 is what this was written on).

```bash
npm ci          # install exactly the locked dependency tree
npm start       # dev server with hot reload, at /jira-sdlc-tools/
npm run build   # production build into website/build/
npm run serve   # serve website/build/ as it will be published
npm run clear   # drop the .docusaurus/ cache when the dev server gets confused
```

`npm run build` is the gate: `onBrokenLinks` and `markdown.hooks.onBrokenMarkdownLinks`
are both `throw`, so a doc link that no longer resolves fails the build instead
of shipping as a 404 nobody notices. Do not downgrade either to `warn` to get a
build through — fix the link. The same goes for `onBrokenMarkdownImages`, which
is left at its failing default and covers images, which the link hooks do not.

## Editing docs

Doc content, front matter (`slug:`, `sidebar_position:`) and `_category_.json`
files belong to `../docs`, not here. Slugs are a published contract: they are
listed in `scripts/docs-url-map.json` and URLs built from them ship inside the
plugin, so a slug that has been released is not renamed.

`url`, `baseUrl` and `docs.routeBasePath` in `docusaurus.config.js` must keep
producing `https://kantorv.github.io/jira-sdlc-tools/docs` for the same reason.

## Notes

- `.md` is parsed as CommonMark, `.mdx` as MDX (`markdown.format: 'detect'`).
  That is what lets docs contain `<KEY>`-style placeholders and raw HTML tables
  without escaping. To use JSX in a page, name it `.mdx`.
- Mermaid needs both `@docusaurus/theme-mermaid` in `themes` and
  `markdown.mermaid: true`; with either missing, blocks silently render as plain
  code fences.
- `showLastUpdateTime` reads git history, so CI checks out with `fetch-depth: 0`.
  On a shallow clone it warns instead of failing.
- The site is deliberately outside `plugins/`, so a marketplace install never
  copies it into a user's plugin cache.
