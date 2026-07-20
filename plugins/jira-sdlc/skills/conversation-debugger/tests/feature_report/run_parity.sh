#!/usr/bin/env bash
# run_parity.sh — golden-file parity harness for the feature_report renderer.
#
#   bash tests/feature_report/run_parity.sh        # from the skill root, or anywhere
#
# For every fixture in fixtures/ it renders the JSON through each entry point
# and diffs the markdown against the committed golden in golden/:
#   * the dual-use Python core   scripts/py/feature_report.py   (path + one stdin leg)
#   * the POSIX shim             scripts/posix/feature_report.sh
#   * the PowerShell back-compat scripts/win/feature_report.ps1  (needs pwsh/powershell)
#
# The goldens were captured from the pre-refactor renderer (JST-130), so a pass
# means the current code is byte-for-byte output-preserving AND the two ports
# agree. Any diff fails the run (exit 1) and is printed.
#
# Without a PowerShell host the ps1 legs are SKIPPED and the run reports
# PARTIAL — the py side is still gated against the goldens, but port parity is
# not verified; run where pwsh exists (pwsh 7 runs on Linux) before releasing.
#
# Adding a fixture: drop new-name.json into fixtures/, generate its golden once
# with `python3 scripts/py/feature_report.py fixtures/new-name.json > golden/new-name.md`,
# eyeball the markdown, and commit both.

set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SKILL_ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)   # conversation-debugger/
PY="$SKILL_ROOT/scripts/py/feature_report.py"
SH="$SKILL_ROOT/scripts/posix/feature_report.sh"
PS1="$SKILL_ROOT/scripts/win/feature_report.ps1"

PWSH=""
command -v pwsh >/dev/null 2>&1 && PWSH="pwsh"
[ -z "$PWSH" ] && command -v powershell >/dev/null 2>&1 && PWSH="powershell"

fails=0
checks=0
skipped=0
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# check <label> <golden-path> <cmd...> — diff cmd's stdout against the golden.
# Rendered output goes through a temp FILE, not $(…): command substitution
# strips trailing newlines and every report ends with a blank line, so a
# captured-string diff would false-fail on the final newline.
check() {
  label=$1; golden=$2; shift 2
  checks=$((checks + 1))
  if "$@" </dev/null >"$TMP/got.md" 2>"$TMP/got.err"; then
    if diff -u "$golden" "$TMP/got.md" >"$TMP/got.diff" 2>&1; then
      printf 'PASS  %s\n' "$label"
    else
      printf 'FAIL  %s — output differs from %s:\n' "$label" "${golden##*/}"
      head -25 "$TMP/got.diff"
      fails=$((fails + 1))
    fi
  else
    printf 'FAIL  %s — renderer exited non-zero:\n' "$label"
    cat "$TMP/got.err"
    fails=$((fails + 1))
  fi
}

for fx in "$HERE"/fixtures/*.json; do
  name=$(basename "$fx" .json)
  golden="$HERE/golden/$name.md"
  if [ ! -f "$golden" ]; then
    printf 'FAIL  %s — no golden (%s missing)\n' "$name" "golden/$name.md"
    fails=$((fails + 1)); continue
  fi
  check "py    $name" "$golden" python3 "$PY" "$fx"
  check "sh    $name" "$golden" bash "$SH" "$fx"
  if [ -n "$PWSH" ]; then
    check "ps1   $name" "$golden" "$PWSH" -NoProfile -File "$PS1" "$fx"
  else
    skipped=$((skipped + 1))
  fi
done

# stdin leg — the pipe form must render identically to the path form
name=single-step-populated
checks=$((checks + 1))
if python3 "$PY" - < "$HERE/fixtures/$name.json" | diff -u "$HERE/golden/$name.md" - >/dev/null 2>&1; then
  printf 'PASS  py    %s (stdin)\n' "$name"
else
  printf 'FAIL  py    %s (stdin) — differs from path form\n' "$name"
  fails=$((fails + 1))
fi

echo
if [ "$fails" -gt 0 ]; then
  printf 'parity: FAIL — %d of %d checks failed.\n' "$fails" "$checks"
  exit 1
elif [ "$skipped" -gt 0 ]; then
  printf 'parity: PARTIAL — %d checks passed, but no pwsh/powershell on PATH so %d ps1 legs were SKIPPED. Port parity is NOT verified; rerun where PowerShell exists.\n' "$checks" "$skipped"
  exit 0
else
  printf 'parity: PASS — all %d checks passed (py, sh, ps1 all byte-identical to the goldens).\n' "$checks"
  exit 0
fi
