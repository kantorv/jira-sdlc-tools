#!/usr/bin/env bash
# render-diagrams.sh — regenerate the lifecycle SVGs in docs/assets/ from their
# mermaid sources, or (--check) exit 1 naming every SVG its source has outrun.
#
# Usage: bash scripts/render-diagrams.sh [--check]
#
# Each SVG is a pure function of its source plus the pinned renderer: this exact
# pipeline (mermaid-cli 11.17.0, -b white) reproduced every committed phase SVG
# byte-for-byte before the script existed (JST-310), so a --check failure means
# a source moved and its SVG didn't — not renderer noise. Keep MMDC_VERSION
# pinned: another mermaid-cli release lays text out differently and churns
# every SVG. Layout also measures text with whatever fonts headless Chromium
# finds, so a machine with different fonts can shift coordinates; if --check
# fails on a fresh machine with no source change, that is the cause.
#
# Needs npx (Node) and network on first run, like check-mermaid.sh.
# Exit: 0 = all current (or rewritten); 1 = stale (--check) or a render failed;
#       2 = usage error or npx missing.

set -u
MMDC_VERSION=11.17.0

CHECK=""
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  *) echo "usage: bash scripts/render-diagrams.sh [--check]" >&2; exit 2 ;;
esac
command -v npx >/dev/null 2>&1 || { echo "render-diagrams: npx not found — install Node to render." >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)" || exit 2

# source → svg. A .md source contributes its one ```mermaid block; a .mmd is
# used whole, for a diagram no published page carries as a block (the Phase 3
# single-step preview is a trimmed view, not a copy of any page's diagram).
DIAGRAMS="
docs/task-lifecycle/TASK-LIFECYCLE-PHASE-1.md docs/assets/task-lifecycle-phase-1.svg
docs/task-lifecycle/TASK-LIFECYCLE-PHASE-2.md docs/assets/task-lifecycle-phase-2.svg
docs/task-lifecycle/TASK-LIFECYCLE-PHASE-3.md docs/assets/task-lifecycle-phase-3.svg
docs/assets/task-lifecycle-phase-3-single-step.mmd docs/assets/task-lifecycle-phase-3-single-step.svg
"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
rc=0

while read -r src svg; do
  [ -n "$src" ] || continue
  name=$(basename "$svg" .svg)
  case "$src" in
    *.md)
      n=$(grep -c '^```mermaid' "$src")
      if [ "$n" -ne 1 ]; then
        echo "  FAIL  $src has $n mermaid blocks — expected exactly one (add the new one to DIAGRAMS as a .mmd instead)"
        rc=1; continue
      fi
      awk '/^```mermaid/{f=1;next} f&&/^```/{exit} f' "$src" > "$TMP/$name.mmd" ;;
    *) cp "$src" "$TMP/$name.mmd" ;;
  esac
  if ! npx -y "@mermaid-js/mermaid-cli@$MMDC_VERSION" -i "$TMP/$name.mmd" -o "$TMP/$name.svg" -b white \
      > "$TMP/$name.log" 2>&1; then
    echo "  FAIL  $src did not render:"; sed 's/^/        /' "$TMP/$name.log"
    rc=1; continue
  fi
  if cmp -s "$TMP/$name.svg" "$svg"; then
    echo "  ok    $svg"
  elif [ -n "$CHECK" ]; then
    echo "  STALE $svg — its source $src has changed; run: bash scripts/render-diagrams.sh"
    rc=1
  else
    cp "$TMP/$name.svg" "$svg"
    echo "  wrote $svg"
  fi
done <<< "$DIAGRAMS"

exit $rc
