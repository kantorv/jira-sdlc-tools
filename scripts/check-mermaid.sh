#!/usr/bin/env bash
# check-mermaid.sh — check every ```mermaid block in the repo's markdown.
#
# Usage:
#   bash scripts/check-mermaid.sh [file.md ...]   # default: all tracked .md
#   bash scripts/check-mermaid.sh --lint          # skip the renderer; lint only
#
# Diagrams fail in a way that is invisible in review — a broken block still
# looks like a reasonable diagram in the diff, and only becomes an error box
# once GitHub renders it. So check them mechanically after any edit.
#
# TWO MODES:
#
#   full  (default, needs Node + network on first run)
#         Parses each block with the real mermaid parser via
#         `npx @mermaid-js/mermaid-cli`. This is the only way to be *sure*.
#
#   lint  (--no-npx / --lint, or automatic when npx is unavailable)
#         Pure bash/grep. Catches the mechanical traps below, then asks you to
#         eyeball the diagram. It cannot prove a diagram is valid — it can only
#         catch the known killers. Paste the block into https://mermaid.live
#         if you want certainty without installing anything.
#
# What the linter checks (each verified against the real parser — these are the
# things that actually break a sequence diagram, as opposed to things that look
# like they should):
#   1. `;` in message or note text — mermaid treats it as a STATEMENT SEPARATOR,
#      so it truncates the line and breaks the whole diagram. The parser then
#      blames the token AFTER the semicolon, which actively misdirects you.
#      This is the single most likely way to break one of these files.
#   2. unbalanced block keywords (alt/loop/opt/par/rect/critical/box vs `end`).
#   3. a block with no diagram-type line (sequenceDiagram, flowchart, ...).
#
# NOT problems, despite looking like them (all confirmed fine): `<KEY>` angle
# tokens, em-dashes, `→`, colons, commas, `#`, backticks, pipes, braces,
# unmatched parens, and participants used without being declared (mermaid
# auto-creates them).
#
# Exit 0 — no problems found. Exit 1 — a definite problem (named).

set -u

MODE=full
FILES=()
for a in "$@"; do
  case "$a" in
    --lint|--no-npx) MODE=lint ;;
    *) FILES+=("$a") ;;
  esac
done

if [ ${#FILES[@]} -eq 0 ]; then
  mapfile -t FILES < <(git ls-files '*.md')
  if [ ${#FILES[@]} -eq 0 ]; then
    echo "check-mermaid: no markdown files found (not a git repo? pass files explicitly)." >&2
    exit 1
  fi
fi

if [ "$MODE" = full ] && ! command -v npx >/dev/null 2>&1; then
  echo "check-mermaid: npx not found — falling back to lint mode (grep only)." >&2
  echo "check-mermaid: for a real parse, install Node, or paste the block into https://mermaid.live" >&2
  echo >&2
  MODE=lint
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FAILED=0; CHECKED=0; LINTED=0

# lint_block <file> <block-no> <path-to-mmd>
lint_block() {
  local f=$1 n=$2 m=$3 bad=0 line ln

  # 1. semicolon in message / note text (the killer)
  while IFS= read -r line; do
    ln=${line%%:*}
    printf '  FAIL  %s (block %s, line %s): semicolon in message text — mermaid reads `;` as a statement separator and the diagram breaks. Use `—` or `·`.\n' "$f" "$n" "$ln"
    bad=1
  done < <(grep -nE '^[[:space:]]*([A-Za-z0-9_]+[[:space:]]*(-|=)+>>?|Note |note )' "$m" | grep ';')

  # 2. unbalanced block keywords
  local opens closes
  opens=$(grep -cE '^[[:space:]]*(alt|loop|opt|par|par_over|rect|critical|box)([[:space:]]|$)' "$m" || true)
  closes=$(grep -cE '^[[:space:]]*end([[:space:]]|$)' "$m" || true)
  if [ "$opens" -ne "$closes" ]; then
    printf '  FAIL  %s (block %s): %s block-opening keyword(s) (alt/loop/opt/par/rect/critical/box) but %s `end` — every one needs its own `end`.\n' "$f" "$n" "$opens" "$closes"
    bad=1
  fi

  # 3. a diagram type at all
  if ! grep -qE '^[[:space:]]*(sequenceDiagram|flowchart|graph|classDiagram|stateDiagram(-v2)?|erDiagram|journey|gantt|pie|gitGraph|mindmap|timeline|quadrantChart|C4Context|sankey(-beta)?|xychart(-beta)?|block(-beta)?)' "$m"; then
    printf '  FAIL  %s (block %s): no diagram-type line (expected `sequenceDiagram`, `flowchart TD`, ...) as the first statement.\n' "$f" "$n"
    bad=1
  fi

  if [ "$bad" = 0 ]; then
    printf '  lint  %s (block %s) — no known trap. Renderer not run: EYEBALL IT (or paste into https://mermaid.live).\n' "$f" "$n"
  fi
  return "$bad"
}

for f in "${FILES[@]}"; do
  grep -q '^```mermaid' "$f" 2>/dev/null || continue
  awk -v out="$TMP/b" 'BEGIN{i=0}
    /^```mermaid$/ {i++; flag=1; next}
    /^```$/        {flag=0}
    flag           {print > (out "-" i ".mmd")}' "$f"

  for m in "$TMP"/b-*.mmd; do
    [ -e "$m" ] || continue
    n=$(basename "$m" .mmd); n=${n#b-}
    CHECKED=$((CHECKED + 1))

    if [ "$MODE" = lint ]; then
      LINTED=$((LINTED + 1))
      lint_block "$f" "$n" "$m" || FAILED=1
      continue
    fi

    if npx -y @mermaid-js/mermaid-cli@11 -i "$m" -o "$m.svg" >"$m.log" 2>&1; then
      printf '  ok    %s (block %s)\n' "$f" "$n"
    else
      FAILED=1
      printf '  FAIL  %s (block %s)\n' "$f" "$n"
      grep -iE 'parse error|expecting' "$m.log" | head -2 | sed 's/^/        /'
      # the parser's message misdirects on this one — say the real cause
      grep -qE '^[[:space:]]*([A-Za-z0-9_]+[[:space:]]*(-|=)+>>?|Note |note ).*;' "$m" \
        && printf '        ^ there is a `;` in this block. That is almost certainly the cause:\n          mermaid reads it as a statement separator. Use `—` or `·`.\n'
    fi
  done
  rm -f "$TMP"/b-*.mmd "$TMP"/b-*.svg "$TMP"/b-*.log
done

echo
if [ "$FAILED" != 0 ]; then
  echo "check-mermaid: problems found (see FAIL above)."
elif [ "$MODE" = lint ]; then
  echo "check-mermaid: $LINTED block(s) linted — no known trap, but NOT parsed."
  echo "check-mermaid: a linted block is not a valid block. Render it (mermaid.live) or view the file on GitHub before merging."
else
  echo "check-mermaid: $CHECKED block(s) parse."
fi
exit "$FAILED"
