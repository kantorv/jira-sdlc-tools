#!/usr/bin/env bash
# check-mermaid.sh — parse every ```mermaid block in the repo's markdown.
#
# Usage:  bash scripts/check-mermaid.sh [file.md ...]     (default: all tracked .md)
#
# Diagrams are the one thing here a machine can actually check, and they fail in
# ways that are invisible on inspection — a diagram that renders as an error box
# on GitHub looks perfectly fine in the diff. Run this after touching any
# ```mermaid block. Requires network on first run (npx fetches mermaid-cli).
#
# Exit 0 — every block parses. Exit 1 — at least one doesn't (offender named).

set -u

FILES=("$@")
if [ ${#FILES[@]} -eq 0 ]; then
  mapfile -t FILES < <(git ls-files '*.md')
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILED=0; CHECKED=0

for f in "${FILES[@]}"; do
  grep -q '^```mermaid' "$f" 2>/dev/null || continue
  # one file may hold several blocks — split them out, check each on its own
  awk -v out="$TMP/b" 'BEGIN{i=0}
    /^```mermaid$/ {i++; flag=1; next}
    /^```$/        {flag=0}
    flag           {print > (out "-" i ".mmd")}' "$f"

  for m in "$TMP"/b-*.mmd; do
    [ -e "$m" ] || continue
    n=$(basename "$m" .mmd); n=${n#b-}
    CHECKED=$((CHECKED + 1))
    if npx -y @mermaid-js/mermaid-cli@11 -i "$m" -o "$m.svg" >"$m.log" 2>&1; then
      printf '  ok    %s (block %s)\n' "$f" "$n"
    else
      FAILED=1
      printf '  FAIL  %s (block %s)\n' "$f" "$n"
      grep -iE 'parse error|expecting' "$m.log" | head -2 | sed 's/^/        /'
    fi
  done
  rm -f "$TMP"/b-*.mmd "$TMP"/b-*.svg "$TMP"/b-*.log
done

echo
if [ "$FAILED" = 0 ]; then
  echo "check-mermaid: $CHECKED block(s) parse."
else
  echo "check-mermaid: at least one block failed to parse (see FAIL above)."
fi
exit "$FAILED"
