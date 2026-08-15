#!/usr/bin/env bash
# check-doc-links.sh — the grep pass the Docusaurus build cannot do for you.
#
# The site build (JST-288) verifies exactly one category of link: relative .md
# links between published docs. It is blind to the rest, and silently so:
#
#   * a published doc linking to an *unpublished* file (a workflow, AGENTS.md,
#     a script) is emitted unchanged — a relative path that 404s on the site
#     and warns nobody;
#   * an absolute github.com URL is never fetched, so one pointing at a file
#     that moved is still "valid" to every tool in the repo;
#   * a published-site URL baked into the plugin is just a string.
#
# So this checks all four link categories against the working tree. No network:
# every assertion is "this path exists in this checkout", which is the part that
# actually rots. Run it before pushing any change that moves or renames a doc.
#
#   bash scripts/check-doc-links.sh
#
# Exit 0 = clean, 1 = at least one broken reference (each printed with file:line).

set -uo pipefail
cd "$(dirname "$0")/.."

DOCS=docs
OLD_DOCS=plugins/jira-sdlc/docs
SELF_URL='https://github.com/kantorv/jira-sdlc-tools'
RAW_URL='https://raw.githubusercontent.com/kantorv/jira-sdlc-tools/main'
SITE_URL='https://kantorv.github.io/jira-sdlc-tools/docs'
MAP=scripts/docs-url-map.json

fails=0
report() { printf '  %s\n' "$1"; fails=$((fails + 1)); }
# URLs are cited mid-sentence, so a trailing full stop, comma or closing
# backtick belongs to the prose rather than to the link.
strip_punct() { printf '%s' "$1" | sed -E 's/[.,;:`]+$//'; }
section() { printf '\n== %s\n' "$1"; }

# Every relative link target in docs/, markdown and raw HTML alike — the phase
# diagrams and the README tables use <a href> / <img src>, which a markdown-only
# grep walks straight past.
doc_targets() {
  { grep -rnoE '\]\([^)"[:space:]]+\)' --include='*.md' "$DOCS" \
      | sed -E 's/\]\((.*)\)$/\1/'
    grep -rnoE '(href|src)="[^"]+"' --include='*.md' "$DOCS" \
      | sed -E 's/(href|src)="(.*)"$/\2/'
  } | grep -vE ':(https?:|mailto:|#|//|data:)'
}

# Every tracked file that may name a doc, minus the two directories owned by
# sibling sub-tasks (.github/workflows -> JST-289, website/ -> JST-288).
tracked() {
  git ls-files "$@" | grep -vE '^(\.github/|website/)'
}

# ---------------------------------------------------------------------------
section "category 1 — relative links inside docs/ resolve"
# Docusaurus checks these too, but only once the site builds; this runs today.
while IFS= read -r hit; do
  file=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}; target=${rest#*:}
  target=${target%%#*}
  [ -z "$target" ] && continue
  resolved=$(readlink -m "$(dirname "$file")/$target")
  [ -e "$resolved" ] || report "$file:$line -> $target (does not resolve)"
done < <(
  doc_targets
)

# ---------------------------------------------------------------------------
section "category 2 — no published doc links out of docs/ with a relative path"
# The invisible category: Docusaurus emits these unchanged, so only a grep finds
# them. A relative link is legal here *only* while it stays inside docs/.
while IFS= read -r hit; do
  file=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}; target=${rest#*:}
  target=${target%%#*}
  [ -z "$target" ] && continue
  resolved=$(readlink -m "$(dirname "$file")/$target")
  case "$resolved" in
    "$PWD/$DOCS"/*) ;;   # inside the docs root — fine, and versioning-safe
    *) report "$file:$line -> $target (escapes docs/; must be an absolute URL)" ;;
  esac
done < <(
  doc_targets
)

# ---------------------------------------------------------------------------
section "category 3 — absolute self-links name a path that exists"
# "Absolute" is not "resolves": a blob/main URL to a file you just moved is
# still absolute and now 404s. Checked against the working tree, not the network,
# so it passes before the branch reaches main.
while IFS= read -r hit; do
  file=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}; url=${rest#*:}
  url=$(strip_punct "$url")
  path=$(printf '%s' "$url" \
    | sed -E "s#^${SELF_URL}/(blob|tree)/main/##; s#^${RAW_URL}/##" \
    | sed -E 's/[#?].*$//')
  case "$path" in http*) continue ;; esac    # a branch other than main (lab/…)
  [ -e "$path" ] || report "$file:$line -> $url (no such path in this checkout)"
done < <(
  grep -rnoE "(${SELF_URL}/(blob|tree)/main|${RAW_URL})/[^)\"'[:space:]]+" \
    $(tracked '*.md' '*.sh' '*.ps1' '*.example') 2>/dev/null
)

# ---------------------------------------------------------------------------
section "category 4 — published-site URLs match a slug in $MAP"
while IFS= read -r hit; do
  file=${hit%%:*}; rest=${hit#*:}; line=${rest%%:*}; url=${rest#*:}
  url=$(strip_punct "$url")
  slug=${url#"$SITE_URL"}
  slug=${slug%%#*}
  # Prose citations rather than links to a page: the bare base URL ("doc
  # references live under …/docs/") and the `<slug>` placeholder form.
  case "$slug" in ""|"/"|*"<"*) continue ;; esac
  grep -q "\"slug\": \"$slug\"" "$MAP" \
    || report "$file:$line -> $url (no page carries slug $slug)"
done < <(
  grep -rnoE "${SITE_URL}[^)\"'[:space:]]*" \
    $(tracked '*.md' '*.sh' '*.ps1' '*.example') 2>/dev/null
)

# ---------------------------------------------------------------------------
section "the old location is gone"
while IFS= read -r hit; do
  report "$hit"
done < <(grep -rn "$OLD_DOCS" $(tracked '*.md' '*.sh' '*.ps1' '*.example' '*.json') 2>/dev/null \
           | grep -v '^scripts/repair-doc-links.py' | grep -v '^scripts/check-doc-links.sh')

# ---------------------------------------------------------------------------
section "every published page has front matter with a slug"
while IFS= read -r page; do
  head -1 "$page" | grep -q '^---$' || report "$page (no front matter)"
done < <(git ls-files "$DOCS/*.md" | grep -v '/_')

printf '\n'
if [ "$fails" -eq 0 ]; then
  echo "check-doc-links: OK — every doc reference resolves."
else
  echo "check-doc-links: $fails broken reference(s)."
fi
exit $((fails > 0))
